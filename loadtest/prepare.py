"""Downloads the EAFIT walks to replay and picks a route. Only reads production.

uv run python prepare.py
"""

import json
import sys

import httpx
from supabase import create_client

from loadtool import config
from loadtool.trips import choose_route


def all_rows(client, table: str, columns: str = "*") -> list[dict]:
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
        start += 1000
        if len(page) < 1000:
            return rows


def main() -> None:
    env = config.settings()
    client = create_client(env["SUPABASE_URL"], env["SUPABASE_SERVICE_ROLE_KEY"])
    frames_dir = config.DATA_DIR / "frames"
    frames_dir.mkdir(parents=True, exist_ok=True)

    sessions = all_rows(client, "navigation_sessions", "id")
    trips = []
    for prefix in config.TRIP_SESSION_PREFIXES:
        session = next((s for s in sessions if s["id"].startswith(prefix)), None)
        if session is None:
            sys.exit(f"No session starting with {prefix}")
        logs = (
            client.table("navigation_logs")
            .select("gps_lat,gps_long,gps_accuracy,heading,raw_image_url,debug")
            .eq("session_id", session["id"])
            .order("timestamp")
            .execute()
            .data
        )
        ticks = []
        for number, log in enumerate(logs):
            url = log.get("raw_image_url")
            if not url:
                continue
            frame = frames_dir / f"{prefix}-{number:03d}.jpg"
            if not frame.exists():
                response = httpx.get(url, timeout=30)
                response.raise_for_status()
                frame.write_bytes(response.content)
            debug = log.get("debug") or {}
            ticks.append(
                {
                    "latitude": log["gps_lat"],
                    "longitude": log["gps_long"],
                    "accuracy": log["gps_accuracy"] or 10,
                    # Only what the app would send: a heading it trusts.
                    "heading": log.get("heading")
                    if debug.get("heading_reliable")
                    else None,
                    "frame": str(frame),
                }
            )
        print(f"{prefix}: {len(ticks)} ticks with a frame, of {len(logs)} logs")
        if ticks:
            trips.append({"session": session["id"], "ticks": ticks})
    if not trips:
        sys.exit("No frames to replay")

    places = client.table("places").select("id,name").execute().data
    campus = {p["id"] for p in places if config.CAMPUS.lower() in p["name"].lower()}
    buildings = client.table("buildings").select("id,place_id").execute().data
    campus_buildings = {b["id"] for b in buildings if b["place_id"] in campus}
    points = {
        p["id"]: p
        for p in all_rows(
            client, "anchor_points", "id,building_id,latitude,longitude,status"
        )
        if p["building_id"] in campus_buildings
    }
    route = choose_route(
        all_rows(client, "routes"),
        points,
        all_rows(client, "anchor_point_connections"),
    )
    if route is None:
        sys.exit(
            f"No saved {config.CAMPUS} route is still walkable. Walk one in the app "
            "so it's saved: asking for an unsaved or stale one would write to routes."
        )
    print(
        f"Route: {route['name']} ({len(route.get('waypoint_anchor_ids') or [])} stops)"
    )
    config.TRIPS_FILE.write_text(json.dumps({"trips": trips, "route": route}))
    print(f"Wrote {config.TRIPS_FILE}")


if __name__ == "__main__":
    main()
