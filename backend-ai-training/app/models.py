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
    # Compass heading the matched photo was taken facing (degrees), so the
    # caller can check it against the direction the phone faces now.
    heading: float | None = None


class SearchSimilarResponse(BaseModel):
    matches: list[SearchMatch]
