import logging
import math
import os

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, File, Header, HTTPException, UploadFile
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

# Match db_schema/roles.sql's seeded rows.
_ADMIN_ROLE_ID = 2

_EARTH_RADIUS_METERS = 6_371_000


async def get_caller_id(authorization: str | None = Header(default=None)) -> str:
    """Verifies the caller's Supabase Auth bearer token for real (against
    Supabase itself, not a local check) and returns the real, verified
    caller id - copied verbatim from backend-user-management (#111), the
    reusable template for this rollout (#24). 401s on anything missing,
    malformed, or rejected by Supabase (expired/invalid token)."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token")
    token = authorization.removeprefix("Bearer ").strip()
    if not token:
        raise HTTPException(status_code=401, detail="Missing bearer token")
    try:
        return db.get_user_id_from_token(token)
    except Exception as e:
        raise HTTPException(status_code=401, detail="Invalid or expired token") from e


def _is_admin(caller_id: str) -> bool:
    result = db.client.table("profiles").select("role_id").eq("id", caller_id).execute()
    return bool(result.data) and result.data[0]["role_id"] == _ADMIN_ROLE_ID


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
async def upload_anchor_point_image(
    file: UploadFile = File(...), caller_id: str = Depends(get_caller_id)
):
    if not _is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    url = db.upload_image("anchor-points", file.file, file.filename)
    return {"url": url}


@app.post("/anchor-points")
async def create_anchor_point(
    anchor_point: AnchorPointCreate, caller_id: str = Depends(get_caller_id)
):
    if not _is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    result = (
        db.client.table("anchor_points").insert(anchor_point.model_dump()).execute()
    )
    return result.data


@app.get("/anchor-points")
async def list_anchor_points(
    caller_id: str = Depends(get_caller_id),
) -> list[AnchorPointResponse]:
    result = db.client.table("anchor_points").select("*").execute()
    return result.data


@app.get("/anchor-points/{id}")
async def get_anchor_point(
    id: str, caller_id: str = Depends(get_caller_id)
) -> AnchorPointResponse:
    result = db.client.table("anchor_points").select("*").eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Anchor point not found")
    return result.data[0]


@app.patch("/anchor-points/{id}")
async def update_anchor_point(
    id: str, anchor_point: AnchorPointUpdate, caller_id: str = Depends(get_caller_id)
):
    if not _is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    result = (
        db.client.table("anchor_points")
        .update(anchor_point.model_dump(exclude_unset=True))
        .eq("id", id)
        .execute()
    )
    return result.data


@app.delete("/anchor-points/{id}")
async def delete_anchor_point(id: str, caller_id: str = Depends(get_caller_id)):
    if not _is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    urls = _photo_urls_for_anchor_points([id])
    db.client.table("anchor_points").delete().eq("id", id).execute()
    _delete_photo_files(urls)
    return "ok"


@app.post("/anchor-points/{id}/photos")
async def create_anchor_point_photo(
    id: str, photo: AnchorPointPhotoCreate, caller_id: str = Depends(get_caller_id)
):
    if not _is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    # captured_by is an audit field (who captured this photo) - force it to
    # the verified caller rather than trusting whatever the body sent, same
    # "don't trust a client-supplied identity field" principle #111 applied
    # to profiles.id.
    payload = {**photo.model_dump(), "anchor_point_id": id, "captured_by": caller_id}
    result = db.client.table("anchor_point_photos").insert(payload).execute()
    return result.data


@app.get("/anchor-points/{id}/photos")
async def list_anchor_point_photos(
    id: str, caller_id: str = Depends(get_caller_id)
) -> list[AnchorPointPhotoResponse]:
    result = (
        db.client.table("anchor_point_photos")
        .select("*")
        .eq("anchor_point_id", id)
        .execute()
    )
    return result.data


@app.get("/anchor-point-photos")
async def list_all_anchor_point_photos(
    caller_id: str = Depends(get_caller_id),
) -> list[AnchorPointPhotoResponse]:
    result = db.client.table("anchor_point_photos").select("*").execute()
    return result.data


@app.delete("/anchor-point-photos/{id}")
async def delete_anchor_point_photo(id: str, caller_id: str = Depends(get_caller_id)):
    if not _is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
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
async def create_anchor_point_connection(
    connection: AnchorPointConnectionCreate, caller_id: str = Depends(get_caller_id)
):
    if not _is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    if connection.anchor_point_a_id == connection.anchor_point_b_id:
        raise HTTPException(
            status_code=400, detail="Cannot connect an anchor point to itself"
        )

    payload = connection.model_dump()
    # created_by is an audit field - force it to the verified caller, same
    # reasoning as captured_by above.
    payload["created_by"] = caller_id
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
async def list_anchor_point_connections(
    caller_id: str = Depends(get_caller_id),
) -> list[AnchorPointConnectionResponse]:
    result = db.client.table("anchor_point_connections").select("*").execute()
    return result.data


@app.get("/anchor-points/{id}/connections")
async def list_anchor_point_connections_for_point(
    id: str, caller_id: str = Depends(get_caller_id)
) -> list[AnchorPointConnectionResponse]:
    result = (
        db.client.table("anchor_point_connections")
        .select("*")
        .or_(f"anchor_point_a_id.eq.{id},anchor_point_b_id.eq.{id}")
        .execute()
    )
    return result.data


@app.delete("/anchor-point-connections/{id}")
async def delete_anchor_point_connection(
    id: str, caller_id: str = Depends(get_caller_id)
):
    if not _is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    db.client.table("anchor_point_connections").delete().eq("id", id).execute()
    return "ok"


@app.get("/buildings")
async def list_buildings(
    caller_id: str = Depends(get_caller_id),
) -> list[BuildingResponse]:
    result = db.client.table("buildings").select("*").execute()
    return result.data


@app.get("/buildings/{id}")
async def get_building(
    id: str, caller_id: str = Depends(get_caller_id)
) -> BuildingResponse:
    result = db.client.table("buildings").select("*").eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Building not found")
    return result.data[0]


@app.post("/buildings")
async def create_building(
    building: BuildingCreate, caller_id: str = Depends(get_caller_id)
):
    if not _is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    result = db.client.table("buildings").insert(building.model_dump()).execute()
    return result.data


@app.patch("/buildings/{id}")
async def update_building(
    id: str, building: BuildingUpdate, caller_id: str = Depends(get_caller_id)
):
    if not _is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    result = (
        db.client.table("buildings")
        .update(building.model_dump(exclude_unset=True))
        .eq("id", id)
        .execute()
    )
    return result.data


@app.delete("/buildings/{id}")
async def delete_building(id: str, caller_id: str = Depends(get_caller_id)):
    if not _is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    urls = _photo_urls_for_anchor_points(_anchor_point_ids_for_buildings([id]))
    db.client.table("buildings").delete().eq("id", id).execute()
    _delete_photo_files(urls)
    return "ok"


@app.post("/places")
async def create_place(place: PlaceCreate, caller_id: str = Depends(get_caller_id)):
    if not _is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    result = db.client.table("places").insert(place.model_dump()).execute()
    return result.data


@app.get("/places")
async def list_places(
    caller_id: str = Depends(get_caller_id),
) -> list[PlaceResponse]:
    result = db.client.table("places").select("*").execute()
    return result.data


@app.get("/places/{id}")
async def get_place(id: str, caller_id: str = Depends(get_caller_id)) -> PlaceResponse:
    result = db.client.table("places").select("*").eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Place not found")
    return result.data[0]


@app.patch("/places/{id}")
async def update_place(
    id: str, place: PlaceUpdate, caller_id: str = Depends(get_caller_id)
):
    if not _is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    result = (
        db.client.table("places")
        .update(place.model_dump(exclude_unset=True))
        .eq("id", id)
        .execute()
    )
    return result.data


@app.delete("/places/{id}")
async def delete_place(id: str, caller_id: str = Depends(get_caller_id)):
    if not _is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    building_ids = _building_ids_for_place(id)
    urls = _photo_urls_for_anchor_points(_anchor_point_ids_for_buildings(building_ids))
    db.client.table("places").delete().eq("id", id).execute()
    _delete_photo_files(urls)
    return "ok"
