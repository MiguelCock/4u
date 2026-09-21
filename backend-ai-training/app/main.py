import os

from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, UploadFile
from packages.qdrant import Qdrant
from qdrant_client.models import PointStruct

from .embedding import download_image, extract_embedding
from .models import IndexAnchorRequest, IndexAnchorResponse, SearchSimilarResponse

load_dotenv()

app = FastAPI()

qdrant = Qdrant(os.environ.get("QDRANT_URL"), os.environ.get("QDRANT_KEY"))

_COLLECTION = "anchor_point_photos"
_VECTOR_SIZE = 1280


@app.get("/")
async def root():
    return {"service": "backend-ai-training", "status": "ok"}


@app.post("/index_anchor")
async def index_anchor(anchor: IndexAnchorRequest) -> IndexAnchorResponse:
    qdrant.ensure_collection(_COLLECTION, _VECTOR_SIZE)

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
    qdrant.ensure_collection(_COLLECTION, _VECTOR_SIZE)

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
