from pydantic import BaseModel, Field


class AnchorPointCreate(BaseModel):
    building_id: str
    location_type_id: int | None = None
    floor: int = 0
    latitude: float
    longitude: float
    altitude: float | None = None
    location_description: str = Field(min_length=1)


# Deliberately NOT `AnchorPointResponse(AnchorPointCreate)` - existing rows
# captured before location_description became required can still have a
# null value, and a required response field would 500 on those on GET.
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


class AnchorPointUpdate(BaseModel):
    location_description: str | None = None
    latitude: float | None = None
    longitude: float | None = None
    location_type_id: int | None = None
    floor: int | None = None
    status: str | None = None


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
