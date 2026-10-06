import heapq

# A missing distance_meters shouldn't crash the search - treat it as a very
# costly (but not infinite) edge rather than skipping the connection
# entirely, so a lopsided graph still finds *a* path when one exists.
_DEFAULT_WEIGHT_METERS = 1_000_000.0


def _build_adjacency(connections: list[dict]) -> dict[str, list[tuple[str, float]]]:
    # anchor_point_connections is undirected (see backend-map-management/
    # CLAUDE.md) - every row contributes an edge in both directions.
    graph: dict[str, list[tuple[str, float]]] = {}
    for conn in connections:
        a, b = conn["anchor_point_a_id"], conn["anchor_point_b_id"]
        weight = conn.get("distance_meters")
        if weight is None:
            weight = _DEFAULT_WEIGHT_METERS
        graph.setdefault(a, []).append((b, weight))
        graph.setdefault(b, []).append((a, weight))
    return graph


def shortest_path(
    connections: list[dict], start_id: str, end_id: str
) -> list[str] | None:
    """Dijkstra's algorithm over the anchor_point_connections graph.

    Returns the full path [start_id, ..., end_id] (inclusive of both ends),
    or None if start_id and end_id aren't connected by any chain of edges.
    """
    if start_id == end_id:
        return [start_id]

    graph = _build_adjacency(connections)
    if start_id not in graph or end_id not in graph:
        return None

    distances: dict[str, float] = {start_id: 0.0}
    previous: dict[str, str] = {}
    visited: set[str] = set()
    queue: list[tuple[float, str]] = [(0.0, start_id)]

    while queue:
        dist, node = heapq.heappop(queue)
        if node in visited:
            continue
        visited.add(node)
        if node == end_id:
            break
        for neighbor, weight in graph.get(node, []):
            if neighbor in visited:
                continue
            candidate = dist + weight
            if candidate < distances.get(neighbor, float("inf")):
                distances[neighbor] = candidate
                previous[neighbor] = node
                heapq.heappush(queue, (candidate, neighbor))

    if end_id not in visited:
        return None

    path = [end_id]
    while path[-1] != start_id:
        path.append(previous[path[-1]])
    path.reverse()
    return path
