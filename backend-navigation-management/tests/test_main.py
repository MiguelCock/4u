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
    assert response.json() == {
        "service": "backend-navigation-management",
        "status": "ok",
    }


def test_no_token_is_rejected():
    response = client.get("/sessions")
    assert response.status_code == 401


def test_garbage_token_is_rejected():
    with patch("app.main.db.get_user_id_from_token", side_effect=Exception("bad")):
        response = client.get("/sessions", headers={"Authorization": "Bearer garbage"})
    assert response.status_code == 401


def _mock_select_eq_result(rows):
    mock_client = MagicMock()
    mock_client.table.return_value.select.return_value.eq.return_value.execute.return_value.data = rows
    return mock_client


def _mock_insert_result(rows):
    mock_client = MagicMock()
    mock_client.table.return_value.insert.return_value.execute.return_value.data = rows
    return mock_client


def _mock_multi_table_client(table_mocks):
    mock_client = MagicMock()
    mock_client.table.side_effect = lambda name: table_mocks[name]
    return mock_client


def _profiles_table(admin: bool) -> MagicMock:
    profiles_table = MagicMock()
    profiles_table.select.return_value.eq.return_value.execute.return_value.data = (
        _ADMIN_ROW if admin else _USER_ROW
    )
    return profiles_table


def _sessions_table(select_rows=None, update_rows=None) -> MagicMock:
    sessions_table = MagicMock()
    sessions_table.select.return_value.eq.return_value.execute.return_value.data = (
        select_rows if select_rows is not None else []
    )
    sessions_table.update.return_value.eq.return_value.execute.return_value.data = (
        update_rows if update_rows is not None else []
    )
    return sessions_table


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


# --- POST /sessions: forces user_id -------------------------------------


def test_create_session_forces_user_id():
    _as_caller("u1")
    payload = {"building_id": "b1", "user_id": "someone-else"}
    mock_client = _mock_insert_result([{**_SESSION_ROW, "id": "2"}])
    with patch("app.main.db.client", mock_client):
        response = client.post("/sessions", json=payload)
    assert response.status_code == 200
    insert_payload = mock_client.table.return_value.insert.call_args.args[0]
    assert insert_payload["user_id"] == "u1"


# --- GET /sessions: admin only -------------------------------------------


def test_list_sessions_forbidden_for_non_admin():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_eq_result(_USER_ROW)):
        response = client.get("/sessions")
    assert response.status_code == 403


def test_list_sessions_allowed_for_admin():
    _as_caller("admin1")
    with patch("app.main.db.client", _mock_select_eq_result(_ADMIN_ROW)):
        response = client.get("/sessions")
    assert response.status_code == 200


# --- GET /sessions/{id}: admin or self ------------------------------------


def test_get_session_returns_single_object():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_eq_result([_SESSION_ROW])):
        response = client.get("/sessions/1")
    assert response.status_code == 200
    assert response.json()["id"] == "1"


def test_get_session_404_when_missing():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_eq_result([])):
        response = client.get("/sessions/missing")
    assert response.status_code == 404


def test_get_session_forbidden_for_other_user():
    _as_caller("u2")
    mock_client = _mock_multi_table_client(
        {
            "navigation_sessions": _sessions_table(select_rows=[_SESSION_ROW]),
            "profiles": _profiles_table(admin=False),
        }
    )
    with patch("app.main.db.client", mock_client):
        response = client.get("/sessions/1")
    assert response.status_code == 403


def test_get_session_allowed_for_admin_on_others_session():
    _as_caller("admin1")
    mock_client = _mock_multi_table_client(
        {
            "navigation_sessions": _sessions_table(select_rows=[_SESSION_ROW]),
            "profiles": _profiles_table(admin=True),
        }
    )
    with patch("app.main.db.client", mock_client):
        response = client.get("/sessions/1")
    assert response.status_code == 200


# --- PATCH /sessions/{id}: admin or self -----------------------------------


