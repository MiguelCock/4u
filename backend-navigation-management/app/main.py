import os

from dotenv import load_dotenv
from fastapi import FastAPI
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

db = SupaBase(os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_PUBLISHABLE_KEY"))


@app.get("/")
async def root():
    return {"service": "backend-navigation-management", "status": "ok"}


@app.post("/sessions")
async def create_session(session: NavigationSessionCreate):
    result = db.client.table("navigation_sessions").insert(session.model_dump()).execute()
    return result.data


@app.get("/sessions")
async def list_sessions() -> list[NavigationSessionResponse]:
    result = db.client.table("navigation_sessions").select("*").execute()
    return result.data


@app.get("/sessions/{id}")
async def get_session(id: str) -> NavigationSessionResponse:
    result = db.client.table("navigation_sessions").select("*").eq("id", id).execute()
    return result.data


@app.patch("/sessions/{id}")
async def update_session(id: str, session: NavigationSessionUpdate):
    result = (
        db.client.table("navigation_sessions")
        .update(session.model_dump(exclude_unset=True))
        .eq("id", id)
        .execute()
    )
    return result.data


@app.post("/logs")
async def create_log(log: NavigationLogCreate):
    result = db.client.table("navigation_logs").insert(log.model_dump()).execute()
    return result.data


@app.get("/logs")
async def list_logs() -> list[NavigationLogResponse]:
    result = db.client.table("navigation_logs").select("*").execute()
    return result.data


@app.get("/logs/{id}")
async def get_log(id: str) -> NavigationLogResponse:
    result = db.client.table("navigation_logs").select("*").eq("id", id).execute()
    return result.data


@app.post("/feedback")
async def create_feedback(feedback: UserFeedbackCreate):
    result = db.client.table("user_feedback").insert(feedback.model_dump()).execute()
    return result.data


@app.get("/feedback")
async def list_feedback() -> list[UserFeedbackResponse]:
    result = db.client.table("user_feedback").select("*").execute()
    return result.data


@app.get("/feedback/{id}")
async def get_feedback(id: str) -> UserFeedbackResponse:
    result = db.client.table("user_feedback").select("*").eq("id", id).execute()
    return result.data
