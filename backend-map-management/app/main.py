import logging
import math
import os

from dotenv import load_dotenv
from fastapi import FastAPI, File, HTTPException, UploadFile
from packages.supabase import SupaBase

logger = logging.getLogger(__name__)

from .models import (
    AnchorPointConnectionCreate,
    AnchorPointConnectionResponse,
    AnchorPointCreate,
    AnchorPointPhotoCreate,
    AnchorPointPhotoResponse,
    AnchorPointResponse,
    AnchorPointUpdate,
    BuildingCreate,
    BuildingResponse,
    BuildingUpdate,
    PlaceCreate,
    PlaceResponse,
    PlaceUpdate,
)

load_dotenv()

app = FastAPI()

db = SupaBase(
    os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
)

_EARTH_RADIUS_METERS = 6_371_000


def _haversine_meters(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    d_phi = math.radians(lat2 - lat1)
    d_lambda = math.radians(lng2 - lng1)
    a = (
        math.sin(d_phi / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
    )
    return _EARTH_RADIUS_METERS * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def _photo_urls_for_anchor_points(ids: list[str]) -> list[str]:
    if not ids:
        return []
    result = (
        db.client.table("anchor_point_photos")
        .select("image_url")
        .in_("anchor_point_id", ids)
        .execute()
    )
    return [row["image_url"] for row in result.data]


def _anchor_point_ids_for_buildings(ids: list[str]) -> list[str]:
    if not ids:
        return []
    result = (
        db.client.table("anchor_points").select("id").in_("building_id", ids).execute()
    )
    return [row["id"] for row in result.data]


def _building_ids_for_place(id: str) -> list[str]:
    result = db.client.table("buildings").select("id").eq("place_id", id).execute()
    return [row["id"] for row in result.data]


def _delete_photo_files(urls: list[str]) -> None:
    # Best-effort: a stray Storage hiccup shouldn't block an admin from
    # successfully deleting a record they already confirmed - same
    # philosophy as the Qdrant cleanup on anchor-point mutations.
    if not urls:
        return
    try:
        db.delete_images_by_url("anchor-points", urls)
    except Exception:
        logger.exception("failed to delete anchor point photo files from storage")


@app.get("/")
async def root():
    return {"service": "backend-map-management", "status": "ok"}


@app.post("/anchor-points/upload-image")
async def upload_anchor_point_image(file: UploadFile = File(...)):
    url = db.upload_image("anchor-points", file.file, file.filename)
    return {"url": url}


@app.post("/anchor-points")
async def create_anchor_point(anchor_point: AnchorPointCreate):
    result = (
        db.client.table("anchor_points").insert(anchor_point.model_dump()).execute()
    )
    return result.data


@app.get("/anchor-points")
async def list_anchor_points() -> list[AnchorPointResponse]:
    result = db.client.table("anchor_points").select("*").execute()
    return result.data


@app.get("/anchor-points/{id}")
async def get_anchor_point(id: str) -> AnchorPointResponse:
    result = db.client.table("anchor_points").select("*").eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Anchor point not found")
    return result.data[0]


@app.patch("/anchor-points/{id}")
async def update_anchor_point(id: str, anchor_point: AnchorPointUpdate):
    result = (
        db.client.table("anchor_points")
        .update(anchor_point.model_dump(exclude_unset=True))
        .eq("id", id)
        .execute()
    )
    return result.data


@app.delete("/anchor-points/{id}")
async def delete_anchor_point(id: str):
    urls = _photo_urls_for_anchor_points([id])
    db.client.table("anchor_points").delete().eq("id", id).execute()
    _delete_photo_files(urls)
    return "ok"


@app.post("/anchor-points/{id}/photos")
async def create_anchor_point_photo(id: str, photo: AnchorPointPhotoCreate):
    payload = {**photo.model_dump(), "anchor_point_id": id}
    result = db.client.table("anchor_point_photos").insert(payload).execute()
    return result.data


@app.get("/anchor-points/{id}/photos")
async def list_anchor_point_photos(id: str) -> list[AnchorPointPhotoResponse]:
    result = (
        db.client.table("anchor_point_photos")
        .select("*")
        .eq("anchor_point_id", id)
        .execute()
    )
    return result.data


@app.get("/anchor-point-photos")
async def list_all_anchor_point_photos() -> list[AnchorPointPhotoResponse]:
    result = db.client.table("anchor_point_photos").select("*").execute()
    return result.data


@app.delete("/anchor-point-photos/{id}")
async def delete_anchor_point_photo(id: str):
    result = (
        db.client.table("anchor_point_photos")
        .select("image_url")
        .eq("id", id)
        .execute()
    )
    url = result.data[0]["image_url"] if result.data else None
    db.client.table("anchor_point_photos").delete().eq("id", id).execute()
    _delete_photo_files([url] if url else [])
    return "ok"


@app.post("/anchor-point-connections")
async def create_anchor_point_connection(connection: AnchorPointConnectionCreate):
    if connection.anchor_point_a_id == connection.anchor_point_b_id:
        raise HTTPException(
            status_code=400, detail="Cannot connect an anchor point to itself"
        )

    payload = connection.model_dump()
    # The CHECK constraint requires a_id < b_id (as text) - always normalize
    # here so a connection made by tapping B-then-A in the app doesn't fail,
    # and so the UNIQUE constraint actually catches reverse-order duplicates.
    a_id, b_id = sorted((payload["anchor_point_a_id"], payload["anchor_point_b_id"]))
    payload["anchor_point_a_id"] = a_id
    payload["anchor_point_b_id"] = b_id

    if payload["distance_meters"] is None:
        points = (
            db.client.table("anchor_points")
            .select("id,latitude,longitude")
            .in_("id", [a_id, b_id])
            .execute()
            .data
        )
        by_id = {p["id"]: p for p in points}
        if a_id in by_id and b_id in by_id:
            payload["distance_meters"] = _haversine_meters(
                by_id[a_id]["latitude"],
                by_id[a_id]["longitude"],
                by_id[b_id]["latitude"],
                by_id[b_id]["longitude"],
            )

    result = db.client.table("anchor_point_connections").insert(payload).execute()
    return result.data


@app.get("/anchor-point-connections")
async def list_anchor_point_connections() -> list[AnchorPointConnectionResponse]:
    result = db.client.table("anchor_point_connections").select("*").execute()
    return result.data


@app.get("/anchor-points/{id}/connections")
async def list_anchor_point_connections_for_point(
    id: str,
) -> list[AnchorPointConnectionResponse]:
    result = (
        db.client.table("anchor_point_connections")
        .select("*")
        .or_(f"anchor_point_a_id.eq.{id},anchor_point_b_id.eq.{id}")
        .execute()
    )
    return result.data


@app.delete("/anchor-point-connections/{id}")
async def delete_anchor_point_connection(id: str):
    db.client.table("anchor_point_connections").delete().eq("id", id).execute()
    return "ok"


@app.get("/buildings")
async def list_buildings() -> list[BuildingResponse]:
    result = db.client.table("buildings").select("*").execute()
    return result.data


@app.get("/buildings/{id}")
async def get_building(id: str) -> BuildingResponse:
    result = db.client.table("buildings").select("*").eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Building not found")
    return result.data[0]


@app.post("/buildings")
async def create_building(building: BuildingCreate):
    result = db.client.table("buildings").insert(building.model_dump()).execute()
    return result.data


@app.patch("/buildings/{id}")
async def update_building(id: str, building: BuildingUpdate):
    result = (
        db.client.table("buildings")
        .update(building.model_dump(exclude_unset=True))
        .eq("id", id)
        .execute()
    )
    return result.data


@app.delete("/buildings/{id}")
async def delete_building(id: str):
    urls = _photo_urls_for_anchor_points(_anchor_point_ids_for_buildings([id]))
    db.client.table("buildings").delete().eq("id", id).execute()
    _delete_photo_files(urls)
    return "ok"


@app.post("/places")
async def create_place(place: PlaceCreate):
    result = db.client.table("places").insert(place.model_dump()).execute()
    return result.data


@app.get("/places")
async def list_places() -> list[PlaceResponse]:
    result = db.client.table("places").select("*").execute()
    return result.data


@app.get("/places/{id}")
async def get_place(id: str) -> PlaceResponse:
    result = db.client.table("places").select("*").eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Place not found")
    return result.data[0]


@app.patch("/places/{id}")
async def update_place(id: str, place: PlaceUpdate):
    result = (
        db.client.table("places")
        .update(place.model_dump(exclude_unset=True))
        .eq("id", id)
        .execute()
    )
    return result.data


@app.delete("/places/{id}")
async def delete_place(id: str):
    building_ids = _building_ids_for_place(id)
    urls = _photo_urls_for_anchor_points(_anchor_point_ids_for_buildings(building_ids))
    db.client.table("places").delete().eq("id", id).execute()
    _delete_photo_files(urls)
    return "ok"
