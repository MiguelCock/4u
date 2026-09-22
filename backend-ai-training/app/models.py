from pydantic import BaseModel


class IndexPhotoRequest(BaseModel):
    photo_id: str
    image_url: str
    heading: float | None = None


class IndexAnchorRequest(BaseModel):
    anchor_point_id: str
    latitude: float
    longitude: float
    building_id: str
    photos: list[IndexPhotoRequest]


class IndexAnchorResponse(BaseModel):
    indexed: int


class SearchMatch(BaseModel):
    anchor_point_id: str
    photo_id: str
    latitude: float
    longitude: float
    building_id: str
    score: float


class SearchSimilarResponse(BaseModel):
    matches: list[SearchMatch]
