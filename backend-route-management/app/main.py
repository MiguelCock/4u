import os

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, HTTPException
from packages.supabase import SupaBase

from .models import RouteCreate, RouteFindOrCreate, RouteResponse
from .pathfinding import shortest_path

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
    # created_by is an audit field - force it to the verified caller rather
    # than trusting whatever the body sent, same principle #111 applied to
    # profiles.id. Any authenticated user can create a route now - trip
    # planning creates one as a side effect of picking a start/end point.
    payload = {**route.model_dump(), "created_by": caller_id}
    result = db.client.table("routes").insert(payload).execute()
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


@app.post("/routes/find_or_create")
async def find_or_create_route(
    request: RouteFindOrCreate, caller_id: str = Depends(get_caller_id)
):
    if request.start_anchor_id == request.end_anchor_id:
        raise HTTPException(
            status_code=400, detail="Start and end anchor point must differ"
        )

    existing = (
        db.client.table("routes")
        .select("*")
        .eq("start_anchor_id", request.start_anchor_id)
        .eq("end_anchor_id", request.end_anchor_id)
        .execute()
    )
    if existing.data:
        return existing.data[0]

    # anchor_point_connections/anchor_points are backend-map-management's
    # tables, not this service's - but every service shares one Supabase
    # Postgres project directly (no per-service DB isolation), so reading
    # them here is a deliberate, direct table read rather than inventing a
    # service-to-service HTTP call just to fetch rows this service's own
    # SupaBase client can already reach. First time this repo reads a
    # table outside the reading service's own domain.
    connections = db.client.table("anchor_point_connections").select("*").execute()
    path = shortest_path(
        connections.data, request.start_anchor_id, request.end_anchor_id
    )
    if path is None:
        raise HTTPException(
            status_code=404, detail="No walkable path found between these points"
        )

    anchors = (
        db.client.table("anchor_points")
        .select("id,building_id,location_description")
        .in_("id", [request.start_anchor_id, request.end_anchor_id])
        .execute()
    )
    by_id = {a["id"]: a for a in anchors.data}
    start_anchor = by_id.get(request.start_anchor_id)
    end_anchor = by_id.get(request.end_anchor_id)
    start_desc = (
        start_anchor["location_description"] if start_anchor else "start"
    ) or "start"
    end_desc = (end_anchor["location_description"] if end_anchor else "end") or "end"

    payload = {
        "building_id": start_anchor["building_id"] if start_anchor else None,
        "name": f"{start_desc} to {end_desc}",
        "start_anchor_id": request.start_anchor_id,
        "end_anchor_id": request.end_anchor_id,
        "waypoint_anchor_ids": path[1:-1],
        "created_by": caller_id,
    }
    result = db.client.table("routes").insert(payload).execute()
    return result.data[0]
