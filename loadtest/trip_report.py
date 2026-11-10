"""What happened on a trip, in one command (B3): stops reached, what was said,
photos, heading, pauses and the likely problems, with when each happened.
Read-only, with the same settings as event_report.py.

    uv run python trip_report.py b73b686d                  # one trip, by id or its start
    uv run python trip_report.py --since 2026-11-20T14:00 --until 2026-11-20T17:00
    uv run python trip_report.py b73b686d --save session.json

--save writes the trip as backend-positioning/scripts/export_session.py does, so
`uv run python scripts/replay.py session.json` there checks a positioning
change against it. The rules behind "likely problems" are in loadtool/trip.py.
"""

import argparse
import json
import sys

from supabase import create_client

from loadtool import config
from loadtool.trip import render, render_many, summarize

PAGE = 1000


def _all(make_query) -> list[dict]:
    rows, start = [], 0
    while True:
        page = make_query().range(start, start + PAGE - 1).execute().data
        rows += page
        if len(page) < PAGE:
            return rows
        start += PAGE


def find_sessions(
    client, ids: list[str], since: str | None, until: str | None
) -> list[dict]:
    query = lambda: client.table("navigation_sessions").select("*").order("start_time")
    if since or until:
        sessions = _all(
            lambda: (
                query()
                .gte("start_time", since or "1970")
                .lte("start_time", until or "9999")
            )
        )
        # The load test's simulated users aren't real trips.
        return [
            s
            for s in sessions
            if (s.get("device_info") or {}).get("platform")
            not in ("loadtest", "measure")
        ]
    # A uuid can't be matched by its start in the API, so match it here.
    every = _all(
        lambda: client.table("navigation_sessions").select("id").order("start_time")
    )
    found = []
    for wanted in ids:
        matches = [s["id"] for s in every if s["id"].startswith(wanted)]
        if len(matches) != 1:
            sys.exit(f"{wanted}: {len(matches)} trips start with that")
        found += (
            client.table("navigation_sessions")
            .select("*")
            .eq("id", matches[0])
            .execute()
            .data
        )
    return found


def trip_rows(client, session_id: str) -> tuple[list[dict], list[dict]]:
    logs = _all(
        lambda: (
            client.table("navigation_logs")
            .select("*")
            .eq("session_id", session_id)
            .order("timestamp")
            .order("id")
        )
    )
    reports = _all(
        lambda: (
            client.table("guidance_reports")
            .select("*")
            .eq("session_id", session_id)
            .order("created_at")
            .order("id")
        )
    )
    return logs, reports


def save(
    client, session: dict, logs: list[dict], reports: list[dict], path: str
) -> None:
    route = (
        client.table("routes").select("*").eq("id", session["route_id"]).execute().data
    )
    out = {
        "session": session,
        "route": route[0] if route else None,
        "logs": logs,
        "reports": reports,
        "anchors": _all(lambda: client.table("anchor_points").select("*").order("id")),
        "photos": _all(
            lambda: client.table("anchor_point_photos").select("*").order("id")
        ),
    }
    with open(path, "w") as file:
        json.dump(out, file, default=str)


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("ids", nargs="*", help="trip ids, or their first characters")
    parser.add_argument("--since")
    parser.add_argument("--until")
    parser.add_argument("--save", help="write the (single) trip for replay.py")
    args = parser.parse_args()
    if not args.ids and not (args.since or args.until):
        parser.error("give trip ids, or --since/--until")
    env = config.settings()
    client = create_client(env["SUPABASE_URL"], env["SUPABASE_SERVICE_ROLE_KEY"])
    sessions = find_sessions(client, args.ids, args.since, args.until)
    if not sessions:
        sys.exit("No trips found.")
    summaries = []
    for session in sessions:
        logs, reports = trip_rows(client, session["id"])
        if not logs:
            continue
        summaries.append(summarize(session, logs, reports))
        if args.save:
            if len(sessions) > 1:
                sys.exit("--save takes one trip.")
            save(client, session, logs, reports, args.save)
    print(render(summaries[0]) if len(summaries) == 1 else render_many(summaries))
    if args.save:
        print(f"\nSaved to {args.save}")


if __name__ == "__main__":
    main()
