import itertools

from loadtool.trips import choose_route, haversine_meters, ping_pong_index, start_offset


def test_trip_plays_there_and_back_without_jumping():
    played = [ping_pong_index(step, 4) for step in range(8)]
    assert played == [0, 1, 2, 3, 2, 1, 0, 1]
    assert all(abs(a - b) == 1 for a, b in itertools.pairwise(played))


def test_single_tick_trip():
    assert ping_pong_index(5, 1) == 0
    assert start_offset(3, 1) == 0


def test_users_start_at_different_places():
    assert len({start_offset(user, 77) for user in range(20)}) == 20


def _point(lat, status="verified"):
    return {"latitude": lat, "longitude": -75.5, "status": status}


def _edge(a, b):
    return {"anchor_point_a_id": a, "anchor_point_b_id": b}


def _route(id_, *stops):
    return {
        "id": id_,
        "start_anchor_id": stops[0],
        "end_anchor_id": stops[-1],
        "waypoint_anchor_ids": list(stops[1:-1]),
    }


# 0.00009 degrees is about 10 m.
POINTS = {
    "a": _point(6.2),
    "b": _point(6.20009),
    "c": _point(6.20018),
    "far": _point(6.2009),
    "pending": _point(6.20027, status="pending"),
}
EDGES = [_edge("a", "b"), _edge("b", "c"), _edge("c", "far"), _edge("c", "pending")]


def test_picks_the_longest_walkable_route():
    routes = [_route("short", "a", "b"), _route("long", "a", "b", "c")]
    assert choose_route(routes, POINTS, EDGES)["id"] == "long"


def test_skips_what_would_make_the_server_rewrite_the_route():
    routes = [
        _route("over-30-m", "c", "far"),
        _route("not-connected", "a", "c"),
        _route("not-verified", "c", "pending"),
        _route("other-campus", "a", "elsewhere"),
    ]
    assert choose_route(routes, POINTS, EDGES) is None


def test_haversine():
    assert abs(haversine_meters(6.2, -75.5, 6.20009, -75.5) - 10) < 0.5
