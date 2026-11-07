"""After a rehearsal or the event: how real trips went, phone by phone (A4).
Read-only. Phones are numbered, never named, since these are real people's trips.

    uv run python event_report.py --since 2026-11-20T14:00 --until 2026-11-20T17:00

Each photo's time is split into the server's part and the rest, which is mostly
the network: the phone's round trip (debug.timing_ms.correct) against
positioning's own time (debug.correction.total_ms). The app version isn't logged
per trip yet (story B2), so it isn't shown.
"""

import argparse
from datetime import UTC, datetime, timedelta

from supabase import create_client

from loadtool import config
from loadtool.event import summarize_trip_logs

PAGE = 1000


def _ms(value) -> str:
    return "—" if value is None else f"{value / 1000:.1f} s"


def _share(value) -> str:
    return "—" if value is None else f"{value:.0%}"


def fetch(client, since: str, until: str) -> list[tuple[dict, list[dict]]]:
    sessions = (
        client.table("navigation_sessions")
        .select("id,start_time,status,device_info")
        .gte("start_time", since)
        .lte("start_time", until)
        .order("start_time")
        .execute()
        .data
    )
    # The load test's simulated users aren't real trips.
    sessions = [
        s
        for s in sessions
        if (s.get("device_info") or {}).get("platform") != "loadtest"
    ]
    trips = []
    for session in sessions:
        logs, start = [], 0
        while True:
            page = (
                client.table("navigation_logs")
                .select("debug,anchor_match_id")
                .eq("session_id", session["id"])
                .order("timestamp")
                .range(start, start + PAGE - 1)
                .execute()
                .data
            )
            logs += page
            if len(page) < PAGE:
                break
            start += PAGE
        trips.append((session, logs))
    return trips


def render(trips: list[tuple[dict, list[dict]]], since: str, until: str) -> str:
    everything = [log for _, logs in trips for log in logs]
    total = summarize_trip_logs(everything)
    lines = [
        f"# Trips from {since} to {until}",
        "",
        f"{len(trips)} trips, {total['photos']} photos.",
        "",
        (
            f"- Photos matched: {_share(total['matched_share'])}, refused as busy: "
            f"{_share(total['busy_share'])}"
        ),
        (
            f"- Photo answers on the phone: {_ms(total['phone_p50_ms'])} p50, "
            f"{_ms(total['phone_p95_ms'])} p95; the server's part {_ms(total['server_p95_ms'])} p95"
        ),
        (
            f"- **The network's part: {_ms(total['network_p50_ms'])} p50, "
            f"{_ms(total['network_p95_ms'])} p95**"
        ),
        (
            f"- Ticks without a photo: {total['paused_ticks']} paused because the server was "
            f"busy, {total['failed_ticks']} failed (camera or connection)"
        ),
        "",
        "| Phone | Status | Photos | Matched | Phone p95 | Network p95 | Failed ticks |",
        "|---:|---|---:|---:|---:|---:|---:|",
    ]
    for number, (session, logs) in enumerate(trips, 1):
        trip = summarize_trip_logs(logs)
        lines.append(
            f"| {number} | {session['status']} | {trip['photos']} "
            f"| {_share(trip['matched_share'])} | {_ms(trip['phone_p95_ms'])} "
            f"| {_ms(trip['network_p95_ms'])} | {trip['failed_ticks']} |"
        )
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    now = datetime.now(UTC)
    parser.add_argument("--since", default=(now - timedelta(hours=6)).isoformat())
    parser.add_argument("--until", default=now.isoformat())
    args = parser.parse_args()
    env = config.settings()
    client = create_client(env["SUPABASE_URL"], env["SUPABASE_SERVICE_ROLE_KEY"])
    print(render(fetch(client, args.since, args.until), args.since, args.until))


if __name__ == "__main__":
    main()
