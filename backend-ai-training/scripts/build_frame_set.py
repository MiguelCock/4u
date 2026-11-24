"""Builds a labelled set of live frames for benchmark_models.py --frames
(#122, #182). A development tool, not part of the service. Read-only.

Admin test walks keep each frame (navigation_logs.raw_image_url) and tap
"I'm at ..." at the start, each corner and the destination, so where the
user really was at each photo is known: walking the route at a steady pace
between taps (the same truth backend-positioning/scripts/replay.py uses).
Each frame is kept with its raw GPS fix, the camera's compass heading and
that true position; the frames and the photos of every anchor near them
are downloaded.

    set -a; . ../packages/.env; set +a
    uv run python scripts/build_frame_set.py frames/

writes frames/set.json (anchors, photos, frames), frames/frames/<log id>.jpg
and frames/photos/<photo id>.jpg. Keep it out of the repo: the frames are
real walks.
"""

import argparse
import itertools
import json
import math
import os
import sys
import urllib.request
from datetime import UTC, datetime, timedelta
from pathlib import Path

from supabase import create_client

# Walks need at least this many checkpoint taps for a true position.
MIN_TAPS = 2
# Anchors this close to some frame's GPS fix are what a search could find.
NEAR_M = 60.0
CORNER_TURN_DEGREES = 30.0  # the app's routeCorners
# Campus local time, for the day/dusk split (Colombia, no DST).
LOCAL = timedelta(hours=-5)


def _ts(value: str) -> float:
    return datetime.fromisoformat(value).timestamp()


class Plane:
    def __init__(self, lat0: float, lng0: float):
        self.lat0, self.lng0 = lat0, lng0

    def xy(self, lat: float, lng: float) -> tuple[float, float]:
        k = 111_320.0
        return (
            (lng - self.lng0) * k * math.cos(math.radians(self.lat0)),
            (lat - self.lat0) * k,
        )

    def latlng(self, x: float, y: float) -> tuple[float, float]:
        k = 111_320.0
        return (
            self.lat0 + y / k,
            self.lng0 + x / (k * math.cos(math.radians(self.lat0))),
        )


def _bearing(a, b) -> float:
    return math.degrees(math.atan2(b[0] - a[0], b[1] - a[1])) % 360


def _turn(a: float, b: float) -> float:
    return (b - a + 180) % 360 - 180


def route_corners(points) -> list[int]:
    """The route's stops for checkpoints: its ends and every turn over 30
    degrees, as the app's routeCorners."""
    if len(points) < 2:
        return list(range(len(points)))
    corners = [0]
    for i in range(1, len(points) - 1):
        turn = _turn(
            _bearing(points[corners[-1]], points[i]), _bearing(points[i], points[i + 1])
        )
        if abs(turn) > CORNER_TURN_DEGREES:
            corners.append(i)
    return corners + [len(points) - 1]


def _cumulative(points) -> list[float]:
    cum = [0.0]
    for a, b in itertools.pairwise(points):
        cum.append(cum[-1] + math.dist(a, b))
    return cum


def _at(points, cum, s: float):
    s = max(0.0, min(cum[-1], s))
    for k in range(len(points) - 1):
        if s <= cum[k + 1] or k == len(points) - 2:
            span = cum[k + 1] - cum[k] or 1.0
            f = (s - cum[k]) / span
            a, b = points[k], points[k + 1]
            return (a[0] + f * (b[0] - a[0]), a[1] + f * (b[1] - a[1]))
    return points[-1]


def checkpoint_taps(logs, points) -> list[tuple[float, float]]:
    """(time, distance along the route) for each tapped checkpoint."""
    corners = route_corners(points)
    cum = _cumulative(points)
    taps = {}
    for log in logs:
        for event in (log.get("debug") or {}).get("events") or []:
            if event.get("type") == "checkpoint" and event.get("index") is not None:
                taps[int(event["index"])] = _ts(event["at"])
    return sorted((taps[i], cum[corners[i]]) for i in taps if 0 <= i < len(corners))


def truth_at(t: float, taps, points):
    """Where the user was at [t]: a steady pace between two taps."""
    if len(taps) < 2 or t < taps[0][0] or t > taps[-1][0]:
        return None
    cum = _cumulative(points)
    for (t0, s0), (t1, s1) in itertools.pairwise(taps):
        if t0 <= t <= t1:
            f = (t - t0) / (t1 - t0) if t1 > t0 else 0.0
            return _at(points, cum, s0 + f * (s1 - s0))
    return None


