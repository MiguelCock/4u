"""Per-endpoint wait from the gateway's own log (E2): p50 and p95 of how long
each endpoint took, as real phones saw it from the gateway. Read-only.

    uv run python endpoint_times.py --since 24h
"""

import argparse
import subprocess

from loadtool import config
from loadtool.event import endpoint_times
from loadtool.report import percentile


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--since", default="24h", help="as docker logs takes it")
    args = parser.parse_args()
    lines = subprocess.run(
        [
            "ssh",
            "-n",
            config.SERVER_HOST,
            f"sudo docker logs --since {args.since} 4u-gateway-1 2>&1",
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.splitlines()
    times = endpoint_times(lines)
    print("| Endpoint | Requests | p50 | p95 |")
    print("|---|---:|---:|---:|")
    for endpoint, seconds in sorted(
        times.items(), key=lambda kv: -percentile(kv[1], 0.95)
    ):
        print(
            f"| {endpoint} | {len(seconds)} | {percentile(seconds, 0.5):.2f} s "
            f"| {percentile(seconds, 0.95):.2f} s |"
        )


if __name__ == "__main__":
    main()
