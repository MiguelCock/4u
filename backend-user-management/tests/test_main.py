from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_root():
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {"service": "backend-user-management", "status": "ok"}


def _mock_select_eq_result(rows):
    mock_client = MagicMock()
    mock_client.table.return_value.select.return_value.eq.return_value.execute.return_value.data = rows
    return mock_client


_PROFILE_ROW = {
    "id": "1",
    "preferences": {"verbosity": "medium", "feedback_type": "voice"},
    "is_active": True,
    "created_at": "2024-01-01T00:00:00Z",
    "updated_at": "2024-01-01T00:00:00Z",
}


def test_get_profile_returns_single_object():
    with patch("app.main.db.client", _mock_select_eq_result([_PROFILE_ROW])):
        response = client.get("/profiles/1")
    assert response.status_code == 200
    assert response.json()["id"] == "1"


def test_get_profile_404_when_missing():
    with patch("app.main.db.client", _mock_select_eq_result([])):
        response = client.get("/profiles/missing")
    assert response.status_code == 404


def test_get_role_returns_single_object():
    with patch("app.main.db.client", _mock_select_eq_result([{"id": 1, "name": "user"}])):
        response = client.get("/roles/1")
    assert response.status_code == 200
    assert response.json()["id"] == 1


def test_get_role_404_when_missing():
    with patch("app.main.db.client", _mock_select_eq_result([])):
        response = client.get("/roles/99")
    assert response.status_code == 404
