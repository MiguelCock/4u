from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_root():
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {"service": "backend-navigation-management", "status": "ok"}


def _mock_select_eq_result(rows):
    mock_client = MagicMock()
    mock_client.table.return_value.select.return_value.eq.return_value.execute.return_value.data = rows
    return mock_client


_SESSION_ROW = {
    "id": "1",
    "user_id": "u1",
    "building_id": "b1",
    "start_time": "2024-01-01T00:00:00Z",
    "status": "active",
}

_LOG_ROW = {
    "id": "1",
    "session_id": "s1",
    "gps_lat": 6.24,
    "gps_long": -75.58,
    "timestamp": "2024-01-01T00:00:00Z",
}

_FEEDBACK_ROW = {
    "id": "1",
    "user_id": "u1",
    "created_at": "2024-01-01T00:00:00Z",
}


def test_get_session_returns_single_object():
    with patch("app.main.db.client", _mock_select_eq_result([_SESSION_ROW])):
        response = client.get("/sessions/1")
    assert response.status_code == 200
    assert response.json()["id"] == "1"


def test_get_session_404_when_missing():
    with patch("app.main.db.client", _mock_select_eq_result([])):
        response = client.get("/sessions/missing")
    assert response.status_code == 404


def test_get_log_returns_single_object():
    with patch("app.main.db.client", _mock_select_eq_result([_LOG_ROW])):
        response = client.get("/logs/1")
    assert response.status_code == 200
    assert response.json()["id"] == "1"


def test_get_log_404_when_missing():
    with patch("app.main.db.client", _mock_select_eq_result([])):
        response = client.get("/logs/missing")
    assert response.status_code == 404


def test_get_feedback_returns_single_object():
    with patch("app.main.db.client", _mock_select_eq_result([_FEEDBACK_ROW])):
        response = client.get("/feedback/1")
    assert response.status_code == 200
    assert response.json()["id"] == "1"


def test_get_feedback_404_when_missing():
    with patch("app.main.db.client", _mock_select_eq_result([])):
        response = client.get("/feedback/missing")
    assert response.status_code == 404
