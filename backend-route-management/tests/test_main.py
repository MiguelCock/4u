from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_root():
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {"service": "backend-route-management", "status": "ok"}


def _mock_select_eq_result(rows):
    mock_client = MagicMock()
    mock_client.table.return_value.select.return_value.eq.return_value.execute.return_value.data = rows
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
    with patch("app.main.db.client", _mock_select_eq_result([_ROUTE_ROW])):
        response = client.get("/routes/1")
    assert response.status_code == 200
    assert response.json()["id"] == "1"


def test_get_route_404_when_missing():
    with patch("app.main.db.client", _mock_select_eq_result([])):
        response = client.get("/routes/missing")
    assert response.status_code == 404
