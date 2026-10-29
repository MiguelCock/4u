import os
import time

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from packages.app_versions import install_app_version_guard
from packages.db_errors import install_db_error_handlers, select_all
from packages.qdrant import Qdrant
from packages.supabase import SupaBase
from qdrant_client.models import (
    FieldCondition,
    Filter,
    GeoPoint,
    GeoRadius,
    MatchValue,
    PointStruct,
)

from .embedding import (
    COLLECTION,
    VECTOR_SIZE,
    InvalidImageError,
    download_image,
    extract_embedding,
)
from .models import IndexAnchorRequest, IndexAnchorResponse, SearchSimilarResponse

load_dotenv()

app = FastAPI()
install_db_error_handlers(app)
install_app_version_guard(app)

qdrant = Qdrant(os.environ.get("QDRANT_URL"), os.environ.get("QDRANT_KEY"))
# Verifies caller bearer tokens / admin role for the write endpoints below,
# and lets POST /reconcile read which photos should be indexed (see
# CLAUDE.md). POST /search_similar stays unauthenticated (#24 - it's
# called server-to-server by backend-positioning with no end-user token).
db = SupaBase(
    os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
)

# Per embedding model (see app/embedding.py).
_COLLECTION = COLLECTION
_VECTOR_SIZE = VECTOR_SIZE
# Filtering (including filter-based delete) on a payload field requires an
# index on that field - every field ever used in a Filter() below must be
# listed here, or Qdrant rejects the request with a 400.
_INDEXED_FIELDS = ["anchor_point_id", "building_id"]
# "location" is Qdrant's native geo-point payload shape ({"lon":..,"lat":..}),
# separate from the plain latitude/longitude floats kept for backward-
# compat/response echoing - a GeoRadius filter condition needs a GEO (not
# KEYWORD) index on it.
_GEO_INDEXED_FIELDS = ["location"]
# Campus-scale, generous enough to absorb GPS noise - #search_similar's
# whole point is to narrow the candidate pool to "plausibly where the
# caller actually is standing", not to be a precise cutoff.
_DEFAULT_SEARCH_RADIUS_METERS = 150.0

# Shared with every other service via packages.supabase.SupaBase (#24) -
# bound as a plain module-level name so Depends(get_caller_id) and tests'
# app.dependency_overrides[get_caller_id] keep working unchanged.
get_caller_id = db.get_caller_id


# The Qdrant client _ensure_collection last prepared the collection with.
_ensured_for: Qdrant | None = None


def _ensure_collection() -> None:
    """Creates the collection and its payload indexes on the first call of
    this process (repairing an older collection's missing indexes). Doing
    it on every call cost 4 Qdrant Cloud round trips per search, about a
    second of each navigation tick. Keyed by client, so a test's mock gets
    its own first call."""
    global _ensured_for
    if _ensured_for is qdrant:
        return
    qdrant.ensure_collection(
        _COLLECTION,
        _VECTOR_SIZE,
        indexed_fields=_INDEXED_FIELDS,
        geo_indexed_fields=_GEO_INDEXED_FIELDS,
    )
    _ensured_for = qdrant


@app.get("/")
async def root():
    return {"service": "backend-ai-training", "status": "ok"}


# Every endpoint below is a plain `def`: FastAPI runs it in its threadpool.
# As `async def`, the model (~0.3-0.5 s of CPU per photo) and the blocking
# httpx/Qdrant calls ran on the event loop, so one search held up every
# other request and positioning's 2 s timeout dropped visual matches as
# soon as a few users navigated at once.


@app.post("/index_anchor")
def index_anchor(
    anchor: IndexAnchorRequest, caller_id: str = Depends(get_caller_id)
) -> IndexAnchorResponse:
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    _ensure_collection()

    points = []
    for photo in anchor.photos:
        image_bytes = download_image(photo.image_url)
        try:
            embedding = extract_embedding(image_bytes)
        except InvalidImageError as e:
            raise HTTPException(
                status_code=400, detail=f"Photo {photo.photo_id} is not an image"
            ) from e
        points.append(
            PointStruct(
                id=photo.photo_id,
                vector=embedding,
                payload={
                    "anchor_point_id": anchor.anchor_point_id,
                    "latitude": anchor.latitude,
                    "longitude": anchor.longitude,
                    # Qdrant's native geo-point shape, used by
                    # /search_similar's GeoRadius filter - the flat
                    # latitude/longitude above stay for backward-compat
                    # and response echoing, this is the one actually
                    # indexed as GEO (see _GEO_INDEXED_FIELDS).
                    "location": {"lon": anchor.longitude, "lat": anchor.latitude},
                    "building_id": anchor.building_id,
                    "heading": photo.heading,
                },
            )
        )

    if points:
        qdrant.client.upsert(_COLLECTION, points=points)
    return IndexAnchorResponse(indexed=len(points))


