import os

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from packages.qdrant import Qdrant
from packages.supabase import SupaBase
from qdrant_client.models import FieldCondition, Filter, MatchValue, PointStruct

from .embedding import download_image, extract_embedding
from .models import IndexAnchorRequest, IndexAnchorResponse, SearchSimilarResponse

load_dotenv()

app = FastAPI()

qdrant = Qdrant(os.environ.get("QDRANT_URL"), os.environ.get("QDRANT_KEY"))
# Only needed to verify caller bearer tokens / admin role for the write
# endpoints below - this service otherwise never queries Postgres directly
# (see CLAUDE.md). POST /search_similar stays unauthenticated (#24 - it's
# called server-to-server by backend-positioning with no end-user token).
db = SupaBase(
    os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
)

_COLLECTION = "anchor_point_photos"
_VECTOR_SIZE = 1280
# Filtering (including filter-based delete) on a payload field requires an
# index on that field - every field ever used in a Filter() below must be
# listed here, or Qdrant rejects the request with a 400.
_INDEXED_FIELDS = ["anchor_point_id", "building_id"]

# Shared with every other service via packages.supabase.SupaBase (#24) -
# bound as a plain module-level name so Depends(get_caller_id) and tests'
# app.dependency_overrides[get_caller_id] keep working unchanged.
get_caller_id = db.get_caller_id


@app.get("/")
async def root():
    return {"service": "backend-ai-training", "status": "ok"}


@app.post("/index_anchor")
async def index_anchor(
    anchor: IndexAnchorRequest, caller_id: str = Depends(get_caller_id)
) -> IndexAnchorResponse:
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    qdrant.ensure_collection(_COLLECTION, _VECTOR_SIZE, indexed_fields=_INDEXED_FIELDS)

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
                    "building_id": anchor.building_id,
                    "heading": photo.heading,
                },
            )
        )

    if points:
        qdrant.client.upsert(_COLLECTION, points=points)
    return IndexAnchorResponse(indexed=len(points))


@app.post("/search_similar")
async def search_similar(
    file: UploadFile = File(...), limit: int = Form(5)
) -> SearchSimilarResponse:
    qdrant.ensure_collection(_COLLECTION, _VECTOR_SIZE, indexed_fields=_INDEXED_FIELDS)

    embedding = extract_embedding(file.file.read())
    result = qdrant.client.query_points(_COLLECTION, query=embedding, limit=limit)

    matches = [
        {
            "anchor_point_id": point.payload["anchor_point_id"],
            "photo_id": str(point.id),
            "latitude": point.payload["latitude"],
            "longitude": point.payload["longitude"],
            "building_id": point.payload["building_id"],
            "score": point.score,
        }
        for point in result.points
    ]
    return SearchSimilarResponse(matches=matches)


@app.delete("/index_photo/{photo_id}")
async def delete_indexed_photo(photo_id: str, caller_id: str = Depends(get_caller_id)):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    qdrant.ensure_collection(_COLLECTION, _VECTOR_SIZE, indexed_fields=_INDEXED_FIELDS)
    qdrant.client.delete(_COLLECTION, points_selector=[photo_id])
    return "ok"


@app.delete("/index_anchor/{anchor_point_id}")
async def delete_indexed_anchor(
    anchor_point_id: str, caller_id: str = Depends(get_caller_id)
):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    qdrant.ensure_collection(_COLLECTION, _VECTOR_SIZE, indexed_fields=_INDEXED_FIELDS)
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
    qdrant.ensure_collection(_COLLECTION, _VECTOR_SIZE, indexed_fields=_INDEXED_FIELDS)
    qdrant.client.delete(
        _COLLECTION,
        points_selector=Filter(
            must=[
                FieldCondition(key="building_id", match=MatchValue(value=building_id))
            ]
        ),
    )
    return "ok"
