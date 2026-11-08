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
from .pathfinding import connected_ids, nearest_of, shortest_path

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

# Connections longer than this aren't routed over. backend-map-management
# refuses new ones (its MAX_CONNECTION_METERS); the older ones at Icesi
# (43-93 m) sent users straight into walls and skipped every turn on the
# way (2026-11-03). "No route" is safer than a straight line through a
# building, and the admin app lists them to redo.
MAX_CONNECTION_METERS = 30.0

# Where a connection may change floor (backend-map-management's
# VERTICAL_LOCATION_TYPE_IDS): an elevator, a stairwell or a ramp. One between
# any other two points was made before that rule and isn't routed.
ENTRANCE_LOCATION_TYPE_ID = 1
ELEVATOR_LOCATION_TYPE_ID = 3
STAIRWELL_LOCATION_TYPE_ID = 4
RAMP_LOCATION_TYPE_ID = 11

# What changing one floor adds to a connection's length in route-finding. The
# two ends of a floor change are nearly on top of each other, so without this
# it cost about 0 m: a route could climb a floor and come back to save a few
# metres. Elevators are cheapest, as the safest way up for these users.
FLOOR_CHANGE_METERS = {
    ELEVATOR_LOCATION_TYPE_ID: 10.0,
    RAMP_LOCATION_TYPE_ID: 15.0,
    STAIRWELL_LOCATION_TYPE_ID: 30.0,
}


@app.get("/")
async def root():
    return {"service": "backend-route-management", "status": "ok"}


@app.post("/routes")
def create_route(route: RouteCreate, caller_id: str = Depends(get_caller_id)):
    # created_by is an audit field - force it to the verified caller rather
    # than trusting whatever the body sent, same principle #111 applied to
    # profiles.id. Any authenticated user can create a route now - trip
    # planning creates one as a side effect of picking a start/end point.
    payload = {**route.model_dump(), "created_by": caller_id}
    result = db.client.table("routes").insert(payload).execute()
    return result.data


@app.get("/routes")
def list_routes(
    caller_id: str = Depends(get_caller_id),
) -> list[RouteResponse]:
    return select_all(lambda: db.client.table("routes").select("*").order("id"))


