import os

from dotenv import load_dotenv
from fastapi import FastAPI
from packages.supabase import SupaBase

from .models import ProfileCreate, ProfileResponse, ProfileUpdate, RoleResponse

load_dotenv()

app = FastAPI()

db = SupaBase(os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_PUBLISHABLE_KEY"))


@app.get("/")
async def root():
    return {"service": "backend-user-management", "status": "ok"}


@app.post("/profiles")
async def create_profile(profile: ProfileCreate):
    result = db.client.table("profiles").insert(profile.model_dump()).execute()
    return result.data


@app.get("/profiles")
async def list_profiles() -> list[ProfileResponse]:
    result = db.client.table("profiles").select("*").execute()
    return result.data


@app.get("/profiles/{id}")
async def get_profile(id: str) -> ProfileResponse:
    result = db.client.table("profiles").select("*").eq("id", id).execute()
    return result.data


@app.patch("/profiles/{id}")
async def update_profile(id: str, profile: ProfileUpdate):
    result = (
        db.client.table("profiles")
        .update(profile.model_dump(exclude_unset=True))
        .eq("id", id)
        .execute()
    )
    return result.data


@app.delete("/profiles/{id}")
async def delete_profile(id: str):
    db.client.table("profiles").delete().eq("id", id).execute()
    return "ok"


@app.get("/roles")
async def list_roles() -> list[RoleResponse]:
    result = db.client.table("roles").select("*").execute()
    return result.data


@app.get("/roles/{id}")
async def get_role(id: int) -> RoleResponse:
    result = db.client.table("roles").select("*").eq("id", id).execute()
    return result.data