def test_update_session_404_when_missing():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_eq_result([])):
        response = client.patch("/sessions/missing", json={"status": "completed"})
    assert response.status_code == 404


def test_update_session_self_allowed():
    _as_caller("u1")
    mock_client = _mock_multi_table_client(
        {
            "navigation_sessions": _sessions_table(
                select_rows=[{"user_id": "u1"}],
                update_rows=[{**_SESSION_ROW, "status": "completed"}],
            )
        }
    )
    with patch("app.main.db.client", mock_client):
        response = client.patch("/sessions/1", json={"status": "completed"})
    assert response.status_code == 200


def test_update_session_forbidden_for_other_user():
    _as_caller("u2")
    mock_client = _mock_multi_table_client(
        {
            "navigation_sessions": _sessions_table(select_rows=[{"user_id": "u1"}]),
            "profiles": _profiles_table(admin=False),
        }
    )
    with patch("app.main.db.client", mock_client):
        response = client.patch("/sessions/1", json={"status": "completed"})
    assert response.status_code == 403


def test_update_session_allowed_for_admin():
    _as_caller("admin1")
    mock_client = _mock_multi_table_client(
        {
            "navigation_sessions": _sessions_table(
                select_rows=[{"user_id": "u1"}],
                update_rows=[{**_SESSION_ROW, "status": "completed"}],
            ),
            "profiles": _profiles_table(admin=True),
        }
    )
    with patch("app.main.db.client", mock_client):
        response = client.patch("/sessions/1", json={"status": "completed"})
    assert response.status_code == 200


# --- POST /logs: admin or self via session_id -> navigation_sessions.user_id


def test_create_log_404_when_session_missing():
    _as_caller("u1")
    mock_client = _mock_multi_table_client(
        {"navigation_sessions": _sessions_table(select_rows=[])}
    )
    with patch("app.main.db.client", mock_client):
        response = client.post(
            "/logs", json={"session_id": "missing", "gps_lat": 6.24, "gps_long": -75.58}
        )
    assert response.status_code == 404


def test_create_log_self_allowed():
    _as_caller("u1")
    mock_client = _mock_multi_table_client(
        {
            "navigation_sessions": _sessions_table(select_rows=[{"user_id": "u1"}]),
            "navigation_logs": MagicMock(
                **{"insert.return_value.execute.return_value.data": [_LOG_ROW]}
            ),
        }
    )
    with patch("app.main.db.client", mock_client):
        response = client.post(
            "/logs", json={"session_id": "s1", "gps_lat": 6.24, "gps_long": -75.58}
        )
    assert response.status_code == 200


def test_create_log_forbidden_for_other_user():
    _as_caller("u2")
    mock_client = _mock_multi_table_client(
        {
            "navigation_sessions": _sessions_table(select_rows=[{"user_id": "u1"}]),
            "profiles": _profiles_table(admin=False),
        }
    )
    with patch("app.main.db.client", mock_client):
        response = client.post(
            "/logs", json={"session_id": "s1", "gps_lat": 6.24, "gps_long": -75.58}
        )
    assert response.status_code == 403


def test_create_log_allowed_for_admin():
    _as_caller("admin1")
    mock_client = _mock_multi_table_client(
        {
            "navigation_sessions": _sessions_table(select_rows=[{"user_id": "u1"}]),
            "profiles": _profiles_table(admin=True),
            "navigation_logs": MagicMock(
                **{"insert.return_value.execute.return_value.data": [_LOG_ROW]}
            ),
        }
    )
    with patch("app.main.db.client", mock_client):
        response = client.post(
            "/logs", json={"session_id": "s1", "gps_lat": 6.24, "gps_long": -75.58}
        )
    assert response.status_code == 200


# --- GET /logs: admin only -------------------------------------------------


def test_list_logs_forbidden_for_non_admin():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_eq_result(_USER_ROW)):
        response = client.get("/logs")
    assert response.status_code == 403


