"""Replays a logged navigation session through this service's filter and
scores it against ground truth. A development tool, not part of the app.

For test walks the admin follows the planned route exactly, so distance
from the route is correction error. With "I'm here" checkpoints tapped at
the start, each corner and the destination, the true position at every
tick is also known along the route (steady pace between taps), which
catches forward/backward jumps too.

    uv run python scripts/replay.py session.json
    uv run python scripts/replay.py session.json --set gps_bias_sigma_m=4
    uv run python scripts/replay.py session.json \\
        --grid gps_bias_sigma_m=0,1.5,2.5,4 gps_bias_tau_s=60,120,300

session.json comes from scripts/export_session.py (see docs/TUNING.md).
"""

import argparse
import asyncio
import dataclasses
import itertools
import json
import math
import statistics
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import session_store as session_store_module
from app.matching import MatchConfig
from app.session_store import SessionStore

CORNER_TURN_DEGREES = 30.0  # same rule as the app's routeCorners


class _Plane:
    def __init__(self, lat0: float, lng0: float):
        self.lat0, self.lng0 = lat0, lng0
        self.k = math.cos(math.radians(lat0))

    def xy(self, lat: float, lng: float) -> tuple[float, float]:
        return ((lng - self.lng0) * 111320 * self.k, (lat - self.lat0) * 111320)


def _bearing(a, b) -> float:
    return math.degrees(math.atan2(b[0] - a[0], b[1] - a[1])) % 360


def _turn(a: float, b: float) -> float:
    return (b - a + 180) % 360 - 180


def route_corners(points) -> list[int]:
    if len(points) < 2:
        return list(range(len(points)))
    corners = [0]
    for i in range(1, len(points) - 1):
        turn = _turn(
            _bearing(points[corners[-1]], points[i]),
            _bearing(points[i], points[i + 1]),
        )
        if abs(turn) > CORNER_TURN_DEGREES:
            corners.append(i)
    return corners + [len(points) - 1]


class Route:
    def __init__(self, points):
        self.points = points
        self.cum = [0.0]
        for a, b in itertools.pairwise(points):
            self.cum.append(self.cum[-1] + math.dist(a, b))

    def cross_track(self, p) -> float:
        best = math.inf
        for a, b in itertools.pairwise(self.points):
            dx, dy = b[0] - a[0], b[1] - a[1]
            length2 = dx * dx + dy * dy
            t = 0.0
            if length2:
                t = max(
                    0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / length2)
                )
            best = min(best, math.dist(p, (a[0] + t * dx, a[1] + t * dy)))
        return best

    def at(self, s: float):
        s = max(0.0, min(self.cum[-1], s))
        for k in range(len(self.points) - 1):
            if s <= self.cum[k + 1] or k == len(self.points) - 2:
                span = self.cum[k + 1] - self.cum[k] or 1.0
                f = (s - self.cum[k]) / span
                a, b = self.points[k], self.points[k + 1]
                return (a[0] + f * (b[0] - a[0]), a[1] + f * (b[1] - a[1]))


def _ts(value: str) -> float:
    return datetime.fromisoformat(value).timestamp()


def load(path: str):
    data = json.loads(Path(path).read_text())
    anchors = {a["id"]: a for a in data["anchors"]}
    route = data["route"]
    ids = [
        route["start_anchor_id"],
        *(route.get("waypoint_anchor_ids") or []),
        route["end_anchor_id"],
    ]
    start = anchors[ids[0]]
    plane = _Plane(start["latitude"], start["longitude"])
    points = [plane.xy(anchors[i]["latitude"], anchors[i]["longitude"]) for i in ids]
    logs = sorted(data["logs"], key=lambda log: log["timestamp"])
    return data, anchors, plane, Route(points), logs


def photo_time(log) -> float:
    """When the tick's photo and GPS fix were taken: `debug.photo_at`, or
    for older logs the POST time minus the capture and round-trip time. The
    log is written ~5 s later, and scoring at that time put the truth ~6 m
    ahead of where the user was."""
    debug = log.get("debug") or {}
    if debug.get("photo_at"):
        return _ts(debug["photo_at"])
    timing = debug.get("timing_ms") or {}
    lag_ms = (timing.get("capture") or 0) + (timing.get("correct") or 0)
    return _ts(log["timestamp"]) - lag_ms / 1000


def checkpoint_truth(logs, route: Route):
    """(time, along-route distance) for each checkpoint tap, or []."""
    corners = route_corners(route.points)
    taps = {}
    for log in logs:
        for event in (log.get("debug") or {}).get("events") or []:
            if event.get("type") == "checkpoint" and event.get("index") is not None:
                taps[int(event["index"])] = _ts(event["at"])
    return sorted(
        (taps[i], route.cum[corners[i]]) for i in taps if 0 <= i < len(corners)
    )


def truth_at(t: float, taps, route: Route):
    if len(taps) < 2 or t < taps[0][0] or t > taps[-1][0]:
        return None
    for (t0, s0), (t1, s1) in itertools.pairwise(taps):
        if t0 <= t <= t1:
            f = (t - t0) / (t1 - t0) if t1 > t0 else 0.0
            return route.at(s0 + f * (s1 - s0))
    return None


