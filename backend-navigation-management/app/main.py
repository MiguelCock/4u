import logging
import os
from datetime import UTC, datetime, timedelta

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, HTTPException
from packages.app_versions import install_app_version_guard
from packages.db_errors import install_db_error_handlers, select_all
from packages.supabase import SupaBase

from .models import (
    GuidanceReportCreate,
    GuidanceReportResponse,
    NavigationLogCreate,
    NavigationLogResponse,
    NavigationSessionCreate,
    NavigationSessionResponse,
    NavigationSessionUpdate,
    UserFeedbackCreate,
    UserFeedbackResponse,
)

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


def _session_owner(session_id: str) -> str | None:
    # navigation_logs has no user_id of its own - ownership is one hop away
    # via session_id -> navigation_sessions.user_id. Returns None if the
    # session doesn't exist (the caller turns that into a 404).
    result = (
        db.client.table("navigation_sessions")
        .select("user_id")
        .eq("id", session_id)
        .execute()
    )
    return result.data[0]["user_id"] if result.data else None


_log = logging.getLogger(__name__)

# Where backend-positioning keeps admin test walks' frames.
FRAMES_BUCKET = "navigation-frames"

# A tick sent just before the trip ended can reach the server after the
# end: a field test lost its last two ticks, and the arrival they
# carried, to a ~20 s connection stall. Accepted for this long after
# end_time; later ones (a phone still logging long after) are refused.
LATE_LOG_GRACE = timedelta(minutes=2)


def _accepts_logs(session: dict) -> bool:
    if session.get("status") == "active":
        return True
    try:
        ended = datetime.fromisoformat(session["end_time"])
    except KeyError, TypeError, ValueError:
        return False
    if ended.tzinfo is None:
        ended = ended.replace(tzinfo=UTC)
    return datetime.now(UTC) - ended <= LATE_LOG_GRACE


def _session_row(session_id: str) -> dict | None:
    result = (
        db.client.table("navigation_sessions")
        .select("user_id,status,end_time")
        .eq("id", session_id)
        .execute()
    )
    return result.data[0] if result.data else None


def _anchor_exists(anchor_id: str) -> bool:
    result = db.client.table("anchor_points").select("id").eq("id", anchor_id).execute()
    return bool(result.data)


@app.get("/")
async def root():
    return {"service": "backend-navigation-management", "status": "ok"}


@app.post("/sessions")
async def create_session(
    session: NavigationSessionCreate, caller_id: str = Depends(get_caller_id)
):
    # user_id is an identity field - force it to the verified caller rather
    # than trusting the body, same principle #111 applied to profiles.id.
    payload = {**session.model_dump(), "user_id": caller_id}
    result = db.client.table("navigation_sessions").insert(payload).execute()
    return result.data


@app.get("/sessions")
async def list_sessions(
    caller_id: str = Depends(get_caller_id),
) -> list[NavigationSessionResponse]:
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    return select_all(
        lambda: db.client.table("navigation_sessions").select("*").order("id")
    )


# Declared above /sessions/{id} so "active" isn't captured as an id.
@app.get("/sessions/active")
async def list_my_active_sessions(
    caller_id: str = Depends(get_caller_id),
) -> list[NavigationSessionResponse]:
    """The caller's own sessions still marked active, newest first - a
    route left open by closing the app mid-trip. The app offers to resume
    or finish it on the next launch, instead of it staying active forever.
    Any user, but only ever their own sessions."""
    result = (
        db.client.table("navigation_sessions")
        .select("*")
        .eq("user_id", caller_id)
        .eq("status", "active")
        .order("start_time", desc=True)
        .execute()
    )
    return result.data


@app.get("/sessions/{id}")
async def get_session(
    id: str, caller_id: str = Depends(get_caller_id)
) -> NavigationSessionResponse:
    result = db.client.table("navigation_sessions").select("*").eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Session not found")
    row = result.data[0]
    if row["user_id"] != caller_id and not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Forbidden")
    return row


@app.patch("/sessions/{id}")
async def update_session(
    id: str, session: NavigationSessionUpdate, caller_id: str = Depends(get_caller_id)
):
    existing = (
        db.client.table("navigation_sessions").select("user_id").eq("id", id).execute()
    )
    if not existing.data:
        raise HTTPException(status_code=404, detail="Session not found")
    if existing.data[0]["user_id"] != caller_id and not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Forbidden")
    changes = session.model_dump(exclude_unset=True)
    if changes.get("status") == "active" and not db.is_admin(caller_id):
        # A finished trip is resumed by continuing its active session, not by
        # reopening a closed one.
        raise HTTPException(status_code=400, detail="A finished trip can't be reopened")
    result = (
        db.client.table("navigation_sessions").update(changes).eq("id", id).execute()
    )
    return result.data


