from pydantic import BaseModel

class ImageMetaData(BaseModel):
    latitude: float
    longitude: float
    accuracy: float

class ImageMetaDataResponse(BaseModel):
    latitude: float
    longitude: float
    accuracy: float