def photo_time(log) -> float:
    debug = log.get("debug") or {}
    if debug.get("photo_at"):
        return _ts(debug["photo_at"])
    timing = debug.get("timing_ms") or {}
    lag_ms = (timing.get("capture") or 0) + (timing.get("correct") or 0)
    return _ts(log["timestamp"]) - lag_ms / 1000


def label_frames(session, logs, route, anchors) -> list[dict]:
    """The frames of one walk that can be labelled, each with its fix, the
    camera heading and its true position."""
    ids = [
        route["start_anchor_id"],
        *(route.get("waypoint_anchor_ids") or []),
        route["end_anchor_id"],
    ]
    if any(i not in anchors for i in ids):
        return []
    start = anchors[ids[0]]
    plane = Plane(start["latitude"], start["longitude"])
    points = [plane.xy(anchors[i]["latitude"], anchors[i]["longitude"]) for i in ids]
    taps = checkpoint_taps(logs, points)
    if len(taps) < MIN_TAPS:
        return []
    out = []
    for log in logs:
        if not log.get("raw_image_url"):
            continue
        t = photo_time(log)
        truth = truth_at(t, taps, points)
        if truth is None:
            continue
        correction = (log.get("debug") or {}).get("correction") or {}
        lat, lng = plane.latlng(*truth)
        local = datetime.fromtimestamp(t, UTC) + LOCAL
        out.append(
            {
                "id": log["id"],
                "session_id": session["id"],
                "url": log["raw_image_url"],
                "gps_lat": log["gps_lat"],
                "gps_lng": log["gps_long"],
                "gps_accuracy": log.get("gps_accuracy"),
                "heading": correction.get("compass"),
                "truth_lat": lat,
                "truth_lng": lng,
                "local_hour": local.hour + local.minute / 60,
            }
        )
    return out


def _all(query_for):
    rows, start = [], 0
    while True:
        page = query_for().range(start, start + 999).execute().data
        rows += page
        if len(page) < 1000:
            return rows
        start += 1000


def _download(url: str, path: Path) -> bool:
    if path.exists():
        return True
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            path.write_bytes(response.read())
        return True
    except OSError as error:
        print(f"skipped {url}: {error}", file=sys.stderr)
        return False


def _near(frame, anchor) -> bool:
    plane = Plane(frame["gps_lat"], frame["gps_lng"])
    return (
        math.dist((0, 0), plane.xy(anchor["latitude"], anchor["longitude"])) <= NEAR_M
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("out_dir")
    args = parser.parse_args()
    out = Path(args.out_dir)
    (out / "frames").mkdir(parents=True, exist_ok=True)
    (out / "photos").mkdir(parents=True, exist_ok=True)
    client = create_client(
        os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    )

    framed = {
        r["session_id"]
        for r in _all(
            lambda: (
                client.table("navigation_logs")
                .select("session_id")
                .not_.is_("raw_image_url", "null")
                .order("id")
            )
        )
    }
    anchors = {
        a["id"]: a
        for a in _all(lambda: client.table("anchor_points").select("*").order("id"))
    }
    photos = _all(lambda: client.table("anchor_point_photos").select("*").order("id"))
    frames = []
    for session_id in sorted(framed):
        session = (
            client.table("navigation_sessions")
            .select("*")
            .eq("id", session_id)
            .execute()
            .data[0]
        )
        if not session.get("route_id"):
            continue
        route = (
            client.table("routes")
            .select("*")
            .eq("id", session["route_id"])
            .execute()
            .data
        )
        if not route:
            continue
        logs = _all(
            lambda s=session_id: (
                client.table("navigation_logs")
                .select("*")
                .eq("session_id", s)
                .order("timestamp")
                .order("id")
            )
        )
        labelled = label_frames(session, logs, route[0], anchors)
        print(f"{session_id[:8]}: {len(labelled)} labelled frames")
        frames += labelled

    frames = [
        f for f in frames if _download(f["url"], out / "frames" / f"{f['id']}.jpg")
    ]
    near = {a for a in anchors if any(_near(f, anchors[a]) for f in frames)}
    kept_photos = [
        p
        for p in photos
        if p["anchor_point_id"] in near
        and p.get("image_url")
        and _download(p["image_url"], out / "photos" / f"{p['id']}.jpg")
    ]
    (out / "set.json").write_text(
        json.dumps(
            {
                "anchors": [anchors[a] for a in sorted(near)],
                "photos": kept_photos,
                "frames": frames,
            },
            default=str,
        )
    )
    print(
        f"{len(frames)} frames, {len(near)} anchors, {len(kept_photos)} photos -> {out}"
    )


if __name__ == "__main__":
    main()
