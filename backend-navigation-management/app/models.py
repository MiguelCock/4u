from pydantic import BaseModel


class NavigationSessionCreate(BaseModel):
    user_id: str
    building_id: str
    route_id: str | None = None
    start_position: dict | None = None
    device_info: dict | None = None


class NavigationSessionUpdate(BaseModel):
    end_time: str | None = None
    status: str | None = None
    end_position: dict | None = None


class NavigationSessionResponse(NavigationSessionCreate):
    id: str
    start_time: str
    end_time: str | None = None
    status: str
    end_position: dict | None = None


class NavigationLogCreate(BaseModel):
    session_id: str
    gps_lat: float
    gps_long: float
    gps_accuracy: float | None = None
    heading: float | None = None
    corrected_lat: float | None = None
    corrected_long: float | None = None
    correction_error: float | None = None
    anchor_match_id: str | None = None
    confidence_score: float | None = None
    raw_image_url: str | None = None


class NavigationLogResponse(NavigationLogCreate):
    id: str
    timestamp: str


class UserFeedbackCreate(BaseModel):
    user_id: str
    session_id: str | None = None
    comment: str | None = None


class UserFeedbackResponse(UserFeedbackCreate):
    id: str
    created_at: str
