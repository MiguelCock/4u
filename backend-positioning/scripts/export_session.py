"""Prints one navigation session as JSON for scripts/replay.py: the session,
its logs and guidance reports, its route, and every anchor point with its
photos. Read-only. Run on the server, inside this service's container
(which has the Supabase service-role environment):

    sudo docker compose exec -T positioning \\
        /app/.venv/bin/python scripts/export_session.py [SESSION_ID] > session.json

Without SESSION_ID, the most recently started session.
"""

import json
import os
import sys

from supabase import create_client


def _all(query_for):
    rows, start = [], 0
    while True:
        page = query_for().range(start, start + 999).execute().data
        rows += page
        if len(page) < 1000:
            return rows
        start += 1000


def main() -> None:
    client = create_client(
        os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    )
    sessions = client.table("navigation_sessions").select("*")
    if len(sys.argv) > 1:
        session = sessions.eq("id", sys.argv[1]).execute().data[0]
    else:
        session = sessions.order("start_time", desc=True).limit(1).execute().data[0]
    sid = session["id"]
    route = (
        client.table("routes").select("*").eq("id", session["route_id"]).execute().data
    )
    out = {
        "session": session,
        "route": route[0] if route else None,
        "logs": _all(
            lambda: (
                client.table("navigation_logs")
                .select("*")
                .eq("session_id", sid)
                .order("timestamp")
                .order("id")
            )
        ),
        "reports": _all(
            lambda: (
                client.table("guidance_reports")
                .select("*")
                .eq("session_id", sid)
                .order("created_at")
                .order("id")
            )
        ),
        "anchors": _all(lambda: client.table("anchor_points").select("*").order("id")),
        "photos": _all(
            lambda: client.table("anchor_point_photos").select("*").order("id")
        ),
    }
    json.dump(out, sys.stdout, default=str)


if __name__ == "__main__":
    main()
