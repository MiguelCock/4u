import os

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException
from packages.supabase import SupaBase

from .models import RouteCreate, RouteResponse

load_dotenv()

app = FastAPI()

db = SupaBase(
    os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
)

# Match db_schema/roles.sql's seeded rows.
_ADMIN_ROLE_ID = 2


async def get_caller_id(authorization: str | None = Header(default=None)) -> str:
    """Verifies the caller's Supabase Auth bearer token for real (against
    Supabase itself, not a local check) and returns the real, verified
    caller id - copied verbatim from backend-user-management (#111), the
    reusable template for this rollout (#24). 401s on anything missing,
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
    return {"service": "backend-route-management", "status": "ok"}


@app.post("/routes")
async def create_route(route: RouteCreate, caller_id: str = Depends(get_caller_id)):
    if not _is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    result = db.client.table("routes").insert(route.model_dump()).execute()
    return result.data


@app.get("/routes")
async def list_routes(
    caller_id: str = Depends(get_caller_id),
) -> list[RouteResponse]:
    result = db.client.table("routes").select("*").execute()
    return result.data


@app.get("/routes/{id}")
async def get_route(id: str, caller_id: str = Depends(get_caller_id)) -> RouteResponse:
    result = db.client.table("routes").select("*").eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Route not found")
    return result.data[0]


@app.delete("/routes/{id}")
async def delete_route(id: str, caller_id: str = Depends(get_caller_id)):
    if not _is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    db.client.table("routes").delete().eq("id", id).execute()
    return "ok"
