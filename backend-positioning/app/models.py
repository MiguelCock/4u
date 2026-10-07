from pydantic import BaseModel


class CorrectPositionResponse(BaseModel):
    # Shaped to map directly onto navigation_logs' existing, previously
    # unused columns (db_schema/navigation_logs.sql) - a future caller can
    # pass this straight through to backend-navigation-management's
    # POST /logs.
    corrected_lat: float
    corrected_long: float
    correction_error: float
    anchor_match_id: str | None = None
    confidence_score: float | None = None
    # Always null in v1 - this service never uploads/stores the submitted
    # frame (no Storage access, by design - see CLAUDE.md). Documented gap,
    # not silently dropped.
    raw_image_url: str | None = None
