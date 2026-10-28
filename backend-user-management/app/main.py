import os

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, HTTPException
from packages.app_versions import install_app_version_guard, load_policy
from packages.db_errors import install_db_error_handlers
from packages.supabase import SupaBase
from supabase import AuthError

from .models import (
    OrphanedUser,
    ProfileCreate,
    ProfileResponse,
    ProfileUpdate,
    RoleResponse,
)

load_dotenv()

app = FastAPI()
install_db_error_handlers(app)
install_app_version_guard(app)

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


@app.get("/app-version")
async def app_version():
    """Public: the app versions the backend serves (packages/app_versions.py).
    The app checks it at sign-in to tell its user to update."""
    return load_policy()


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


_AUTH_USERS_PAGE_SIZE = 200


# Must stay declared above GET /profiles/{id}, or "orphaned" would be
# captured as an {id}.
@app.get("/profiles/orphaned")
async def list_orphaned_profiles(
    caller_id: str = Depends(get_caller_id),
) -> list[OrphanedUser]:
    """Auth accounts with no profiles row - signup's POST /profiles can fail
    after Supabase Auth already created the account (no rollback between
    the two), leaving a user that's invisible to GET /profiles and so can't
    be promoted or managed until it's repaired."""
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    existing_ids = {
        row["id"] for row in db.client.table("profiles").select("id").execute().data
    }
    orphaned: list[OrphanedUser] = []
    page = 1
    while True:
        users = db.client.auth.admin.list_users(
            page=page, per_page=_AUTH_USERS_PAGE_SIZE
        )
        for user in users:
            if user.id not in existing_ids:
                orphaned.append(
                    OrphanedUser(
                        id=user.id,
                        email=user.email,
                        created_at=str(user.created_at) if user.created_at else None,
                    )
                )
        if len(users) < _AUTH_USERS_PAGE_SIZE:
            break
        page += 1
    return orphaned


@app.post("/profiles/{user_id}/repair")
async def repair_profile(
    user_id: str,
    profile: ProfileUpdate,
    caller_id: str = Depends(get_caller_id),
):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    # profiles.id has no FK to auth.users, so this lookup is the only thing
    # stopping an arbitrary id from getting a profiles row.
    try:
        auth_user = db.client.auth.admin.get_user_by_id(user_id).user
    except AuthError:
        auth_user = None
    if auth_user is None:
        raise HTTPException(status_code=404, detail="Auth user not found")
    existing = db.client.table("profiles").select("id").eq("id", user_id).execute()
    if existing.data:
        raise HTTPException(status_code=409, detail="Profile already exists")
    payload = profile.model_dump(exclude_unset=True)
    payload["id"] = user_id
    payload.setdefault("role_id", _USER_ROLE_ID)
    result = db.client.table("profiles").insert(payload).execute()
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
    if payload.get("role_id") not in (None, SupaBase.ADMIN_ROLE_ID):
        _ensure_not_last_admin(id)
    result = db.client.table("profiles").update(payload).eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Profile not found")
    return result.data


def _ensure_not_last_admin(profile_id: str) -> None:
    """Refuses to remove the last admin (by demotion or deletion): with no
    admin left, nobody could promote anyone again from the app."""
    admins = (
        db.client.table("profiles")
        .select("id")
        .eq("role_id", SupaBase.ADMIN_ROLE_ID)
        .execute()
    ).data
    if [a.get("id") for a in admins] == [profile_id]:
        raise HTTPException(status_code=400, detail="There must be at least one admin")


@app.delete("/profiles/{id}")
async def delete_profile(id: str, caller_id: str = Depends(get_caller_id)):
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    if id == caller_id:
        raise HTTPException(status_code=400, detail="You can't delete your own account")
    _ensure_not_last_admin(id)
    result = db.client.table("profiles").delete().eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Profile not found")
    # The sign-in account goes too; otherwise it would linger as an
    # "account without a profile". Best effort: the profile is already gone.
    try:
        db.client.auth.admin.delete_user(id)
    except AuthError:
        pass
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
