import os

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, HTTPException
from packages.supabase import SupaBase

from .models import (
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
    result = db.client.table("navigation_sessions").select("*").execute()
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
    result = (
        db.client.table("navigation_sessions")
        .update(session.model_dump(exclude_unset=True))
        .eq("id", id)
        .execute()
    )
    return result.data


@app.post("/logs")
async def create_log(log: NavigationLogCreate, caller_id: str = Depends(get_caller_id)):
    owner_id = _session_owner(log.session_id)
    if owner_id is None:
        raise HTTPException(status_code=404, detail="Session not found")
    if owner_id != caller_id and not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Forbidden")
    result = db.client.table("navigation_logs").insert(log.model_dump()).execute()
    return result.data


@app.get("/logs")
async def list_logs(
    caller_id: str = Depends(get_caller_id),
) -> list[NavigationLogResponse]:
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    result = db.client.table("navigation_logs").select("*").execute()
    return result.data


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
    payload = {**feedback.model_dump(), "user_id": caller_id}
    result = db.client.table("user_feedback").insert(payload).execute()
    return result.data


@app.get("/feedback")
async def list_feedback(
    caller_id: str = Depends(get_caller_id),
) -> list[UserFeedbackResponse]:
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    result = db.client.table("user_feedback").select("*").execute()
    return result.data


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
