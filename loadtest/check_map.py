"""Whether a route is ready for an event (A4). Read-only.

    uv run python check_map.py --place 050022          # EAFIT: routes and pending points
    uv run python check_map.py --route "Entrada 2"     # one route, point by point

A route is ready when every point on the path the server would give today is
verified and has searchable photos. Fewer than 3 photos, or more than 15 m to the
next point, only make matching weaker. A saved route whose connection was deleted
is recomputed by the server, so it's checked the same way here.
"""

import argparse
import importlib.util
import itertools
import statistics

import httpx
from supabase import create_client

from loadtool import config
from loadtool.event import route_problems

COLLECTION = "anchor_point_photos_eigenplaces"


def _route_pathfinding():
    """backend-route-management's own pathfinding, so this finds the same path."""
    path = config.REPO / "backend-route-management" / "app" / "pathfinding.py"
    spec = importlib.util.spec_from_file_location("route_pathfinding", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


pathfinding = _route_pathfinding()


def _all(client, table: str, columns: str = "*") -> list[dict]:
    rows, start = [], 0
    while True:
        page = (
            client.table(table)
            .select(columns)
            .order("id")
            .range(start, start + 999)
            .execute()
            .data
        )
        rows += page
        if len(page) < 1000:
            return rows
        start += 1000


def indexed_photos() -> dict[str, str]:
    """Every searchable photo id, with its point."""
    env = config._read_env_file(config.REPO / "packages" / ".env")
    url, key = env["QDRANT_URL"], env["QDRANT_KEY"]
    found, offset = {}, None
    while True:
        body = {"limit": 500, "with_payload": ["anchor_point_id"], "with_vector": False}
        if offset:
            body["offset"] = offset
        result = httpx.post(
            f"{url}/collections/{COLLECTION}/points/scroll",
            headers={"api-key": key},
            json=body,
            timeout=60,
        ).json()["result"]
        for point in result["points"]:
            found[str(point["id"])] = point["payload"]["anchor_point_id"]
        offset = result.get("next_page_offset")
        if not offset:
            return found


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    which = parser.add_mutually_exclusive_group(required=True)
    which.add_argument("--place", help="a place's code, like 050022 for EAFIT")
    which.add_argument("--route", help="part of a route's name, or its id")
    args = parser.parse_args()

    env = config.settings()
    client = create_client(env["SUPABASE_URL"], env["SUPABASE_SERVICE_ROLE_KEY"])
    points = {p["id"]: p for p in _all(client, "anchor_points")}
    buildings = {b["id"]: b for b in _all(client, "buildings")}
    photos: dict[str, list[str]] = {}
    for photo in _all(client, "anchor_point_photos", "id,anchor_point_id"):
        photos.setdefault(photo["anchor_point_id"], []).append(photo["id"])
    connections = _all(client, "anchor_point_connections")
    connected = {
        frozenset((c["anchor_point_a_id"], c["anchor_point_b_id"])) for c in connections
    }
    indexed = indexed_photos()
    stale = sum(1 for point_id in indexed.values() if point_id not in points)
    routes = _all(client, "routes")

    if args.place:
        place = next(
            (p for p in _all(client, "places") if p.get("code") == args.place), None
        )
        if not place:
            raise SystemExit(f"No place with code {args.place}.")
        mine = {b for b, row in buildings.items() if row["place_id"] == place["id"]}
        pending = [
            p
            for p in points.values()
            if p["building_id"] in mine and p["status"] != "verified"
        ]
        print(
            f"{place['name']}: {sum(p['building_id'] in mine for p in points.values())} points"
        )
        print(f"Not verified ({len(pending)}):")
        for point in pending:
            building = buildings[point["building_id"]]["name"]
            print(
                f"  - {point.get('location_description') or point['id'][:8]} "
                f"({building}, floor {point.get('floor')}): {point['status']}"
            )
        routes = [r for r in routes if r["building_id"] in mine]
    else:
        routes = [
            r
            for r in routes
            if args.route in (r["id"], r["name"]) or args.route in r["name"]
        ]
        if not routes:
            raise SystemExit(f"No route matches {args.route!r}.")

    print(
        f"\nSearch entries pointing at deleted points: {stale}"
        + ("  (run 'Re-index verified points' in the admin app)" if stale else "")
    )
    for route in routes:
        ids = [
            route["start_anchor_id"],
            *(route["waypoint_anchor_ids"] or []),
            route["end_anchor_id"],
        ]
        note = ""
        if not all(frozenset(pair) in connected for pair in itertools.pairwise(ids)):
            # As find_or_create does on the next trip.
            ids = pathfinding.shortest_path(connections, ids[0], ids[-1]) or []
            note = " (saved path out of date: checking the one the server would give)"
            if not ids:
                print(f"\n{route['name']}: NOT READY, start and end aren't connected")
                continue
        path = [points[i] for i in ids if i in points]
        problems, warnings, gaps = route_problems(path, photos, connected, set(indexed))
        if len(path) < len(ids):
            problems.insert(0, f"{len(ids) - len(path)} points no longer exist")
        spacing = (
            f"gaps {statistics.median(gaps):.0f} m median, {max(gaps):.0f} m max"
            if gaps
            else "no gaps"
        )
        verdict = "READY" if not problems else f"NOT READY, {len(problems)} to fix"
        if warnings:
            verdict += f", {len(warnings)} warnings"
        print(f"\n{route['name']}: {len(path)} points, {spacing}: {verdict}{note}")
        for problem in problems:
            print(f"  - fix: {problem}")
        for warning in warnings:
            print(f"  - weaker matching: {warning}")


if __name__ == "__main__":
    main()
