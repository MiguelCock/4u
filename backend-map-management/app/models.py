from typing import Literal

from pydantic import BaseModel, field_validator

# location_type ids (db_schema/location_type.sql) that are places people go
# *to* - entrance, classroom, office, restroom, cafeteria, parking, lobby,
# auditorium, bus stop. An anchor point of one of these types must have a
# description (it's the name users pick and hear); in-between types
# (hallway, intersection, stairs...) may leave it empty. Mirrored by
# kDestinationLocationTypes in application/lib/services/destinations.dart.
DESTINATION_LOCATION_TYPE_IDS = frozenset({1, 5, 6, 7, 8, 13, 14, 15, 18})


def _blank_to_none(value: str | None) -> str | None:
    if value is None:
        return None
    value = value.strip()
    return value or None


class AnchorPointMetadata(BaseModel):
    indoor: bool | None = None
    lighting: Literal["bright", "moderate", "dim"] | None = None
    surface: str | None = None


class AnchorPointCreate(BaseModel):
    building_id: str
    location_type_id: int | None = None
    floor: int = 0
    latitude: float
    longitude: float
    altitude: float | None = None
    location_description: str | None = None
    metadata: AnchorPointMetadata = AnchorPointMetadata()

    _normalize_description = field_validator("location_description")(_blank_to_none)


# Deliberately NOT `AnchorPointResponse(AnchorPointCreate)` - kept as its own
# loose model so older rows (null description, `{}` metadata) never 500.
class AnchorPointResponse(BaseModel):
    id: str
    building_id: str
    location_type_id: int | None = None
    floor: int = 0
    latitude: float
    longitude: float
    altitude: float | None = None
    location_description: str | None = None
    status: str
    # Loose dict, not AnchorPointMetadata - rows written before this field
    # existed default to `{}`, and a strict submodel would 500 on any shape
    # that doesn't conform, same reasoning as location_description above.
    metadata: dict = {}


class AnchorPointUpdate(BaseModel):
    location_description: str | None = None
    latitude: float | None = None
    longitude: float | None = None
    location_type_id: int | None = None
    floor: int | None = None
    status: str | None = None
    metadata: AnchorPointMetadata | None = None

    _normalize_description = field_validator("location_description")(_blank_to_none)


class AnchorPointPhotoCreate(BaseModel):
    image_url: str
    heading: float | None = None
    captured_by: str


class AnchorPointPhotoResponse(AnchorPointPhotoCreate):
    id: str
    anchor_point_id: str
    captured_at: str


class BuildingResponse(BaseModel):
    id: str
    place_id: str
    code: str
    name: str
    address: str | None = None
    latitude: float
    longitude: float
    floors: int
    has_elevator: bool
    has_stairs: bool


class BuildingCreate(BaseModel):
    place_id: str
    code: str
    name: str
    latitude: float
    longitude: float
    address: str | None = None
    floors: int = 1
    has_elevator: bool = False
    has_stairs: bool = True


class BuildingUpdate(BaseModel):
    place_id: str | None = None
    code: str | None = None
    name: str | None = None
    address: str | None = None
    latitude: float | None = None
    longitude: float | None = None
    floors: int | None = None
    has_elevator: bool | None = None
    has_stairs: bool | None = None
    is_active: bool | None = None


class PlaceCreate(BaseModel):
    code: str
    name: str
    latitude: float
    longitude: float
    address: str | None = None


class PlaceResponse(PlaceCreate):
    id: str


class PlaceUpdate(BaseModel):
    code: str | None = None
    name: str | None = None
    address: str | None = None
    latitude: float | None = None
    longitude: float | None = None
    is_active: bool | None = None


class AnchorPointConnectionCreate(BaseModel):
    anchor_point_a_id: str
    anchor_point_b_id: str
    # Server computes this via haversine (from the two anchor points'
    # lat/lng) when the caller doesn't supply one.
    distance_meters: float | None = None
    notes: str | None = None
    created_by: str


class AnchorPointConnectionResponse(AnchorPointConnectionCreate):
    id: str
    created_at: str
