from loadtool.event import (
    meters_between,
    route_problems,
    summarize_gateway,
    summarize_trip_logs,
)


def _log(phone=None, server=None, matched=False, busy=False, failure=None):
    debug = {}
    if phone is not None:
        debug["timing_ms"] = {"capture": 900, "correct": phone}
        debug["correction"] = {"total_ms": server, "server_busy": busy}
    if failure:
        debug["failure"] = failure
    return {"debug": debug, "anchor_match_id": "a" if matched else None}


def test_trip_logs_split_the_network_from_the_server():
    logs = [
        _log(1300, 800, matched=True),
        _log(2000, 900, matched=True),
        _log(1500, 1600, busy=True),  # a clock quirk never makes it negative
        _log(failure="server_busy"),
        _log(failure="api_0"),
        {"debug": {}, "anchor_match_id": None},  # a raw tick with no photo
    ]
    summary = summarize_trip_logs(logs)
    assert summary["photos"] == 3
    assert summary["matched_share"] == 2 / 3
    assert summary["busy_share"] == 1 / 3
    assert summary["paused_ticks"] == 1
    assert summary["failed_ticks"] == 1
    assert summary["network_p50_ms"] == 500
    assert summary["network_p95_ms"] == 1100


def test_no_photos_gives_no_shares():
    summary = summarize_trip_logs([_log(failure="api_0")])
    assert summary["photos"] == 0
    assert summary["matched_share"] is None


def test_gateway_lines_count_errors_limits_and_addresses():
    lines = [
        '1.1.1.1 - - [07/Nov/2026:18:02:45 +0000] "POST /positioning/correct_position HTTP/1.1" 200 512 "-" "x"',
        '1.1.1.1 - - [07/Nov/2026:18:02:46 +0000] "GET /map/anchor-points HTTP/1.1" 502 0 "-" "x"',
        '2.2.2.2 - - [07/Nov/2026:18:02:47 +0000] "POST /positioning/correct_position HTTP/1.1" 429 0 "-" "x"',
        '3.3.3.3 - - [07/Nov/2026:18:02:48 +0000] "GET /user/app-version HTTP/1.1" 200 9 "-" "curl"',
        "/docker-entrypoint.sh: Configuration complete",
    ]
    summary = summarize_gateway(lines)
    assert summary == {
        "requests": 3,
        "server_errors": 1,
        "rate_limited": 1,
        "addresses": 2,
    }


def _point(id, lat, status="verified"):
    return {
        "id": id,
        "latitude": lat,
        "longitude": -75.5,
        "status": status,
        "location_description": f"P{id}",
    }


def test_a_ready_route_has_no_problems():
    path = [_point("a", 6.2), _point("b", 6.20005), _point("c", 6.2001)]
    photos = {p["id"]: [f"{p['id']}{n}" for n in range(3)] for p in path}
    connected = {frozenset("ab"), frozenset("bc")}
    indexed = {photo for ids in photos.values() for photo in ids}
    problems, warnings, gaps = route_problems(path, photos, connected, indexed)
    assert problems == []
    assert warnings == []
    assert [round(gap) for gap in gaps] == [6, 6]


def test_route_problems_name_each_point():
    path = [_point("a", 6.2), _point("b", 6.2003, status="pending")]
    photos = {"a": ["a1", "a2", "a3"], "b": ["b1"]}
    problems, warnings, _ = route_problems(path, photos, set(), {"a1", "a2"})
    assert problems == [
        "Pa: 1 photos not searchable",
        "Pb: not verified (pending)",
        "Pb: not connected to the point before it",
    ]
    assert warnings == [
        "Pb: 1 photos, fewer than 3",
        "Pb: 33 m from the point before it",
    ]


def test_meters_between():
    assert round(meters_between(_point("a", 6.2), _point("b", 6.2001))) == 11
