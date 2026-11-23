"""Counts how often the filter was told the user stood still while they were
walking, and the other way round (#310). A development tool, not part of
the app.

    uv run python scripts/stationary_check.py session.json [more.json ...]

Each session.json comes from scripts/export_session.py. Every log's
`debug` holds the phone's `gps_speed`, and `debug.correction.stationary`
is what the server decided for that tick. Movement is judged by the speed
alone: `debug.guidance` said "walking" on every tick of ten real walks,
standing or not.
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path

# At or above this the phone was walking.
WALKING_SPEED_MPS = 0.5
# Below this the phone was still.
STILL_SPEED_MPS = 0.3


@dataclass
class Counts:
    ticks: int = 0  # ticks with a correction
    stationary: int = 0  # told "standing still"
    false_stops: int = 0  # ...while walking
    missed_stops: int = 0  # slow but not told
    walking: int = 0  # walking ticks
    zero_speed_walking: int = 0  # walking, yet gps_speed exactly 0
    no_speed: int = 0  # gps_speed missing

    def add(self, other: Counts) -> None:
        for name in self.__dataclass_fields__:
            setattr(self, name, getattr(self, name) + getattr(other, name))


def count(logs) -> Counts:
    counts = Counts()
    for log in logs:
        debug = log.get("debug") or {}
        correction = debug.get("correction")
        if not correction or "stationary" not in correction:
            continue
        counts.ticks += 1
        speed = debug.get("gps_speed")
        stationary = bool(correction["stationary"])
        walking = speed is not None and speed >= WALKING_SPEED_MPS
        counts.stationary += stationary
        counts.walking += walking
        if speed is None:
            counts.no_speed += 1
        elif walking and speed == 0:
            counts.zero_speed_walking += 1
        if stationary and walking:
            counts.false_stops += 1
        if not stationary and speed is not None and speed < STILL_SPEED_MPS:
            counts.missed_stops += 1
    return counts


def _pct(part: int, whole: int) -> str:
    return f"{part} ({100 * part / whole:.0f} %)" if whole else str(part)


def report(name: str, c: Counts) -> str:
    return (
        f"{name}: {c.ticks} ticks, stationary {_pct(c.stationary, c.ticks)}, "
        f"false stops {_pct(c.false_stops, c.walking)} of walking ticks, "
        f"missed stops {c.missed_stops}, walking with speed 0 "
        f"{_pct(c.zero_speed_walking, c.walking)}, no speed {c.no_speed}"
    )


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    total = Counts()
    for path in sys.argv[1:]:
        data = json.loads(Path(path).read_text())
        counts = count(data["logs"])
        total.add(counts)
        print(report(data["session"]["id"][:8], counts))
    if len(sys.argv) > 2:
        print(report("total", total))


if __name__ == "__main__":
    main()
