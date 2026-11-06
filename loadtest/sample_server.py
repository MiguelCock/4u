"""Records CPU and memory per container during a run, into a CSV.

    uv run python sample_server.py out.csv     # until stopped

One long SSH connection: opening one per sample over SSM would itself be slow.
"""

import csv
import subprocess
import sys
import time

from loadtool import config
from loadtool.sampling import parse_stats_line

REMOTE = (
    "while true; do sudo docker stats --no-stream --format '{{json .}}'; sleep 10; done"
)


def main(out: str) -> None:
    process = subprocess.Popen(
        ["ssh", config.SERVER_HOST, REMOTE],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    with open(out, "w", newline="") as file:
        writer = csv.DictWriter(file, ["time", "name", "cpu_percent", "mem_mb"])
        writer.writeheader()
        for line in process.stdout:
            row = parse_stats_line(line)
            if row:
                writer.writerow({"time": round(time.time()), **row})
                file.flush()


if __name__ == "__main__":
    main(sys.argv[1])
