from pydantic import BaseModel


class AnchorPointCreate(BaseModel):
    building_id: str
    location_type_id: int | None = None
    floor: int = 0
    heading: float | None = None
    image_url: str
    latitude: float
    longitude: float
    altitude: float | None = None
    location_description: str | None = None
    captured_by: str


class AnchorPointResponse(AnchorPointCreate):
    id: str
    status: str


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