def _indexed_photo_ids() -> list[str]:
    ids: list[str] = []
    offset = None
    while True:
        points, offset = qdrant.client.scroll(
            _COLLECTION,
            limit=1000,
            offset=offset,
            with_payload=False,
            with_vectors=False,
        )
        ids += [str(point.id) for point in points]
        if offset is None:
            return ids


def _searchable_photo_ids() -> set[str]:
    """Photos of verified anchor points: what the index should hold."""
    verified = {
        row["id"]
        for row in select_all(
            lambda: (
                db.client.table("anchor_points").select("id").eq("status", "verified")
            )
        )
    }
    return {
        str(row["id"])
        for row in select_all(
            lambda: db.client.table("anchor_point_photos").select("id,anchor_point_id")
        )
        if row["anchor_point_id"] in verified
    }


@app.get("/index_status")
def index_status(caller_id: str = Depends(get_caller_id)) -> dict:
    """Admin only: the ids of every indexed photo, so the app can tell which
    verified photos aren't searchable. A re-index once left 122 of 298 out,
    and nothing showed it until a test walk found anchors that never
    matched."""
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    _ensure_collection()
    return {"collection": _COLLECTION, "photo_ids": _indexed_photo_ids()}


@app.post("/reconcile")
def reconcile(caller_id: str = Depends(get_caller_id)) -> dict:
    """Admin only: removes indexed photos that shouldn't be searchable any
    more - the photo was deleted, or its point is no longer verified. The
    app deletes rows and index entries in separate calls, so a failure in
    between used to leave vectors that searches kept finding. The app's
    "Re-index verified points" runs this first."""
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    _ensure_collection()
    searchable = _searchable_photo_ids()
    indexed = _indexed_photo_ids()
    stale = [photo_id for photo_id in indexed if photo_id not in searchable]
    for start in range(0, len(stale), 500):
        qdrant.client.delete(_COLLECTION, points_selector=stale[start : start + 500])
    return {"removed": len(stale), "kept": len(indexed) - len(stale)}


@app.post("/search_similar")
def search_similar(
    file: UploadFile = File(...),
    limit: int = Form(5),
    # Optional: when the caller's (raw, pre-correction) GPS fix is known,
    # scope the search to nearby anchor points instead of the entire
    # collection - both for latency and correctness (a visually-similar but
    # geographically-distant point shouldn't win on cosine similarity
    # alone). Omitted entirely -> identical unscoped behavior as before,
    # so this stays backward-compatible with any other caller.
    latitude: float | None = Form(None),
    longitude: float | None = Form(None),
    radius_meters: float | None = Form(None),
) -> SearchSimilarResponse:
    _ensure_collection()

    started = time.perf_counter()
    try:
        embedding = extract_embedding(file.file.read())
    except InvalidImageError as e:
        raise HTTPException(status_code=400, detail="Not an image") from e
    embed_ms = round(1000 * (time.perf_counter() - started))
    query_filter = None
    if latitude is not None and longitude is not None:
        query_filter = Filter(
            must=[
                FieldCondition(
                    key="location",
                    geo_radius=GeoRadius(
                        center=GeoPoint(lon=longitude, lat=latitude),
                        radius=radius_meters or _DEFAULT_SEARCH_RADIUS_METERS,
                    ),
                )
            ]
        )
    started = time.perf_counter()
    result = qdrant.client.query_points(
        _COLLECTION, query=embedding, limit=limit, query_filter=query_filter
    )
    qdrant_ms = round(1000 * (time.perf_counter() - started))

    matches = [
        {
            "anchor_point_id": point.payload["anchor_point_id"],
            "photo_id": str(point.id),
            "latitude": point.payload["latitude"],
            "longitude": point.payload["longitude"],
            "building_id": point.payload["building_id"],
            "score": point.score,
            "heading": point.payload.get("heading"),
        }
        for point in result.points
    ]
    return SearchSimilarResponse(
        matches=matches, timing_ms={"embed": embed_ms, "qdrant": qdrant_ms}
    )


@app.delete("/index_photo/{photo_id}")
def delete_indexed_photo(photo_id: str, caller_id: str = Depends(get_caller_id)):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    _ensure_collection()
    qdrant.client.delete(_COLLECTION, points_selector=[photo_id])
    return "ok"


@app.delete("/index_anchor/{anchor_point_id}")
def delete_indexed_anchor(
    anchor_point_id: str, caller_id: str = Depends(get_caller_id)
):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    _ensure_collection()
    qdrant.client.delete(
        _COLLECTION,
        points_selector=Filter(
            must=[
                FieldCondition(
                    key="anchor_point_id", match=MatchValue(value=anchor_point_id)
                )
            ]
        ),
    )
    return "ok"


@app.delete("/index_building/{building_id}")
def delete_indexed_building(building_id: str, caller_id: str = Depends(get_caller_id)):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    _ensure_collection()
    qdrant.client.delete(
        _COLLECTION,
        points_selector=Filter(
            must=[
                FieldCondition(key="building_id", match=MatchValue(value=building_id))
            ]
        ),
    )
    return "ok"
