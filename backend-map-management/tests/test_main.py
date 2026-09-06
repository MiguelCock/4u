from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_root():
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {"service": "backend-map-management", "status": "ok"}


def _mock_select_eq_result(rows):
    mock_client = MagicMock()
    mock_client.table.return_value.select.return_value.eq.return_value.execute.return_value.data = rows
    return mock_client


_ANCHOR_POINT_ROW = {
    "id": "1",
    "building_id": "b1",
    "image_url": "https://example.com/a.jpg",
    "latitude": 6.24,
    "longitude": -75.58,
    "captured_by": "u1",
    "status": "pending",
}


def test_get_anchor_point_returns_single_object():
    with patch("app.main.db.client", _mock_select_eq_result([_ANCHOR_POINT_ROW])):
        response = client.get("/anchor-points/1")
    assert response.status_code == 200
    assert response.json()["id"] == "1"


def test_get_anchor_point_404_when_missing():
    with patch("app.main.db.client", _mock_select_eq_result([])):
        response = client.get("/anchor-points/missing")
    assert response.status_code == 404


_BUILDING_ROW = {
    "id": "1",
    "place_id": "p1",
    "code": "B1",
    "name": "Main Building",
    "latitude": 6.24,
    "longitude": -75.58,
    "floors": 3,
    "has_elevator": True,
    "has_stairs": True,
}


def test_get_building_returns_single_object():
    with patch("app.main.db.client", _mock_select_eq_result([_BUILDING_ROW])):
        response = client.get("/buildings/1")
    assert response.status_code == 200
    assert response.json()["id"] == "1"


def test_get_building_404_when_missing():
    with patch("app.main.db.client", _mock_select_eq_result([])):
        response = client.get("/buildings/missing")
    assert response.status_code == 404
