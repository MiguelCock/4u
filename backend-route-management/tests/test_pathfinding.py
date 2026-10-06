from app.pathfinding import shortest_path


def _conn(a, b, distance=None):
    return {"anchor_point_a_id": a, "anchor_point_b_id": b, "distance_meters": distance}


def test_direct_edge():
    connections = [_conn("a", "b", 10.0)]
    assert shortest_path(connections, "a", "b") == ["a", "b"]


def test_same_start_and_end():
    connections = [_conn("a", "b", 10.0)]
    assert shortest_path(connections, "a", "a") == ["a"]


def test_multi_hop_picks_shortest_route():
    # a -> b -> c is 1+1=2, a -> c direct is 100 - must pick the cheaper path.
    connections = [
        _conn("a", "b", 1.0),
        _conn("b", "c", 1.0),
        _conn("a", "c", 100.0),
    ]
    assert shortest_path(connections, "a", "c") == ["a", "b", "c"]


def test_disconnected_graph_returns_none():
    connections = [_conn("a", "b", 10.0), _conn("x", "y", 5.0)]
    assert shortest_path(connections, "a", "y") is None


def test_unknown_anchor_returns_none():
    connections = [_conn("a", "b", 10.0)]
    assert shortest_path(connections, "a", "ghost") is None


def test_missing_distance_meters_does_not_crash():
    connections = [_conn("a", "b", None), _conn("b", "c", 1.0)]
    # Still finds a path even though one edge has no weight recorded.
    assert shortest_path(connections, "a", "c") == ["a", "b", "c"]


def test_connection_is_undirected():
    connections = [_conn("a", "b", 5.0)]
    assert shortest_path(connections, "b", "a") == ["b", "a"]
