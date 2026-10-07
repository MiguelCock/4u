import os

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, HTTPException
from packages.supabase import SupaBase

from .models import ProfileCreate, ProfileResponse, ProfileUpdate, RoleResponse

load_dotenv()

app = FastAPI()

db = SupaBase(
    os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
)

# Match db_schema/roles.sql's seeded rows.
_USER_ROLE_ID = 1

# Shared with every other service via packages.supabase.SupaBase (#24) -
# bound as a plain module-level name so Depends(get_caller_id) and tests'
# app.dependency_overrides[get_caller_id] keep working unchanged.
get_caller_id = db.get_caller_id


@app.get("/")
async def root():
    return {"service": "backend-user-management", "status": "ok"}


@app.post("/profiles")
async def create_profile(
    profile: ProfileCreate, caller_id: str = Depends(get_caller_id)
):
    # A caller can only ever create *their own* profile, as the verified
    # token identifies them - not an arbitrary id from the request body
    # (that would let someone pre-create/overwrite another user's row).
    # role_id is likewise forced to the default unless the caller is
    # already an admin, closing the same self-promotion hole on the
    # create path, not just update.
    payload = profile.model_dump()
    payload["id"] = caller_id
    if not db.is_admin(caller_id):
        payload["role_id"] = _USER_ROLE_ID
    result = db.client.table("profiles").insert(payload).execute()
    return result.data


@app.get("/profiles")
async def list_profiles(
    caller_id: str = Depends(get_caller_id),
) -> list[ProfileResponse]:
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    result = db.client.table("profiles").select("*").execute()
    return result.data


@app.get("/profiles/{id}")
async def get_profile(
    id: str, caller_id: str = Depends(get_caller_id)
) -> ProfileResponse:
    if id != caller_id and not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Forbidden")
    result = db.client.table("profiles").select("*").eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Profile not found")
    return result.data[0]


@app.patch("/profiles/{id}")
async def update_profile(
    id: str, profile: ProfileUpdate, caller_id: str = Depends(get_caller_id)
):
    is_admin = db.is_admin(caller_id)
    if id != caller_id and not is_admin:
        raise HTTPException(status_code=403, detail="Forbidden")
    payload = profile.model_dump(exclude_unset=True)
    if not is_admin and ("role_id" in payload or "is_active" in payload):
        raise HTTPException(
            status_code=403, detail="Only admins can change role or active status"
        )
    result = db.client.table("profiles").update(payload).eq("id", id).execute()
    return result.data


@app.delete("/profiles/{id}")
async def delete_profile(id: str, caller_id: str = Depends(get_caller_id)):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    db.client.table("profiles").delete().eq("id", id).execute()
    return "ok"


@app.get("/roles")
async def list_roles() -> list[RoleResponse]:
    result = db.client.table("roles").select("*").execute()
    return result.data


@app.get("/roles/{id}")
async def get_role(id: int) -> RoleResponse:
    result = db.client.table("roles").select("*").eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Role not found")
    return result.data[0]
