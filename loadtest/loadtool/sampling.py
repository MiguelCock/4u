"""Reading `docker stats` output. Pure, so it's tested without a server."""

import json

_UNITS = {
    "B": 1 / 1024**2,
    "KIB": 1 / 1024,
    "KB": 1 / 1000,
    "MIB": 1,
    "MB": 1,
    "GIB": 1024,
    "GB": 1000,
}


def memory_mb(usage: str) -> float:
    """The used part of "312.5MiB / 3.8GiB", in MB."""
    used = usage.split("/")[0].strip()
    number = used.rstrip("BbIiKkMmGg ")
    unit = used[len(number) :].strip().upper()
    return float(number) * _UNITS.get(unit, 1)


def parse_stats_line(line: str) -> dict | None:
    """One `docker stats --format '{{json .}}'` line, or None if it isn't one."""
    try:
        row = json.loads(line)
        return {
            "name": row["Name"],
            "cpu_percent": float(row["CPUPerc"].rstrip("%")),
            "mem_mb": memory_mb(row["MemUsage"]),
        }
    except ValueError, KeyError, TypeError, AttributeError:
        return None
