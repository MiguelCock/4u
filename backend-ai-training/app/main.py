import os
import time

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from packages.app_versions import install_app_version_guard
from packages.db_errors import install_db_error_handlers
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

from .embedding import COLLECTION, VECTOR_SIZE, download_image, extract_embedding
from .models import IndexAnchorRequest, IndexAnchorResponse, SearchSimilarResponse

load_dotenv()

app = FastAPI()
install_db_error_handlers(app)
install_app_version_guard(app)

qdrant = Qdrant(os.environ.get("QDRANT_URL"), os.environ.get("QDRANT_KEY"))
# Only needed to verify caller bearer tokens / admin role for the write
# endpoints below - this service otherwise never queries Postgres directly
# (see CLAUDE.md). POST /search_similar stays unauthenticated (#24 - it's
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


@app.post("/index_anchor")
async def index_anchor(
    anchor: IndexAnchorRequest, caller_id: str = Depends(get_caller_id)
) -> IndexAnchorResponse:
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    _ensure_collection()

    points = []
    for photo in anchor.photos:
        image_bytes = download_image(photo.image_url)
        embedding = extract_embedding(image_bytes)
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


@app.get("/index_status")
async def index_status(caller_id: str = Depends(get_caller_id)) -> dict:
    """Admin only: the ids of every indexed photo, so the app can tell which
    verified photos aren't searchable. A re-index once left 122 of 298 out,
    and nothing showed it until a test walk found anchors that never
    matched."""
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    _ensure_collection()
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
            return {"collection": _COLLECTION, "photo_ids": ids}


@app.post("/search_similar")
async def search_similar(
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
    embedding = extract_embedding(file.file.read())
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
async def delete_indexed_photo(photo_id: str, caller_id: str = Depends(get_caller_id)):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    _ensure_collection()
    qdrant.client.delete(_COLLECTION, points_selector=[photo_id])
    return "ok"


@app.delete("/index_anchor/{anchor_point_id}")
async def delete_indexed_anchor(
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
async def delete_indexed_building(
    building_id: str, caller_id: str = Depends(get_caller_id)
):
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