def test_list_logs_allowed_for_admin():
    _as_caller("admin1")
    with patch("app.main.db.client", _mock_select_eq_result(_ADMIN_ROW)):
        response = client.get("/logs")
    assert response.status_code == 200


# --- GET /logs/{id}: admin or self via the log's session's owner ----------


def test_get_log_returns_single_object():
    _as_caller("u1")
    mock_client = _mock_multi_table_client(
        {
            "navigation_logs": _sessions_table(select_rows=[_LOG_ROW]),
            "navigation_sessions": _sessions_table(select_rows=[{"user_id": "u1"}]),
        }
    )
    with patch("app.main.db.client", mock_client):
        response = client.get("/logs/1")
    assert response.status_code == 200
    assert response.json()["id"] == "1"


def test_get_log_404_when_missing():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_eq_result([])):
        response = client.get("/logs/missing")
    assert response.status_code == 404


def test_get_log_forbidden_for_other_user():
    _as_caller("u2")
    mock_client = _mock_multi_table_client(
        {
            "navigation_logs": _sessions_table(select_rows=[_LOG_ROW]),
            "navigation_sessions": _sessions_table(select_rows=[{"user_id": "u1"}]),
            "profiles": _profiles_table(admin=False),
        }
    )
    with patch("app.main.db.client", mock_client):
        response = client.get("/logs/1")
    assert response.status_code == 403


def test_get_log_allowed_for_admin():
    _as_caller("admin1")
    mock_client = _mock_multi_table_client(
        {
            "navigation_logs": _sessions_table(select_rows=[_LOG_ROW]),
            "navigation_sessions": _sessions_table(select_rows=[{"user_id": "u1"}]),
            "profiles": _profiles_table(admin=True),
        }
    )
    with patch("app.main.db.client", mock_client):
        response = client.get("/logs/1")
    assert response.status_code == 200


# --- POST /feedback: forces user_id ---------------------------------------


def test_create_feedback_forces_user_id():
    _as_caller("u1")
    payload = {"comment": "great app", "user_id": "someone-else"}
    mock_client = _mock_insert_result([{**_FEEDBACK_ROW, "id": "2"}])
    with patch("app.main.db.client", mock_client):
        response = client.post("/feedback", json=payload)
    assert response.status_code == 200
    insert_payload = mock_client.table.return_value.insert.call_args.args[0]
    assert insert_payload["user_id"] == "u1"


# --- GET /feedback: admin only ---------------------------------------------


def test_list_feedback_forbidden_for_non_admin():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_eq_result(_USER_ROW)):
        response = client.get("/feedback")
    assert response.status_code == 403


def test_list_feedback_allowed_for_admin():
    _as_caller("admin1")
    with patch("app.main.db.client", _mock_select_eq_result(_ADMIN_ROW)):
        response = client.get("/feedback")
    assert response.status_code == 200


# --- GET /feedback/{id}: admin or self -------------------------------------


def test_get_feedback_returns_single_object():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_eq_result([_FEEDBACK_ROW])):
        response = client.get("/feedback/1")
    assert response.status_code == 200
    assert response.json()["id"] == "1"


def test_get_feedback_404_when_missing():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_eq_result([])):
        response = client.get("/feedback/missing")
    assert response.status_code == 404


def test_get_feedback_forbidden_for_other_user():
    _as_caller("u2")
    mock_client = _mock_multi_table_client(
        {
            "user_feedback": _sessions_table(select_rows=[_FEEDBACK_ROW]),
            "profiles": _profiles_table(admin=False),
        }
    )
    with patch("app.main.db.client", mock_client):
        response = client.get("/feedback/1")
    assert response.status_code == 403


def test_get_feedback_allowed_for_admin():
    _as_caller("admin1")
    mock_client = _mock_multi_table_client(
        {
            "user_feedback": _sessions_table(select_rows=[_FEEDBACK_ROW]),
            "profiles": _profiles_table(admin=True),
        }
    )
    with patch("app.main.db.client", mock_client):
        response = client.get("/feedback/1")
    assert response.status_code == 200
