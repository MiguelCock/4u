"""Replaying a logged walk, and picking a route that's safe to ask for. Pure."""

import itertools
import math


def haversine_meters(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    radius = 6_371_000
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = phi2 - phi1
    dlng = math.radians(lng2 - lng1)
    a = (
        math.sin(dphi / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(dlng / 2) ** 2
    )
    return 2 * radius * math.asin(math.sqrt(a))


def ping_pong_index(step: int, length: int, offset: int = 0) -> int:
    """Which tick of a [length]-tick trip to play at [step]: there and back,
    so the position never jumps from the end of the trip to its start."""
    if length <= 1:
        return 0
    period = 2 * (length - 1)
    position = (step + offset) % period
    return position if position < length else period - position


def start_offset(user_number: int, length: int) -> int:
    """Spreads users along the trip, as real users wouldn't all be in one spot."""
    if length <= 1:
        return 0
    return (user_number * 7) % (2 * (length - 1))


def choose_route(
    routes: list[dict],
    points: dict[str, dict],
    connections: list[dict],
    max_leg_meters: float = 30.0,
) -> dict | None:
    """The longest saved route that find_or_create returns as it is: every stop
    verified, on the campus given by [points], and every leg still connected and
    short. Anything else would make the server recompute and rewrite the row, and
    a load test must not change real routes."""
    edges = {
        frozenset((c["anchor_point_a_id"], c["anchor_point_b_id"])) for c in connections
    }
    best: dict | None = None
    best_stops = 0
    for route in routes:
        stops = [
            route["start_anchor_id"],
            *(route.get("waypoint_anchor_ids") or []),
            route["end_anchor_id"],
        ]
        if not all(
            stop in points and points[stop].get("status") == "verified"
            for stop in stops
        ):
            continue
        walkable = True
        for a, b in itertools.pairwise(stops):
            meters = haversine_meters(
                points[a]["latitude"],
                points[a]["longitude"],
                points[b]["latitude"],
                points[b]["longitude"],
            )
            if frozenset((a, b)) not in edges or meters > max_leg_meters:
                walkable = False
                break
        if walkable and len(stops) > best_stops:
            best, best_stops = route, len(stops)
    return best
