"""A test round in one report (B5, B2): trips per campus and app version, the
device matrix, and the SUS score. Read-only, with the same settings as
trip_report.py.

    uv run python round_report.py --since 2026-11-13 --until 2026-11-14
    uv run python round_report.py --since 2026-11-13 --sus answers.csv > report.md

answers.csv has one row per participant with columns q1..q10 (1-5) and an
optional code, never a name; keep it in test_users_comments/, not the repo.
See docs/testing/field-test.md.
"""

import argparse
import sys

from supabase import create_client

from loadtool import config
from loadtool.round import read_sus, render_round
from loadtool.trip import summarize
from trip_report import _all, find_sessions, trip_rows


def campus_names(client) -> dict[str, str]:
    """building id -> its place's (campus's) name."""
    places = {
        p["id"]: p["name"]
        for p in _all(lambda: client.table("places").select("id,name").order("id"))
    }
    return {
        b["id"]: places.get(b["place_id"], "?")
        for b in _all(
            lambda: client.table("buildings").select("id,place_id").order("id")
        )
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--since", required=True)
    parser.add_argument("--until")
    parser.add_argument("--sus", help="a CSV of SUS answers (q1..q10)")
    args = parser.parse_args()
    env = config.settings()
    client = create_client(env["SUPABASE_URL"], env["SUPABASE_SERVICE_ROLE_KEY"])
    sessions = find_sessions(client, [], args.since, args.until)
    if not sessions:
        sys.exit("No trips found.")
    campuses = campus_names(client)
    summaries = []
    for session in sessions:
        logs, reports = trip_rows(client, session["id"])
        if not logs:
            continue
        summary = summarize(session, logs, reports)
        summary.campus = campuses.get(summary.building_id or "", "not logged")
        summaries.append(summary)
    print(
        f"# Test round from {args.since}" + (f" to {args.until}" if args.until else "")
    )
    print(f"\n{len(summaries)} trips.\n")
    print(render_round(summaries, read_sus(args.sus) if args.sus else None))


if __name__ == "__main__":
    main()
