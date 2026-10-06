import os

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, HTTPException
from packages.supabase import SupaBase

from .models import RouteCreate, RouteResponse

load_dotenv()

app = FastAPI()

db = SupaBase(
    os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
)

# Shared with every other service via packages.supabase.SupaBase (#24) -
# bound as a plain module-level name so Depends(get_caller_id) and tests'
# app.dependency_overrides[get_caller_id] keep working unchanged.
get_caller_id = db.get_caller_id


@app.get("/")
async def root():
    return {"service": "backend-route-management", "status": "ok"}


@app.post("/routes")
async def create_route(route: RouteCreate, caller_id: str = Depends(get_caller_id)):
    if not db.is_admin(caller_id):
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
    if not db.is_admin(caller_id):
        raise HTTPException(status_code=403, detail="Admin only")
    db.client.table("routes").delete().eq("id", id).execute()
    return "ok"
