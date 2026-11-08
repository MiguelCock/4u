import logging
import os
import re
from datetime import UTC, datetime, timedelta

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, File, HTTPException, UploadFile
from packages.app_versions import install_app_version_guard
from packages.db_errors import install_db_error_handlers, select_all
from packages.geo import haversine_meters
from packages.supabase import SupaBase

logger = logging.getLogger(__name__)

from .models import (
    DESTINATION_LOCATION_TYPE_IDS,
    VERTICAL_LOCATION_TYPE_IDS,
    AnchorPointConnectionCreate,
    AnchorPointConnectionResponse,
    AnchorPointConnectionUpdate,
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
from .names import name_without_building

load_dotenv()

app = FastAPI()
install_db_error_handlers(app)
install_app_version_guard(app)

db = SupaBase(
    os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
)

# Shared with every other service via packages.supabase.SupaBase (#24) -
# bound as a plain module-level name so Depends(get_caller_id) and tests'
# app.dependency_overrides[get_caller_id] keep working unchanged.
get_caller_id = db.get_caller_id

# Guardrails against the mistakes found in the Icesi data (2026-11-03).
# Points are captured every 6-8 m; a longer connection makes guidance walk
# a straight line through whatever is in between (36-76 m ones crossed
# buildings there).
MAX_CONNECTION_METERS = 30.0
# Closer than this on the same floor is almost always the same spot saved
# twice, or a GPS fix nobody adjusted.
DUPLICATE_POINT_METERS = 1.0
# Farther than this from its building's pin is a wrong position (0,0, the
# admin's desk, another campus).
MAX_POINT_TO_BUILDING_METERS = 300.0


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


_ID_PATTERN = re.compile(r"[0-9A-Za-z-]{1,64}")


def _either_end(anchor_id: str) -> str:
    """The `.or_()` filter for connections touching [anchor_id]. The id goes
    into a filter string, so only id characters are let through (letters,
    digits, dashes - a UUID's); a comma, dot or parenthesis could add
    conditions. Anything else is a 404, like a malformed id elsewhere
    (packages.db_errors)."""
    if not _ID_PATTERN.fullmatch(anchor_id):
        raise HTTPException(status_code=404, detail="Anchor point not found")
    return f"anchor_point_a_id.eq.{anchor_id},anchor_point_b_id.eq.{anchor_id}"


def _recompute_connection_distances(anchor_id: str) -> None:
    """After a point moves, its connections' straight-line distances are
    stale (they weight the route search). Distances an admin typed by hand
    (distance_manual) are kept."""
    connections = (
        db.client.table("anchor_point_connections")
        .select("id,anchor_point_a_id,anchor_point_b_id,distance_manual")
        .or_(_either_end(anchor_id))
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
        distance = haversine_meters(
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
def upload_anchor_point_image(
    file: UploadFile = File(...), caller_id: str = Depends(get_caller_id)
):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    url = db.upload_image("anchor-points", file.file, file.filename)
    return {"url": url}


# Declared before DELETE /anchor-points/{id}, which would otherwise capture
# "upload-image" as an id.
@app.delete("/anchor-points/upload-image")
def delete_uploaded_anchor_point_image(
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


def _point_name(point: dict) -> str:
    return point.get("location_description") or f"point {point['id'][:4]}"


def _require_near_building(building_id: str, latitude: float, longitude: float):
    rows = (
        db.client.table("buildings")
        .select("latitude,longitude")
        .eq("id", building_id)
        .execute()
        .data
    )
    building = rows[0] if rows else {}
    if building.get("latitude") is None or building.get("longitude") is None:
        return
    distance = haversine_meters(
        latitude, longitude, building["latitude"], building["longitude"]
    )
    if distance > MAX_POINT_TO_BUILDING_METERS:
        raise HTTPException(
            status_code=400,
            detail=f"This position is {distance:.0f} m from its building. "
            "Pick the point's real position on the map.",
        )


def _require_no_duplicate(anchor_point: AnchorPointCreate):
    neighbours = (
        db.client.table("anchor_points")
        .select("id,latitude,longitude,location_description")
        .eq("building_id", anchor_point.building_id)
        .eq("floor", anchor_point.floor)
        .execute()
        .data
    )
    for other in neighbours:
        if (
            haversine_meters(
                anchor_point.latitude,
                anchor_point.longitude,
                other["latitude"],
                other["longitude"],
            )
            < DUPLICATE_POINT_METERS
        ):
            raise HTTPException(
                status_code=409,
                detail=f'"{_point_name(other)}" is already at this spot on '
                "this floor. Move the new point to where it really is, or add "
                "photos to the existing one.",
            )


def _require_short_connection(a: dict, b: dict) -> float:
    """The straight-line length of a connection between a and b, refused
    when it's too long or changes floor without stairs, an elevator or a
    ramp at either end."""
    distance = haversine_meters(
        a["latitude"], a["longitude"], b["latitude"], b["longitude"]
    )
    if distance > MAX_CONNECTION_METERS:
        raise HTTPException(
            status_code=400,
            detail=f'"{_point_name(a)}" and "{_point_name(b)}" are '
            f"{distance:.0f} m apart (at most {MAX_CONNECTION_METERS:.0f} m). "
            "Add points in between, every 6-8 m, so the guidance can follow "
            "the path.",
        )
    if (a.get("floor") or 0) != (b.get("floor") or 0) and not (
        a.get("location_type_id") in VERTICAL_LOCATION_TYPE_IDS
        or b.get("location_type_id") in VERTICAL_LOCATION_TYPE_IDS
    ):
        raise HTTPException(
            status_code=400,
            detail=f'"{_point_name(a)}" and "{_point_name(b)}" are on '
            "different floors. Connect floors through a stairs, elevator or "
            "ramp point.",
        )
    return distance


def _require_connections_still_short(point: dict):
    """Refuses moving a point (or changing its floor) when one of its
    connections would break the rules a new connection must follow."""
    connections = (
        db.client.table("anchor_point_connections")
        .select("anchor_point_a_id,anchor_point_b_id")
        .or_(_either_end(point["id"]))
        .execute()
        .data
    )
    other_ids = sorted(
        {
            c["anchor_point_b_id"]
            if c["anchor_point_a_id"] == point["id"]
            else c["anchor_point_a_id"]
            for c in connections
        }
    )
    if not other_ids:
        return
    others = (
        db.client.table("anchor_points")
        .select("id,floor,location_type_id,location_description,latitude,longitude")
        .in_("id", other_ids)
        .execute()
        .data
    )
    for other in others:
        _require_short_connection(point, other)


def _short_description(description: str | None, building_id: str | None) -> str | None:
    """description without its building's name (see app/names.py)."""
    if not description or not building_id:
        return description
    buildings = (
        db.client.table("buildings")
        .select("name,place_id")
        .eq("id", building_id)
        .execute()
    ).data
    if not buildings or not isinstance(buildings[0].get("name"), str):
        return description
    places = (
        db.client.table("places")
        .select("name")
        .eq("id", buildings[0].get("place_id"))
        .execute()
    ).data
    place = places[0].get("name") if places else None
    return name_without_building(
        description, buildings[0]["name"], place if isinstance(place, str) else None
    )


@app.post("/anchor-points")
def create_anchor_point(
    anchor_point: AnchorPointCreate, caller_id: str = Depends(get_caller_id)
):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    _require_description_for_destinations(
        anchor_point.location_type_id, anchor_point.location_description
    )
    _require_near_building(
        anchor_point.building_id, anchor_point.latitude, anchor_point.longitude
    )
    if not anchor_point.allow_nearby:
        _require_no_duplicate(anchor_point)
    payload = anchor_point.model_dump(exclude={"allow_nearby"})
    payload["location_description"] = _short_description(
        anchor_point.location_description, anchor_point.building_id
    )
    result = db.client.table("anchor_points").insert(payload).execute()
    return result.data


@app.get("/anchor-points")
def list_anchor_points(
    caller_id: str = Depends(get_caller_id),
) -> list[AnchorPointResponse]:
    return _list_all("anchor_points")


@app.get("/anchor-points/{id}")
def get_anchor_point(
    id: str, caller_id: str = Depends(get_caller_id)
) -> AnchorPointResponse:
    result = db.client.table("anchor_points").select("*").eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Anchor point not found")
    return result.data[0]


@app.patch("/anchor-points/{id}")
def update_anchor_point(
    id: str, anchor_point: AnchorPointUpdate, caller_id: str = Depends(get_caller_id)
):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    changes = anchor_point.model_dump(exclude_unset=True, exclude={"expected"})
    expected = {
        field: value
        for field, value in (anchor_point.expected or {}).items()
        if field in changes and field in _EXPECTABLE_FIELDS
    }
    current = _require_found(
        db.client.table("anchor_points")
        .select(
            "id,building_id,floor,location_type_id,location_description,"
            "latitude,longitude,status,metadata"
        )
        .eq("id", id)
        .execute(),
        "Anchor point",
    )[0]
    # JSON can't be compared inside the update, so metadata is checked here.
    if "metadata" in expected and current.get("metadata") != expected["metadata"]:
        _conflict(id, expected)
    current.pop("metadata", None)
    # Check the row as it will be after this PATCH, not just the payload -
    # changing only the type to "classroom" on an unnamed point must still
    # be rejected.
    merged = {**current, **changes}
    _require_description_for_destinations(
        merged.get("location_type_id"), merged.get("location_description")
    )
    if "location_description" in changes:
        changes["location_description"] = _short_description(
            changes["location_description"], merged.get("building_id")
        )
    relocated = any(
        key in changes and changes[key] != current.get(key)
        for key in ("latitude", "longitude", "floor", "building_id")
    )
    has_position = (
        merged.get("latitude") is not None and merged.get("longitude") is not None
    )
    if relocated and has_position:
        if merged.get("building_id"):
            _require_near_building(
                merged["building_id"], merged["latitude"], merged["longitude"]
            )
        _require_connections_still_short({**merged, "id": id})
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
    query = db.client.table("anchor_points").update(changes).eq("id", id)
    # In the same statement, so nothing can change between the check and the write.
    for field, value in expected.items():
        if field == "metadata":
            continue
        if value is None:
            query = query.is_(field, "null")
        elif field in _COORDINATE_FIELDS:
            # Postgres keeps a few more digits than it sends back
            # (6.200428135106001 is read as 6.200428135106), so the value an
            # app saw never equals the stored one exactly.
            query = query.gte(field, value - _COORDINATE_TOLERANCE).lte(
                field, value + _COORDINATE_TOLERANCE
            )
        else:
            query = query.eq(field, value)
    result = query.execute()
    if expected and not result.data:
        _conflict(id, expected)
    moved = any(
        key in changes and changes[key] != current.get(key)
        for key in ("latitude", "longitude")
    )
    if moved:
        _recompute_connection_distances(id)
    return result.data


# The fields an admin edits, which a save can check weren't changed meanwhile.
_EXPECTABLE_FIELDS = frozenset(
    (
        "location_description",
        "latitude",
        "longitude",
        "altitude",
        "location_type_id",
        "floor",
        "status",
        "metadata",
    )
)


# Coordinates compare within this, about 0.1 mm (see update_anchor_point).
_COORDINATE_FIELDS = frozenset(("latitude", "longitude", "altitude"))
_COORDINATE_TOLERANCE = 1e-9


def _differs(field: str, now, expected) -> bool:
    if field in _COORDINATE_FIELDS and now is not None and expected is not None:
        return abs(now - expected) > _COORDINATE_TOLERANCE
    return now != expected


def _conflict(id: str, expected: dict) -> None:
    """409 with the point as it is now, and which of the expected fields differ."""
    rows = db.client.table("anchor_points").select("*").eq("id", id).execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="Anchor point not found")
    now = rows[0]
    raise HTTPException(
        status_code=409,
        detail={
            "message": "Another admin changed this point since you opened it.",
            "fields": sorted(
                f for f, value in expected.items() if _differs(f, now.get(f), value)
            ),
            "current": now,
        },
    )


@app.delete("/anchor-points/{id}")
def delete_anchor_point(id: str, caller_id: str = Depends(get_caller_id)):
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
def create_anchor_point_photo(
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
def list_anchor_point_photos(
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
def list_all_anchor_point_photos(
    caller_id: str = Depends(get_caller_id),
) -> list[AnchorPointPhotoResponse]:
    return _list_all("anchor_point_photos")


@app.delete("/anchor-point-photos/{id}")
def delete_anchor_point_photo(id: str, caller_id: str = Depends(get_caller_id)):
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
def create_anchor_point_connection(
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

    points = (
        db.client.table("anchor_points")
        .select("id,floor,location_type_id,location_description,latitude,longitude")
        .in_("id", [a_id, b_id])
        .execute()
        .data
    )
    by_id = {p["id"]: p for p in points}
    if a_id not in by_id or b_id not in by_id:
        raise HTTPException(status_code=404, detail="Anchor point not found")
    straight = _require_short_connection(by_id[a_id], by_id[b_id])

    payload["distance_manual"] = payload["distance_meters"] is not None
    if payload["distance_meters"] is None:
        payload["distance_meters"] = straight
    elif payload["distance_meters"] < straight - 1:
        # A walk can be longer than the straight line (a bend, stairs),
        # never shorter.
        raise HTTPException(
            status_code=400,
            detail=f"The distance can't be shorter than the straight line "
            f"between the points ({straight:.1f} m).",
        )

    result = db.client.table("anchor_point_connections").insert(payload).execute()
    return result.data


@app.get("/anchor-point-connections")
def list_anchor_point_connections(
    caller_id: str = Depends(get_caller_id),
) -> list[AnchorPointConnectionResponse]:
    return _list_all("anchor_point_connections")


@app.get("/anchor-points/{id}/connections")
def list_anchor_point_connections_for_point(
    id: str, caller_id: str = Depends(get_caller_id)
) -> list[AnchorPointConnectionResponse]:
    result = (
        db.client.table("anchor_point_connections")
        .select("*")
        .or_(_either_end(id))
        .execute()
    )
    return result.data


@app.patch("/anchor-point-connections/{id}")
def update_anchor_point_connection(
    id: str,
    connection: AnchorPointConnectionUpdate,
    caller_id: str = Depends(get_caller_id),
) -> AnchorPointConnectionResponse:
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    notes = (connection.notes or "").strip() or None
    return _require_found(
        db.client.table("anchor_point_connections")
        .update({"notes": notes})
        .eq("id", id)
        .execute(),
        "Connection",
    )[0]


@app.delete("/anchor-point-connections/{id}")
def delete_anchor_point_connection(id: str, caller_id: str = Depends(get_caller_id)):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    _require_found(
        db.client.table("anchor_point_connections").delete().eq("id", id).execute(),
        "Connection",
    )
    return "ok"


@app.get("/buildings")
def list_buildings(
    caller_id: str = Depends(get_caller_id),
) -> list[BuildingResponse]:
    return _list_all("buildings")


@app.get("/buildings/{id}")
def get_building(id: str, caller_id: str = Depends(get_caller_id)) -> BuildingResponse:
    result = db.client.table("buildings").select("*").eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Building not found")
    return result.data[0]


@app.post("/buildings")
def create_building(building: BuildingCreate, caller_id: str = Depends(get_caller_id)):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    result = db.client.table("buildings").insert(building.model_dump()).execute()
    return result.data


@app.patch("/buildings/{id}")
def update_building(
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
def delete_building(id: str, caller_id: str = Depends(get_caller_id)):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    urls = _photo_urls_for_anchor_points(_anchor_point_ids_for_buildings([id]))
    _require_found(
        db.client.table("buildings").delete().eq("id", id).execute(), "Building"
    )
    _delete_photo_files(urls)
    return "ok"


@app.post("/places")
def create_place(place: PlaceCreate, caller_id: str = Depends(get_caller_id)):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    result = db.client.table("places").insert(place.model_dump()).execute()
    return result.data


@app.get("/places")
def list_places(
    caller_id: str = Depends(get_caller_id),
) -> list[PlaceResponse]:
    return _list_all("places")


@app.get("/places/{id}")
def get_place(id: str, caller_id: str = Depends(get_caller_id)) -> PlaceResponse:
    result = db.client.table("places").select("*").eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Place not found")
    return result.data[0]


@app.patch("/places/{id}")
def update_place(id: str, place: PlaceUpdate, caller_id: str = Depends(get_caller_id)):
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
def delete_place(id: str, caller_id: str = Depends(get_caller_id)):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    building_ids = _building_ids_for_place(id)
    urls = _photo_urls_for_anchor_points(_anchor_point_ids_for_buildings(building_ids))
    _require_found(
        db.client.table("places").delete().eq("id", id).execute(), "University"
    )
    _delete_photo_files(urls)
    return "ok"


# --- what changed since (A5) ---------------------------------------------

# Rows written in the same moment can commit a little after their updated_at,
# so each answer reaches back this far. Merging the same row twice is harmless.
_CHANGES_OVERLAP = timedelta(seconds=10)
# Further back, the app reloads everything instead.
_CHANGES_MAX_AGE = timedelta(hours=1)
_DELETIONS_KEPT = timedelta(days=1)
_CHANGED_TABLES = (
    "places",
    "buildings",
    "anchor_points",
    "anchor_point_photos",
    "anchor_point_connections",
)


@app.get("/changes")
def list_changes(since: datetime, caller_id: str = Depends(get_caller_id)) -> dict:
    """What changed or was deleted in the map since `since`, so admins' screens
    stay fresh without reading every list again (A5). Pass back `next_since`.
    `full: true` means it's been too long: load everything instead."""
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    now = datetime.now(UTC)
    if since.tzinfo is None:
        since = since.replace(tzinfo=UTC)
    next_since = (now - _CHANGES_OVERLAP).isoformat()
    if now - since > _CHANGES_MAX_AGE:
        return {"full": True, "next_since": next_since}
    stamp = since.isoformat()
    changes: dict = {"full": False, "next_since": next_since}
    for table in _CHANGED_TABLES:
        changes[table] = select_all(
            lambda table=table: (
                db.client.table(table).select("*").gte("updated_at", stamp).order("id")
            )
        )
    deletions = select_all(
        lambda: (
            db.client.table("map_deletions")
            .select("table_name,row_id")
            .gte("deleted_at", stamp)
            .order("id")
        )
    )
    changes["deleted"] = {
        table: sorted({d["row_id"] for d in deletions if d["table_name"] == table})
        for table in _CHANGED_TABLES
    }
    db.client.table("map_deletions").delete().lt(
        "deleted_at", (now - _DELETIONS_KEPT).isoformat()
    ).execute()
    return changes
