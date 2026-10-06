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
    # select().eq() defaults to an admin row for the _is_admin check -
    # create_route does nothing else with select().eq().
    mock_client = MagicMock()
    mock_client.table.return_value.insert.return_value.execute.return_value.data = rows
    mock_client.table.return_value.select.return_value.eq.return_value.execute.return_value.data = _ADMIN_ROW
    return mock_client


def _mock_delete_eq_result():
    mock_client = MagicMock()
    mock_client.table.return_value.delete.return_value.eq.return_value.execute.return_value.data = []
    mock_client.table.return_value.select.return_value.eq.return_value.execute.return_value.data = _ADMIN_ROW
    return mock_client


_ROUTE_ROW = {
    "id": "1",
    "building_id": "b1",
    "name": "Main entrance to elevator",
    "start_anchor_id": "a1",
    "end_anchor_id": "a2",
    "waypoint_anchor_ids": [],
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


def test_create_route_forbidden_for_non_admin():
    _as_caller("u1")
    payload = {
        "building_id": "b1",
        "name": "New route",
        "start_anchor_id": "a1",
        "end_anchor_id": "a2",
    }
    with patch("app.main.db.client", _mock_select_eq_result(_USER_ROW)):
        response = client.post("/routes", json=payload)
    assert response.status_code == 403


def test_create_route_returns_created_row():
    _as_caller("admin1")
    payload = {
        "building_id": "b1",
        "name": "New route",
        "start_anchor_id": "a1",
        "end_anchor_id": "a2",
    }
    with patch(
        "app.main.db.client",
        _mock_insert_result([{**payload, "id": "2", "waypoint_anchor_ids": []}]),
    ):
        response = client.post("/routes", json=payload)
    assert response.status_code == 200
    assert response.json() == [{**payload, "id": "2", "waypoint_anchor_ids": []}]


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