@app.delete("/sessions/{id}")
async def delete_session(id: str, caller_id: str = Depends(get_caller_id)):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    # user_feedback.session_id has no ON DELETE action (db_schema/user_feedback.sql),
    # so it must be detached (keeping the comment, just orphaning the link) before the
    # session delete, or that delete would fail on the FK. navigation_logs.session_id
    # cascades automatically (ON DELETE CASCADE) - nothing to do for those.
    db.client.table("user_feedback").update({"session_id": None}).eq(
        "session_id", id
    ).execute()
    # Admin test walks keep their camera frames (backend-positioning's
    # store_frame); the logs pointing at them go with the session.
    frames = [
        row["raw_image_url"]
        for row in select_all(
            lambda: (
                db.client.table("navigation_logs")
                .select("raw_image_url")
                .eq("session_id", id)
                .not_.is_("raw_image_url", "null")
                .order("id")
            )
        )
    ]
    db.client.table("navigation_sessions").delete().eq("id", id).execute()
    if frames:
        try:
            db.delete_images_by_url(FRAMES_BUCKET, frames)
        except Exception:  # noqa: BLE001 - leftover files don't undo the delete
            _log.exception("deleting %d frames of session %s failed", len(frames), id)
    return "ok"


@app.post("/logs")
async def create_log(log: NavigationLogCreate, caller_id: str = Depends(get_caller_id)):
    session = _session_row(log.session_id)
    if session is None:
        raise HTTPException(status_code=404, detail="Session not found")
    if session["user_id"] != caller_id and not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Forbidden")
    if not _accepts_logs(session):
        raise HTTPException(status_code=409, detail="This trip has already ended")
    payload = log.model_dump()
    # A camera match on an anchor point deleted since it was indexed would
    # fail the whole log on the foreign key; keep the GPS data instead.
    if payload.get("anchor_match_id") and not _anchor_exists(
        payload["anchor_match_id"]
    ):
        payload["anchor_match_id"] = None
    result = db.client.table("navigation_logs").insert(payload).execute()
    return result.data


@app.get("/logs")
async def list_logs(
    session_id: str | None = None,
    caller_id: str = Depends(get_caller_id),
) -> list[NavigationLogResponse]:
    """With `session_id`: that session's logs in time order, for its owner
    or an admin (session tracking used to download every log in the system
    and filter client-side). Without it: every log, admin only."""
    if session_id is not None:
        owner_id = _session_owner(session_id)
        if owner_id is None:
            raise HTTPException(status_code=404, detail="Session not found")
        if owner_id != caller_id and not db.is_admin(caller_id):
            raise HTTPException(status_code=403, detail="Forbidden")
        return select_all(
            lambda: (
                db.client.table("navigation_logs")
                .select("*")
                .eq("session_id", session_id)
                .order("timestamp")
                .order("id")
            )
        )
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    return select_all(
        lambda: db.client.table("navigation_logs").select("*").order("id")
    )


@app.get("/logs/{id}")
async def get_log(
    id: str, caller_id: str = Depends(get_caller_id)
) -> NavigationLogResponse:
    result = db.client.table("navigation_logs").select("*").eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Log not found")
    row = result.data[0]
    owner_id = _session_owner(row["session_id"])
    if owner_id != caller_id and not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Forbidden")
    return row


@app.post("/feedback")
async def create_feedback(
    feedback: UserFeedbackCreate, caller_id: str = Depends(get_caller_id)
):
    if feedback.session_id is not None:
        owner_id = _session_owner(feedback.session_id)
        if owner_id is None:
            raise HTTPException(status_code=404, detail="Session not found")
        if owner_id != caller_id and not db.is_admin(caller_id):
            raise HTTPException(status_code=403, detail="Forbidden")
    payload = {**feedback.model_dump(), "user_id": caller_id}
    result = db.client.table("user_feedback").insert(payload).execute()
    return result.data


@app.get("/feedback")
async def list_feedback(
    caller_id: str = Depends(get_caller_id),
) -> list[UserFeedbackResponse]:
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    return select_all(lambda: db.client.table("user_feedback").select("*").order("id"))


@app.get("/feedback/{id}")
async def get_feedback(
    id: str, caller_id: str = Depends(get_caller_id)
) -> UserFeedbackResponse:
    result = db.client.table("user_feedback").select("*").eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Feedback not found")
    row = result.data[0]
    if row["user_id"] != caller_id and not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Forbidden")
    return row


@app.post("/guidance-reports")
async def create_guidance_report(
    report: GuidanceReportCreate, caller_id: str = Depends(get_caller_id)
):
    """Marks the instruction the app just gave as wrong (admin test flow).
    The session's owner or an admin; reported_by is always the caller."""
    owner_id = _session_owner(report.session_id)
    if owner_id is None:
        raise HTTPException(status_code=404, detail="Session not found")
    if owner_id != caller_id and not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Forbidden")
    payload = {**report.model_dump(), "reported_by": caller_id}
    result = db.client.table("guidance_reports").insert(payload).execute()
    return result.data


@app.get("/guidance-reports")
async def list_guidance_reports(
    session_id: str, caller_id: str = Depends(get_caller_id)
) -> list[GuidanceReportResponse]:
    """One session's reports in time order, for its owner or an admin -
    drawn as X marks on that session's tracking map."""
    owner_id = _session_owner(session_id)
    if owner_id is None:
        raise HTTPException(status_code=404, detail="Session not found")
    if owner_id != caller_id and not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Forbidden")
    return select_all(
        lambda: (
            db.client.table("guidance_reports")
            .select("*")
            .eq("session_id", session_id)
            .order("created_at")
            .order("id")
        )
    )
