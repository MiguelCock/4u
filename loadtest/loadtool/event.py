"""The event tools' logic (A4): reading trips' logs, the gateway's log, and a
route's readiness. Pure, so it's tested without a server."""

import math
import re
from collections import Counter

from .report import percentile

# A failure that isn't one: the phone skipped its photo because the server was
# busy (photoPaused in the app's test_walk.dart).
PAUSED = "server_busy"
# Further apart than this, photo matches get sparse (story B1).
MAX_SPACING_M = 15.0
MIN_PHOTOS = 3


def _p(values: list[float], fraction: float) -> float | None:
    return percentile(values, fraction)


def summarize_trip_logs(logs: list[dict]) -> dict:
    """navigation_logs rows of one or more trips: how photos went, and how much
    of each photo's time was the network rather than the server."""
    photos = matched = busy = paused = failed = 0
    phone_ms: list[float] = []
    server_ms: list[float] = []
    network_ms: list[float] = []
    for log in logs:
        debug = log.get("debug") or {}
        failure = debug.get("failure")
        if failure == PAUSED:
            paused += 1
            continue
        if failure:
            failed += 1
            continue
        phone = (debug.get("timing_ms") or {}).get("correct")
        if phone is None:
            continue
        photos += 1
        correction = debug.get("correction") or {}
        if log.get("anchor_match_id"):
            matched += 1
        if correction.get("server_busy"):
            busy += 1
        phone_ms.append(phone)
        server = correction.get("total_ms")
        if server is not None:
            server_ms.append(server)
            network_ms.append(max(0.0, phone - server))
    return {
        "photos": photos,
        "matched_share": matched / photos if photos else None,
        "busy_share": busy / photos if photos else None,
        "paused_ticks": paused,
        "failed_ticks": failed,
        "phone_p50_ms": _p(phone_ms, 0.5),
        "phone_p95_ms": _p(phone_ms, 0.95),
        "server_p95_ms": _p(server_ms, 0.95),
        "network_p50_ms": _p(network_ms, 0.5),
        "network_p95_ms": _p(network_ms, 0.95),
    }


_GATEWAY_LINE = re.compile(r'^(\S+) .*?"(\S+) (\S+) [^"]*" (\d{3}) ')


def summarize_gateway(lines: list[str]) -> dict:
    """nginx access-log lines: requests, server errors, rate limits, and from how
    many addresses (a whole campus Wi-Fi can share one)."""
    statuses: Counter[int] = Counter()
    addresses: set[str] = set()
    for line in lines:
        match = _GATEWAY_LINE.match(line)
        if not match:
            continue
        address, _method, path, status = match.groups()
        if path.startswith("/user/app-version"):
            continue  # the live view's own health checks
        addresses.add(address)
        statuses[int(status)] += 1
    return {
        "requests": sum(statuses.values()),
        "server_errors": sum(n for s, n in statuses.items() if s >= 500),
        "rate_limited": statuses[429],
        "addresses": len(addresses),
    }


def meters_between(a: dict, b: dict) -> float:
    lat = math.radians((a["latitude"] + b["latitude"]) / 2)
    dy = (a["latitude"] - b["latitude"]) * 111_320
    dx = (a["longitude"] - b["longitude"]) * 111_320 * math.cos(lat)
    return math.hypot(dx, dy)


def route_problems(
    path: list[dict],
    photos_by_point: dict[str, list[str]],
    connected: set[frozenset],
    indexed_photos: set[str],
) -> tuple[list[str], list[str], list[float]]:
    """In path order: what stops the route working (blockers), what makes photo
    matches weaker (warnings), and the gaps between points."""
    problems = []
    warnings = []
    gaps = []
    for index, point in enumerate(path):
        name = point.get("location_description") or f"point {point['id'][:8]}"
        if point.get("status") != "verified":
            problems.append(f"{name}: not verified ({point.get('status')})")
        photos = photos_by_point.get(point["id"], [])
        if len(photos) < MIN_PHOTOS:
            warnings.append(f"{name}: {len(photos)} photos, fewer than {MIN_PHOTOS}")
        missing = [p for p in photos if p not in indexed_photos]
        if point.get("status") == "verified" and missing:
            problems.append(f"{name}: {len(missing)} photos not searchable")
        if index:
            previous = path[index - 1]
            gap = meters_between(previous, point)
            gaps.append(gap)
            if frozenset((previous["id"], point["id"])) not in connected:
                problems.append(f"{name}: not connected to the point before it")
            if gap > MAX_SPACING_M:
                warnings.append(f"{name}: {gap:.0f} m from the point before it")
    return problems, warnings, gaps
