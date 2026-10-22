import logging
import math
import os

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, File, HTTPException, UploadFile
from packages.db_errors import install_db_error_handlers, select_all
from packages.supabase import SupaBase

logger = logging.getLogger(__name__)

from .models import (
    DESTINATION_LOCATION_TYPE_IDS,
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
install_db_error_handlers(app)

db = SupaBase(
    os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
)

# Shared with every other service via packages.supabase.SupaBase (#24) -
# bound as a plain module-level name so Depends(get_caller_id) and tests'
# app.dependency_overrides[get_caller_id] keep working unchanged.
get_caller_id = db.get_caller_id

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


# An `in_` filter puts every id in the request URL; a big university could
# exceed URL limits, so ids are sent in chunks.
_IN_CHUNK = 150


def _chunks(ids: list[str]) -> list[list[str]]:
    return [ids[i : i + _IN_CHUNK] for i in range(0, len(ids), _IN_CHUNK)]


def _photo_urls_for_anchor_points(ids: list[str]) -> list[str]:
    urls: list[str] = []
    for chunk in _chunks(ids):
        rows = select_all(
            lambda chunk=chunk: (
                db.client.table("anchor_point_photos")
                .select("id,image_url")
                .in_("anchor_point_id", chunk)
                .order("id")
            )
        )
        urls.extend(row["image_url"] for row in rows)
    return urls


def _anchor_point_ids_for_buildings(ids: list[str]) -> list[str]:
    found: list[str] = []
    for chunk in _chunks(ids):
        rows = select_all(
            lambda chunk=chunk: (
                db.client.table("anchor_points")
                .select("id")
                .in_("building_id", chunk)
                .order("id")
            )
        )
        found.extend(row["id"] for row in rows)
    return found


def _list_all(table: str) -> list[dict]:
    """Every row, past Supabase's 1000-row-per-request cap."""
    return select_all(lambda: db.client.table(table).select("*").order("id"))


def _recompute_connection_distances(anchor_id: str) -> None:
    """After a point moves, its connections' straight-line distances are
    stale (they weight the route search). Distances an admin typed by hand
    (distance_manual) are kept."""
    connections = (
        db.client.table("anchor_point_connections")
        .select("id,anchor_point_a_id,anchor_point_b_id,distance_manual")
        .or_(f"anchor_point_a_id.eq.{anchor_id},anchor_point_b_id.eq.{anchor_id}")
        .execute()
        .data
    )
    automatic = [c for c in connections if not c.get("distance_manual")]
    if not automatic:
        return
    ids = {anchor_id}
    for c in automatic:
        ids.update((c["anchor_point_a_id"], c["anchor_point_b_id"]))
    points = (
        db.client.table("anchor_points")
        .select("id,latitude,longitude")
        .in_("id", sorted(ids))
        .execute()
        .data
    )
    by_id = {p["id"]: p for p in points}
    for c in automatic:
        a = by_id.get(c["anchor_point_a_id"])
        b = by_id.get(c["anchor_point_b_id"])
        if a is None or b is None:
            continue
        distance = _haversine_meters(
            a["latitude"], a["longitude"], b["latitude"], b["longitude"]
        )
        db.client.table("anchor_point_connections").update(
            {"distance_meters": distance}
        ).eq("id", c["id"]).execute()


def _require_found(result, what: str):
    if not result.data:
        raise HTTPException(status_code=404, detail=f"{what} not found")
    return result.data


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
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    url = db.upload_image("anchor-points", file.file, file.filename)
    return {"url": url}


# Declared before DELETE /anchor-points/{id}, which would otherwise capture
# "upload-image" as an id.
@app.delete("/anchor-points/upload-image")
async def delete_uploaded_anchor_point_image(
    url: str, caller_id: str = Depends(get_caller_id)
):
    """Removes a file uploaded by the step above whose photo record was
    never saved (the app's second request failed), so it doesn't sit in
    Storage forever. Refuses files a photo row still uses."""
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    used = (
        db.client.table("anchor_point_photos")
        .select("id")
        .eq("image_url", url)
        .limit(1)
        .execute()
    )
    if used.data:
        raise HTTPException(status_code=409, detail="This photo is still in use")
    _delete_photo_files([url])
    return "ok"


def _require_description_for_destinations(
    location_type_id: int | None, description: str | None
) -> None:
    # 400 (not a pydantic 422) so the app shows this sentence as-is.
    if (
        location_type_id in DESTINATION_LOCATION_TYPE_IDS
        and not (description or "").strip()
    ):
        raise HTTPException(
            status_code=400,
            detail="Destinations (entrances, classrooms, restrooms...) need a "
            "description - it's the name users pick and hear.",
        )


@app.post("/anchor-points")
async def create_anchor_point(
    anchor_point: AnchorPointCreate, caller_id: str = Depends(get_caller_id)
):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    _require_description_for_destinations(
        anchor_point.location_type_id, anchor_point.location_description
    )
    result = (
        db.client.table("anchor_points").insert(anchor_point.model_dump()).execute()
    )
    return result.data


@app.get("/anchor-points")
async def list_anchor_points(
    caller_id: str = Depends(get_caller_id),
) -> list[AnchorPointResponse]:
    return _list_all("anchor_points")


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
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    changes = anchor_point.model_dump(exclude_unset=True)
    current = _require_found(
        db.client.table("anchor_points")
        .select("location_type_id,location_description,latitude,longitude,status")
        .eq("id", id)
        .execute(),
        "Anchor point",
    )[0]
    # Check the row as it will be after this PATCH, not just the payload -
    # changing only the type to "classroom" on an unnamed point must still
    # be rejected.
    merged = {**current, **changes}
    _require_description_for_destinations(
        merged.get("location_type_id"), merged.get("location_description")
    )
    if changes.get("status") == "verified" and current.get("status") != "verified":
        photos = (
            db.client.table("anchor_point_photos")
            .select("id")
            .eq("anchor_point_id", id)
            .limit(1)
            .execute()
        )
        if not photos.data:
            raise HTTPException(
                status_code=400,
                detail="Add at least one photo before verifying this point - "
                "without photos the camera can never recognise it.",
            )
    result = db.client.table("anchor_points").update(changes).eq("id", id).execute()
    moved = any(
        key in changes and changes[key] != current.get(key)
        for key in ("latitude", "longitude")
    )
    if moved:
        _recompute_connection_distances(id)
    return result.data


@app.delete("/anchor-points/{id}")
async def delete_anchor_point(id: str, caller_id: str = Depends(get_caller_id)):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    urls = _photo_urls_for_anchor_points([id])
    _require_found(
        db.client.table("anchor_points").delete().eq("id", id).execute(),
        "Anchor point",
    )
    _delete_photo_files(urls)
    return "ok"


@app.post("/anchor-points/{id}/photos")
async def create_anchor_point_photo(
    id: str, photo: AnchorPointPhotoCreate, caller_id: str = Depends(get_caller_id)
):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    # captured_by is an audit field (who captured this photo) - force it to
    # the verified caller rather than trusting whatever the body sent, same
    # "don't trust a client-supplied identity field" principle #111 applied
    # to profiles.id.
    _require_found(
        db.client.table("anchor_points").select("id").eq("id", id).execute(),
        "Anchor point",
    )
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
    return _list_all("anchor_point_photos")


@app.delete("/anchor-point-photos/{id}")
async def delete_anchor_point_photo(id: str, caller_id: str = Depends(get_caller_id)):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    result = (
        db.client.table("anchor_point_photos")
        .select("image_url")
        .eq("id", id)
        .execute()
    )
    url = _require_found(result, "Photo")[0]["image_url"]
    db.client.table("anchor_point_photos").delete().eq("id", id).execute()
    _delete_photo_files([url] if url else [])
    return "ok"


@app.post("/anchor-point-connections")
async def create_anchor_point_connection(
    connection: AnchorPointConnectionCreate, caller_id: str = Depends(get_caller_id)
):
    if not db.is_admin(caller_id):
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

    payload["distance_manual"] = payload["distance_meters"] is not None
    if payload["distance_meters"] is None:
        points = (
            db.client.table("anchor_points")
            .select("id,latitude,longitude")
            .in_("id", [a_id, b_id])
            .execute()
            .data
        )
        by_id = {p["id"]: p for p in points}
        if a_id not in by_id or b_id not in by_id:
            raise HTTPException(status_code=404, detail="Anchor point not found")
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
    return _list_all("anchor_point_connections")


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
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    _require_found(
        db.client.table("anchor_point_connections").delete().eq("id", id).execute(),
        "Connection",
    )
    return "ok"


@app.get("/buildings")
async def list_buildings(
    caller_id: str = Depends(get_caller_id),
) -> list[BuildingResponse]:
    return _list_all("buildings")


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
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    result = db.client.table("buildings").insert(building.model_dump()).execute()
    return result.data


@app.patch("/buildings/{id}")
async def update_building(
    id: str, building: BuildingUpdate, caller_id: str = Depends(get_caller_id)
):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    result = (
        db.client.table("buildings")
        .update(building.model_dump(exclude_unset=True))
        .eq("id", id)
        .execute()
    )
    return _require_found(result, "Building")


@app.delete("/buildings/{id}")
async def delete_building(id: str, caller_id: str = Depends(get_caller_id)):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    urls = _photo_urls_for_anchor_points(_anchor_point_ids_for_buildings([id]))
    _require_found(
        db.client.table("buildings").delete().eq("id", id).execute(), "Building"
    )
    _delete_photo_files(urls)
    return "ok"


@app.post("/places")
async def create_place(place: PlaceCreate, caller_id: str = Depends(get_caller_id)):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    result = db.client.table("places").insert(place.model_dump()).execute()
    return result.data


@app.get("/places")
async def list_places(
    caller_id: str = Depends(get_caller_id),
) -> list[PlaceResponse]:
    return _list_all("places")


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
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    result = (
        db.client.table("places")
        .update(place.model_dump(exclude_unset=True))
        .eq("id", id)
        .execute()
    )
    return _require_found(result, "University")


@app.delete("/places/{id}")
async def delete_place(id: str, caller_id: str = Depends(get_caller_id)):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    building_ids = _building_ids_for_place(id)
    urls = _photo_urls_for_anchor_points(_anchor_point_ids_for_buildings(building_ids))
    _require_found(
        db.client.table("places").delete().eq("id", id).execute(), "University"
    )
    _delete_photo_files(urls)
    return "ok"