@app.get("/routes/{id}")
def get_route(id: str, caller_id: str = Depends(get_caller_id)) -> RouteResponse:
    result = db.client.table("routes").select("*").eq("id", id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Route not found")
    return result.data[0]


@app.delete("/routes/{id}")
def delete_route(id: str, caller_id: str = Depends(get_caller_id)):
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


def _load_points() -> dict[str, dict]:
    points = select_all(
        lambda: (
            db.client.table("anchor_points")
            .select("id,latitude,longitude,floor,status,location_type_id,building_id")
            .order("id")
        )
    )
    return {p["id"]: p for p in points}


def _floor_change_meters(a: dict, b: dict) -> float | None:
    """What going between a and b costs for changing floor: 0 on one floor,
    None when they change floor with no vertical point at either end. An
    elevator at either end counts as the elevator."""
    floors = abs((a.get("floor") or 0) - (b.get("floor") or 0))
    if floors == 0:
        return 0.0
    costs = [
        FLOOR_CHANGE_METERS[t]
        for t in (a.get("location_type_id"), b.get("location_type_id"))
        if t in FLOOR_CHANGE_METERS
    ]
    return floors * min(costs) if costs else None


def _routable_connections(
    connections: list[dict], by_id: dict[str, dict]
) -> list[dict]:
    """The connections routes may use, with distance_meters including the cost
    of changing floor: at most MAX_CONNECTION_METERS long, and any floor change
    through a vertical point. One whose ends have no position can't be measured
    and is kept. Copies: the rows themselves stay as stored."""

    def length(a: dict, b: dict) -> float | None:
        if None in (a.get("latitude"), a.get("longitude")):
            return None
        if None in (b.get("latitude"), b.get("longitude")):
            return None
        return haversine_meters(
            a["latitude"], a["longitude"], b["latitude"], b["longitude"]
        )

    routable = []
    for connection in connections:
        a = by_id.get(connection["anchor_point_a_id"])
        b = by_id.get(connection["anchor_point_b_id"])
        if not a or not b:
            routable.append(connection)
            continue
        meters = length(a, b)
        if meters is not None and meters > MAX_CONNECTION_METERS:
            continue
        floor_cost = _floor_change_meters(a, b)
        if floor_cost is None:
            continue
        distance = connection.get("distance_meters")
        routable.append(
            connection
            if not floor_cost or distance is None
            else {**connection, "distance_meters": distance + floor_cost}
        )
    return routable


def _building_targets(
    connections: list[dict], by_id: dict[str, dict], building_id: str
) -> set[str]:
    """Where a route to a whole building may end: its entrances. Most buildings
    at Icesi have none marked yet (2026-11-04), so otherwise any point on its
    lowest floor, the one people come in on. Verified and connected only."""
    connected = {
        end
        for c in connections
        for end in (c["anchor_point_a_id"], c["anchor_point_b_id"])
    }
    points = [
        p
        for p in by_id.values()
        if p.get("building_id") == building_id
        and p.get("status") == "verified"
        and p["id"] in connected
    ]
    entrances = {
        p["id"]
        for p in points
        if p.get("location_type_id") == ENTRANCE_LOCATION_TYPE_ID
    }
    if entrances or not points:
        return entrances
    lowest = min(p.get("floor") or 0 for p in points)
    return {p["id"] for p in points if (p.get("floor") or 0) == lowest}


def _building_end(
    connections: list[dict],
    by_id: dict[str, dict],
    start_id: str,
    building_id: str,
) -> tuple[str, str]:
    """The (start, end) of a route to a building: its target closest by walking.
    The start can change just as for a point (see _reachable_start)."""
    targets = _building_targets(connections, by_id, building_id)
    if not targets:
        raise HTTPException(
            status_code=404,
            detail="The destination isn't connected to any path yet - an admin "
            "needs to connect it.",
        )
    if start_id in targets:
        raise HTTPException(status_code=400, detail="You're already at that building.")
    path = nearest_of(connections, start_id, targets)
    if path is None:
        start_id = _reachable_start(connections, by_id, start_id, targets)
        path = nearest_of(connections, start_id, targets)
    return start_id, path[-1]


def _reachable_start(
    connections: list[dict],
    by_id: dict[str, dict],
    start_id: str,
    end_ids: set[str],
) -> str:
    """The verified point nearest start_id, on its floor and within
    REACHABLE_START_METERS, that has a path to one of end_ids. A 404 says which
    end isn't connected."""
    reachable = (
        set().union(*(connected_ids(connections, end) for end in end_ids)) - end_ids
    )
    if not reachable:
        raise HTTPException(
            status_code=404,
            detail="The destination isn't connected to any path yet - an admin "
            "needs to connect it.",
        )
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
def find_or_create_route(
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
    # Positions and floors too: see _routable_connections.
    by_id = _load_points()
    connections = _routable_connections(
        select_all(
            lambda: db.client.table("anchor_point_connections").select("*").order("id")
        ),
        by_id,
    )
    end_id = request.end_anchor_id
    if request.end_building_id is not None:
        start_id, end_id = _building_end(
            connections, by_id, start_id, request.end_building_id
        )
    cached = _find_saved_route(start_id, end_id)
    if cached and _route_still_walkable(cached, connections):
        return cached

    # anchor_point_connections/anchor_points are backend-map-management's
    # tables, not this service's - but every service shares one Supabase
    # Postgres project directly (no per-service DB isolation), so reading
    # them here is a deliberate, direct table read rather than inventing a
    # service-to-service HTTP call just to fetch rows this service's own
    # SupaBase client can already reach. First time this repo reads a
    # table outside the reading service's own domain.
    path = shortest_path(connections, start_id, end_id)
    if path is None:
        # Start from the nearest connected point instead. The saved route
        # carries that start, and the app guides from route.start_anchor_id.
        start_id = _reachable_start(connections, by_id, start_id, {end_id})
        cached = _find_saved_route(start_id, end_id)
        if cached and _route_still_walkable(cached, connections):
            return cached
        path = shortest_path(connections, start_id, end_id)

    anchors = (
        db.client.table("anchor_points")
        .select("id,building_id,location_description")
        .in_("id", [start_id, end_id])
        .execute()
    )
    by_id = {a["id"]: a for a in anchors.data}
    start_anchor = by_id.get(start_id)
    end_anchor = by_id.get(end_id)
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
        "end_anchor_id": end_id,
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
            .eq("end_anchor_id", end_id)
            .execute()
        )
    return result.data[0]