async def replay(logs, anchors, config: MatchConfig):
    clock = [0.0]
    session_store_module.time.monotonic = lambda: clock[0]
    store = SessionStore()
    out = {}
    for log in logs:
        debug = log.get("debug") or {}
        correction = debug.get("correction")
        if correction is None:
            continue
        clock[0] = photo_time(log)
        candidates = []
        for c in correction.get("candidates") or []:
            anchor = anchors.get(c.get("anchor_id"))
            if anchor is None:
                continue
            candidates.append(
                {
                    "anchor_point_id": c["anchor_id"],
                    "photo_id": c.get("photo_id"),
                    "latitude": anchor["latitude"],
                    "longitude": anchor["longitude"],
                    "score": c["score"],
                    "heading": c.get("photo_heading"),
                }
            )
        lat, lng = log["gps_lat"], log["gps_long"]
        async with store.get_lock("replay", lat, lng):
            result = await store.correct(
                "replay",
                lat=lat,
                lng=lng,
                accuracy=log.get("gps_accuracy") or 10.0,
                candidates=candidates,
                compass_heading=correction.get("compass"),
                gps_time=debug.get("gps_time"),
                config=config,
            )
        out[log["id"]] = (result.corrected_lat, result.corrected_long)
    return out


def _summary(values) -> str:
    if not values:
        return "-"
    v = sorted(values)
    return (
        f"mean {statistics.mean(v):5.2f}  median {statistics.median(v):5.2f}  "
        f"p90 {v[min(len(v) - 1, int(0.9 * len(v)))]:5.2f}  max {v[-1]:5.2f}  (n={len(v)})"
    )


def score(logs, plane, route, taps, positions):
    """Per-source (cross-track errors, 2D checkpoint errors)."""
    sources = {"raw": {}, "logged": {}, "replay": {}}
    for log in logs:
        if log["id"] not in positions:
            continue
        t = photo_time(log)
        p = {
            "raw": (log["gps_lat"], log["gps_long"]),
            "logged": (log["corrected_lat"], log["corrected_long"]),
            "replay": positions[log["id"]],
        }
        truth = truth_at(t, taps, route)
        for name, (lat, lng) in p.items():
            if lat is None:
                continue
            xy = plane.xy(lat, lng)
            cross, full = (
                sources[name].setdefault("x", []),
                sources[name].setdefault("2d", []),
            )
            cross.append(route.cross_track(xy))
            if truth is not None:
                full.append(math.dist(xy, truth))
    return sources


def checkpoint_errors(logs, plane, route):
    """Per tapped checkpoint: raw GPS error, and the corrected position's
    error as recorded at the tap (the app now records it with the latest
    correction offset applied to the live fix)."""
    corners = route_corners(route.points)
    rows = []
    for log in logs:
        for event in (log.get("debug") or {}).get("events") or []:
            if event.get("type") != "checkpoint" or event.get("index") is None:
                continue
            index = int(event["index"])
            if not 0 <= index < len(corners):
                continue
            truth = route.points[corners[index]]
            errors = {
                name: math.dist(plane.xy(*event[name]), truth)
                for name in ("raw", "corrected")
                if event.get(name)
            }
            rows.append((index, errors, event.get("correction_age_s")))
    return sorted(rows, key=lambda row: row[0])


def _parse(pairs):
    out = {}
    for pair in pairs or []:
        key, _, value = pair.partition("=")
        out[key] = value
    return out


def _config(overrides: dict) -> MatchConfig:
    base = MatchConfig()
    fields = {f.name: f.type for f in dataclasses.fields(MatchConfig)}
    values = {}
    for key, value in overrides.items():
        if key not in fields:
            raise SystemExit(f"unknown setting {key}; one of {', '.join(fields)}")
        values[key] = int(value) if fields[key] in (int, "int") else float(value)
    return dataclasses.replace(base, **values)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("session")
    parser.add_argument("--set", nargs="*", default=[], help="setting=value")
    parser.add_argument("--grid", nargs="*", default=[], help="setting=v1,v2,...")
    args = parser.parse_args()

    data, anchors, plane, route, logs = load(args.session)
    taps = checkpoint_truth(logs, route)
    print(
        f"session {data['session']['id']}: {len(logs)} ticks, route {route.cum[-1]:.0f} m, {len(taps)} checkpoints"
    )
    for index, errors, age in checkpoint_errors(logs, plane, route):
        line = "  ".join(f"{k} {v:5.1f} m" for k, v in errors.items())
        aged = f"  (correction {age:.1f} s old)" if age is not None else ""
        print(f"checkpoint {index}: {line}{aged}")
    fixed = _parse(args.set)
    grid = {k: v.split(",") for k, v in _parse(args.grid).items()}
    combos = [
        dict(zip(grid, values)) for values in itertools.product(*grid.values())
    ] or [{}]
    first = True
    for combo in combos:
        config = _config({**fixed, **combo})
        positions = asyncio.run(replay(logs, anchors, config))
        sources = score(logs, plane, route, taps, positions)
        if first:
            for name in ("raw", "logged"):
                print(f"{name:7} off route {_summary(sources[name].get('x'))}")
                if taps:
                    print(f"{'':7} 2D      {_summary(sources[name].get('2d'))}")
            first = False
        label = (
            " ".join(f"{k}={v}" for k, v in {**fixed, **combo}.items()) or "defaults"
        )
        print(f"replay  off route {_summary(sources['replay'].get('x'))}  [{label}]")
        if taps:
            print(f"{'':7} 2D      {_summary(sources['replay'].get('2d'))}")


if __name__ == "__main__":
    main()
