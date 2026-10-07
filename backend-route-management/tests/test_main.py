from unittest.mock import MagicMock, patch

import pytest
from fastapi.testclient import TestClient

from app.main import app, get_caller_id

client = TestClient(app)


@pytest.fixture(autouse=True)
def _clear_overrides():
    yield
    app.dependency_overrides.clear()


def _as_caller(caller_id: str) -> None:
    app.dependency_overrides[get_caller_id] = lambda: caller_id


_ADMIN_ROW = [{"role_id": 2}]
_USER_ROW = [{"role_id": 1}]


def test_root():
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {"service": "backend-route-management", "status": "ok"}


def test_no_token_is_rejected():
    response = client.get("/routes")
    assert response.status_code == 401


def test_garbage_token_is_rejected():
    with patch("app.main.db.get_user_id_from_token", side_effect=Exception("bad")):
        response = client.get("/routes", headers={"Authorization": "Bearer garbage"})
    assert response.status_code == 401


def _mock_select_eq_result(rows):
    mock_client = MagicMock()
    mock_client.table.return_value.select.return_value.eq.return_value.execute.return_value.data = rows
    return mock_client


def _mock_select_result(rows):
    mock_client = MagicMock()
    mock_client.table.return_value.select.return_value.execute.return_value.data = rows
    return mock_client


def _mock_insert_result(rows):
    mock_client = MagicMock()
    mock_client.table.return_value.insert.return_value.execute.return_value.data = rows
    return mock_client


def _mock_delete_eq_result():
    mock_client = MagicMock()
    mock_client.table.return_value.delete.return_value.eq.return_value.execute.return_value.data = []
    mock_client.table.return_value.select.return_value.eq.return_value.execute.return_value.data = _ADMIN_ROW
    return mock_client


def _mock_multi_table_client(table_mocks):
    mock_client = MagicMock()
    mock_client.table.side_effect = lambda name: table_mocks[name]
    return mock_client


_ROUTE_ROW = {
    "id": "1",
    "building_id": "b1",
    "name": "Main entrance to elevator",
    "start_anchor_id": "a1",
    "end_anchor_id": "a2",
    "waypoint_anchor_ids": [],
    "created_by": "u1",
}


def test_get_route_returns_single_object():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_eq_result([_ROUTE_ROW])):
        response = client.get("/routes/1")
    assert response.status_code == 200
    assert response.json()["id"] == "1"


def test_get_route_404_when_missing():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_eq_result([])):
        response = client.get("/routes/missing")
    assert response.status_code == 404


def test_list_routes():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_result([_ROUTE_ROW])):
        response = client.get("/routes")
    assert response.status_code == 200
    assert response.json() == [_ROUTE_ROW]


# --- POST /routes: any authenticated user, created_by forced -------------


def test_create_route_allowed_for_non_admin():
    _as_caller("u1")
    payload = {
        "building_id": "b1",
        "name": "New route",
        "start_anchor_id": "a1",
        "end_anchor_id": "a2",
    }
    mock_client = _mock_insert_result(
        [{**payload, "id": "2", "waypoint_anchor_ids": [], "created_by": "u1"}]
    )
    with patch("app.main.db.client", mock_client):
        response = client.post("/routes", json=payload)
    assert response.status_code == 200


def test_create_route_forces_created_by():
    _as_caller("u1")
    payload = {
        "building_id": "b1",
        "name": "New route",
        "start_anchor_id": "a1",
        "end_anchor_id": "a2",
        "created_by": "someone-else",
    }
    mock_client = _mock_insert_result([{}])
    with patch("app.main.db.client", mock_client):
        response = client.post("/routes", json=payload)
    assert response.status_code == 200
    insert_payload = mock_client.table.return_value.insert.call_args.args[0]
    assert insert_payload["created_by"] == "u1"


# --- DELETE /routes/{id}: admin only (unchanged) --------------------------


def test_delete_route_forbidden_for_non_admin():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_eq_result(_USER_ROW)):
        response = client.delete("/routes/1")
    assert response.status_code == 403


def test_delete_route_returns_ok():
    _as_caller("admin1")
    mock_client = _mock_delete_eq_result()
    with patch("app.main.db.client", mock_client):
        response = client.delete("/routes/1")
    assert response.status_code == 200
    assert response.json() == "ok"
    mock_client.table.return_value.delete.return_value.eq.assert_called_once_with(
        "id", "1"
    )


# --- POST /routes/find_or_create ------------------------------------------


def test_find_or_create_rejects_same_start_and_end():
    _as_caller("u1")
    response = client.post(
        "/routes/find_or_create",
        json={"start_anchor_id": "a1", "end_anchor_id": "a1"},
    )
    assert response.status_code == 400


def test_find_or_create_returns_existing_match():
    _as_caller("u1")
    routes_table = MagicMock()
    routes_table.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = [
        _ROUTE_ROW
    ]
    mock_client = _mock_multi_table_client({"routes": routes_table})
    with patch("app.main.db.client", mock_client):
        response = client.post(
            "/routes/find_or_create",
            json={"start_anchor_id": "a1", "end_anchor_id": "a2"},
        )
    assert response.status_code == 200
    assert response.json() == _ROUTE_ROW
    routes_table.insert.assert_not_called()


def test_find_or_create_computes_and_inserts_new_route():
    _as_caller("u1")
    routes_table = MagicMock()
    routes_table.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = []
    routes_table.insert.return_value.execute.return_value.data = [
        {
            "id": "new-route",
            "building_id": "b1",
            "name": "front door to back door",
            "start_anchor_id": "a1",
            "end_anchor_id": "a3",
            "waypoint_anchor_ids": ["a2"],
            "created_by": "u1",
        }
    ]
    connections_table = MagicMock()
    connections_table.select.return_value.execute.return_value.data = [
        {"anchor_point_a_id": "a1", "anchor_point_b_id": "a2", "distance_meters": 5.0},
        {"anchor_point_a_id": "a2", "anchor_point_b_id": "a3", "distance_meters": 5.0},
    ]
    anchors_table = MagicMock()
    anchors_table.select.return_value.in_.return_value.execute.return_value.data = [
        {"id": "a1", "building_id": "b1", "location_description": "front door"},
        {"id": "a3", "building_id": "b2", "location_description": "back door"},
    ]
    mock_client = _mock_multi_table_client(
        {
            "routes": routes_table,
            "anchor_point_connections": connections_table,
            "anchor_points": anchors_table,
        }
    )
    with patch("app.main.db.client", mock_client):
        response = client.post(
            "/routes/find_or_create",
            json={"start_anchor_id": "a1", "end_anchor_id": "a3"},
        )
    assert response.status_code == 200
    insert_payload = routes_table.insert.call_args.args[0]
    assert insert_payload["waypoint_anchor_ids"] == ["a2"]
    assert insert_payload["building_id"] == "b1"
    assert insert_payload["name"] == "front door to back door"
    assert insert_payload["created_by"] == "u1"


def test_find_or_create_404_when_no_path_exists():
    _as_caller("u1")
    routes_table = MagicMock()
    routes_table.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = []
    connections_table = MagicMock()
    connections_table.select.return_value.execute.return_value.data = []
    mock_client = _mock_multi_table_client(
        {"routes": routes_table, "anchor_point_connections": connections_table}
    )
    with patch("app.main.db.client", mock_client):
        response = client.post(
            "/routes/find_or_create",
            json={"start_anchor_id": "a1", "end_anchor_id": "a3"},
        )
    assert response.status_code == 404
