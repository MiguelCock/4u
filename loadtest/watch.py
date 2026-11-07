"""The live view for an event (A4): is everything well, and if not, which part?
Read-only, every 15 s, until Ctrl-C.

    uv run python watch.py            # or --once, to check it works

Problems show in red with the section of docs/event/runbook.md to use.
"""

import argparse
import subprocess
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path

import requests
from supabase import create_client

from loadtool import config
from loadtool.event import summarize_gateway, summarize_trip_logs
from loadtool.sampling import parse_stats_line
from run import running_model_machines

SERVICES = ("user", "map", "route", "navigation", "positioning", "ai-training")
CREDENTIALS = Path.home() / ".aws" / "credentials"
# AWS Academy lab sessions last about 4 hours.
CREDENTIALS_LAST = timedelta(hours=4)
RED, GREEN, DIM, OFF = "\033[31m", "\033[32m", "\033[2m", "\033[0m"


def remote(host: str, command: str, timeout: int = 20) -> str:
    try:
        return subprocess.run(
            ["ssh", "-n", "-o", "ConnectTimeout=10", host, command],
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        ).stdout
    except subprocess.TimeoutExpired:
        return ""


def machine_line(name: str, host: str) -> tuple[str, bool]:
    lines = remote(host, "sudo docker stats --no-stream --format '{{json .}}'")
    rows = [row for row in map(parse_stats_line, lines.splitlines()) if row]
    if not rows:
        return f"{name}: no answer", False
    cpu = sum(row["cpu_percent"] for row in rows)
    memory = sum(row["mem_mb"] for row in rows)
    # 2 vCPUs; the memory stop in the load test is at 2800 MB.
    healthy = memory < 2800
    return f"{name}: CPU {cpu:.0f}% of 200%, memory {memory:.0f} MB", healthy


def check(api: str, client) -> list[tuple[str, bool, str]]:
    """(line, healthy, runbook section) for each thing watched."""
    lines = []
    down = []
    for service in SERVICES:
        try:
            ok = requests.get(f"{api}/{service}/", timeout=8).ok
        except requests.RequestException:
            ok = False
        if not ok:
            down.append(service)
    lines.append(
        (
            "Services: all answering"
            if not down
            else f"Not answering: {', '.join(down)}",
            not down,
            "The server stops answering",
        )
    )

    gateway = summarize_gateway(
        remote(
            config.SERVER_HOST, "sudo docker logs --since 1m 4u-gateway-1 2>&1"
        ).splitlines()
    )
    lines.append(
        (
            (
                f"Last minute: {gateway['requests']} requests from "
                f"{gateway['addresses']} addresses, {gateway['server_errors']} server "
                f"errors, {gateway['rate_limited']} rate-limited"
            ),
            gateway["server_errors"] == 0 and gateway["rate_limited"] == 0,
            "The server stops answering",
        )
    )

    since = (datetime.now(UTC) - timedelta(minutes=2)).isoformat()
    logs = (
        client.table("navigation_logs")
        .select("debug,anchor_match_id")
        .gte("timestamp", since)
        .limit(2000)
        .execute()
        .data
    )
    trips = summarize_trip_logs(logs)
    if trips["photos"]:
        network = trips["network_p95_ms"] or 0
        server = trips["server_p95_ms"] or 0
        lines.append(
            (
                (
                    f"Photos, last 2 min: {trips['photos']}, "
                    f"{trips['matched_share']:.0%} matched, {trips['busy_share']:.0%} "
                    f"busy; p95 server {server / 1000:.1f} s, network "
                    f"{network / 1000:.1f} s"
                ),
                trips["busy_share"] < 0.2 and server < 2500 and network < 3000,
                "Photos are slow",
            )
        )
    else:
        lines.append(("Photos, last 2 min: none (nobody navigating)", True, ""))

    healthy_line, ok = machine_line("Main machine", config.SERVER_HOST)
    lines.append((healthy_line, ok, "The server stops answering"))
    models = running_model_machines()
    if not models:
        lines.append(
            (
                "Model machines: none running (start them for an event)",
                False,
                "A model machine is down",
            )
        )
    for number, instance in enumerate(models, 1):
        line, ok = machine_line(f"Model machine {number}", f"ec2-user@{instance}")
        lines.append((line, ok, "A model machine is down"))

    if CREDENTIALS.exists():
        left = (
            datetime.fromtimestamp(CREDENTIALS.stat().st_mtime, UTC)
            + CREDENTIALS_LAST
            - datetime.now(UTC)
        )
        minutes = int(left.total_seconds() // 60)
        lines.append(
            (
                f"AWS credentials: about {minutes} min left",
                minutes > 30,
                "The lab session is about to expire",
            )
        )
    return lines


def show(lines: list[tuple[str, bool, str]]) -> None:
    print(f"{DIM}{datetime.now().strftime('%H:%M:%S')}{OFF}")
    for line, healthy, section in lines:
        if healthy:
            print(f"{GREEN}ok{OFF}  {line}")
        else:
            print(f"{RED}!!  {line}{OFF}")
            if section:
                print(f'    {RED}runbook: "{section}"{OFF}')
    print()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    env = config.settings()
    client = create_client(env["SUPABASE_URL"], env["SUPABASE_SERVICE_ROLE_KEY"])
    while True:
        show(check(env["API_GATEWAY_URL"], client))
        if args.once:
            return
        time.sleep(15)


if __name__ == "__main__":
    main()
