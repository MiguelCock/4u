import os
from itertools import pairwise

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, HTTPException
from packages.app_versions import install_app_version_guard
from packages.db_errors import install_db_error_handlers, select_all
from packages.geo import haversine_meters
from packages.supabase import SupaBase
from postgrest.exceptions import APIError

from .models import RouteCreate, RouteFindOrCreate, RouteResponse
from .pathfinding import connected_ids, shortest_path

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

# The app picks the start as the verified point nearest the user's GPS fix,
# connected or not. When that point has no path to the destination, a
# connected point within this distance (on the same floor) is used instead:
# at Icesi most verified points had no connections yet (2026-11-03).
REACHABLE_START_METERS = 40.0


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
    return select_all(lambda: db.client.table("routes").select("*").order("id"))


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
    result = db.client.table("routes").delete().eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Route not found")
    return "ok"


def _route_still_walkable(route: dict, connections: list[dict]) -> bool:
    """Whether every consecutive pair on a saved route is still connected.
    Routes are cached by (start, end), so without this check a route kept
    following a connection an admin had since deleted."""
    edges = {
        frozenset((c["anchor_point_a_id"], c["anchor_point_b_id"])) for c in connections
    }
    stops = [
        route["start_anchor_id"],
        *(route.get("waypoint_anchor_ids") or []),
        route["end_anchor_id"],
    ]
    return all(frozenset(pair) in edges for pair in pairwise(stops))


def _find_saved_route(start_id: str, end_id: str) -> dict | None:
    existing = (
        db.client.table("routes")
        .select("*")
        .eq("start_anchor_id", start_id)
        .eq("end_anchor_id", end_id)
        .execute()
    )
    return existing.data[0] if existing.data else None


def _reachable_start(connections: list[dict], start_id: str, end_id: str) -> str:
    """The verified point nearest start_id, on its floor and within
    REACHABLE_START_METERS, that has a path to end_id. A 404 says which end
    isn't connected."""
    reachable = connected_ids(connections, end_id) - {end_id}
    if not reachable:
        raise HTTPException(
            status_code=404,
            detail="The destination isn't connected to any path yet - an admin "
            "needs to connect it.",
        )
    points = select_all(
        lambda: (
            db.client.table("anchor_points")
            .select("id,latitude,longitude,floor,status")
            .order("id")
        )
    )
    by_id = {p["id"]: p for p in points}
    start = by_id.get(start_id)
    best: tuple[float, str] | None = None
    for point_id in reachable if start else ():
        point = by_id.get(point_id)
        if not point or point.get("status") != "verified":
            continue
        if (point.get("floor") or 0) != (start.get("floor") or 0):
            continue
        distance = haversine_meters(
            start["latitude"], start["longitude"], point["latitude"], point["longitude"]
        )
        if distance <= REACHABLE_START_METERS and (best is None or distance < best[0]):
            best = (distance, point_id)
    if best is None:
        raise HTTPException(
            status_code=404,
            detail="Your starting point isn't connected to the paths that lead "
            "there - an admin needs to connect it.",
        )
    return best[1]


@app.post("/routes/find_or_create")
async def find_or_create_route(
    request: RouteFindOrCreate, caller_id: str = Depends(get_caller_id)
):
    if request.start_anchor_id == request.end_anchor_id:
        raise HTTPException(
            status_code=400, detail="Start and end anchor point must differ"
        )

    start_id = request.start_anchor_id
    # Fetched up front: needed both to re-check a cached route and to
    # compute a new one.
    # Every connection, paged: a graph silently truncated at Supabase's
    # 1000-row cap gave false "no walkable path" errors.
    connections = select_all(
        lambda: db.client.table("anchor_point_connections").select("*").order("id")
    )
    cached = _find_saved_route(start_id, request.end_anchor_id)
    if cached and _route_still_walkable(cached, connections):
        return cached

    # anchor_point_connections/anchor_points are backend-map-management's
    # tables, not this service's - but every service shares one Supabase
    # Postgres project directly (no per-service DB isolation), so reading
    # them here is a deliberate, direct table read rather than inventing a
    # service-to-service HTTP call just to fetch rows this service's own
    # SupaBase client can already reach. First time this repo reads a
    # table outside the reading service's own domain.
    path = shortest_path(connections, start_id, request.end_anchor_id)
    if path is None:
        # Start from the nearest connected point instead. The saved route
        # carries that start, and the app guides from route.start_anchor_id.
        start_id = _reachable_start(connections, start_id, request.end_anchor_id)
        cached = _find_saved_route(start_id, request.end_anchor_id)
        if cached and _route_still_walkable(cached, connections):
            return cached
        path = shortest_path(connections, start_id, request.end_anchor_id)

    anchors = (
        db.client.table("anchor_points")
        .select("id,building_id,location_description")
        .in_("id", [start_id, request.end_anchor_id])
        .execute()
    )
    by_id = {a["id"]: a for a in anchors.data}
    start_anchor = by_id.get(start_id)
    end_anchor = by_id.get(request.end_anchor_id)
    start_desc = (
        start_anchor["location_description"] if start_anchor else "start"
    ) or "start"
    end_desc = (end_anchor["location_description"] if end_anchor else "end") or "end"

    if cached:
        # A connection on the cached path was deleted since it was saved:
        # recompute its waypoints in place rather than deleting the row -
        # navigation_sessions.route_id references it with no ON DELETE.
        result = (
            db.client.table("routes")
            .update({"waypoint_anchor_ids": path[1:-1]})
            .eq("id", cached["id"])
            .execute()
        )
        return result.data[0]

    payload = {
        "building_id": start_anchor["building_id"] if start_anchor else None,
        "name": f"{start_desc} to {end_desc}",
        "start_anchor_id": start_id,
        "end_anchor_id": request.end_anchor_id,
        "waypoint_anchor_ids": path[1:-1],
        "created_by": caller_id,
    }
    try:
        result = db.client.table("routes").insert(payload).execute()
    except APIError as error:
        # Two requests for the same pair raced past the lookup above; the
        # unique (start, end) index kept just one - use that one.
        if error.code != "23505":
            raise
        result = (
            db.client.table("routes")
            .select("*")
            .eq("start_anchor_id", start_id)
            .eq("end_anchor_id", request.end_anchor_id)
            .execute()
        )
    return result.data[0]
