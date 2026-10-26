from typing import Literal

from pydantic import BaseModel

SessionStatus = Literal["active", "completed", "abandoned", "failed"]


class NavigationSessionCreate(BaseModel):
    user_id: str
    # Nullable: a route can start outside any building, and deleting a
    # building keeps its trip history with building_id set to null.
    building_id: str | None = None
    route_id: str | None = None
    start_position: dict | None = None
    device_info: dict | None = None


class NavigationSessionUpdate(BaseModel):
    end_time: str | None = None
    status: SessionStatus | None = None
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
    # Free-form per-tick diagnostics (navigation_logs.debug): the
    # correction's candidates and gating decisions, compass heading, which
    # position guidance used, any cue spoken since the last tick.
    debug: dict | None = None


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


class GuidanceReportCreate(BaseModel):
    """An admin's "wrong instruction" mark during a test trip."""

    session_id: str
    instruction_text: str | None = None
    cue_type: str | None = None
    waypoint_index: int | None = None
    gps_lat: float | None = None
    gps_long: float | None = None
    corrected_lat: float | None = None
    corrected_long: float | None = None
    compass_heading: float | None = None
    debug: dict | None = None


class GuidanceReportResponse(GuidanceReportCreate):
    id: str
    reported_by: str | None = None
    created_at: str
