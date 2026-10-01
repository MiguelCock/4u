import os

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException
from packages.supabase import SupaBase

from .models import ProfileCreate, ProfileResponse, ProfileUpdate, RoleResponse

load_dotenv()

app = FastAPI()

db = SupaBase(
    os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
)

# Match db_schema/roles.sql's seeded rows.
_USER_ROLE_ID = 1
_ADMIN_ROLE_ID = 2


async def get_caller_id(authorization: str | None = Header(default=None)) -> str:
    """Verifies the caller's Supabase Auth bearer token for real (against
    Supabase itself, not a local check) and returns the real, verified
    caller id - every endpoint below depends on this instead of trusting
    whatever id shows up in the URL or body. 401s on anything missing,
    malformed, or rejected by Supabase (expired/invalid token)."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token")
    token = authorization.removeprefix("Bearer ").strip()
    if not token:
        raise HTTPException(status_code=401, detail="Missing bearer token")
    try:
        return db.get_user_id_from_token(token)
    except Exception as e:
        raise HTTPException(status_code=401, detail="Invalid or expired token") from e


def _is_admin(caller_id: str) -> bool:
    result = db.client.table("profiles").select("role_id").eq("id", caller_id).execute()
    return bool(result.data) and result.data[0]["role_id"] == _ADMIN_ROLE_ID


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
    if not _is_admin(caller_id):
        payload["role_id"] = _USER_ROLE_ID
    result = db.client.table("profiles").insert(payload).execute()
    return result.data


@app.get("/profiles")
async def list_profiles(
    caller_id: str = Depends(get_caller_id),
) -> list[ProfileResponse]:
    if not _is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    result = db.client.table("profiles").select("*").execute()
    return result.data


@app.get("/profiles/{id}")
async def get_profile(
    id: str, caller_id: str = Depends(get_caller_id)
) -> ProfileResponse:
    if id != caller_id and not _is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Forbidden")
    result = db.client.table("profiles").select("*").eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Profile not found")
    return result.data[0]


@app.patch("/profiles/{id}")
async def update_profile(
    id: str, profile: ProfileUpdate, caller_id: str = Depends(get_caller_id)
):
    is_admin = _is_admin(caller_id)
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
    if not _is_admin(caller_id):
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
