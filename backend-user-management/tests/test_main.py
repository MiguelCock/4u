from unittest.mock import MagicMock, patch

import pytest
from fastapi.testclient import TestClient

from app.main import app, get_caller_id

client = TestClient(app)


@pytest.fixture(autouse=True)
def _clear_overrides():
    # Every test either overrides get_caller_id explicitly (to act as a
    # given caller) or relies on there being none (to hit the real 401
    # path) - always start from a clean slate and clean up after.
    yield
    app.dependency_overrides.clear()


def _as_caller(caller_id: str) -> None:
    app.dependency_overrides[get_caller_id] = lambda: caller_id


def _mock_client(select_rows=None, update_rows=None, insert_rows=None):
    """A MagicMock standing in for db.client. `select_rows` backs both the
    `_is_admin` role lookup and any plain GET - tests that exercise both in
    one request (e.g. an admin acting on someone else) only need one shape,
    since the caller's own admin-check row and the target's profile row
    don't need to differ for these guard tests to be meaningful."""
    mock_client = MagicMock()
    mock_client.table.return_value.select.return_value.eq.return_value.execute.return_value.data = select_rows
    mock_client.table.return_value.update.return_value.eq.return_value.execute.return_value.data = update_rows
    mock_client.table.return_value.insert.return_value.execute.return_value.data = (
        insert_rows
    )
    return mock_client


_ADMIN_ROW = [{"role_id": 2}]
_USER_ROW = [{"role_id": 1}]

_PROFILE_ROW = {
    "id": "1",
    "preferences": {"verbosity": "medium", "feedback_type": "voice"},
    "is_active": True,
    "created_at": "2024-01-01T00:00:00Z",
    "updated_at": "2024-01-01T00:00:00Z",
}


def test_root():
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {"service": "backend-user-management", "status": "ok"}


# --- authentication ---------------------------------------------------


def test_no_token_is_rejected():
    response = client.get("/profiles/1")
    assert response.status_code == 401


def test_garbage_token_is_rejected():
    with patch("app.main.db.get_user_id_from_token", side_effect=Exception("bad")):
        response = client.get(
            "/profiles/1", headers={"Authorization": "Bearer garbage"}
        )
    assert response.status_code == 401


# --- GET /profiles/{id}: admin or self ---------------------------------


def test_get_profile_self_returns_single_object():
    _as_caller("1")
    with patch("app.main.db.client", _mock_client(select_rows=[_PROFILE_ROW])):
        response = client.get("/profiles/1")
    assert response.status_code == 200
    assert response.json()["id"] == "1"


def test_get_profile_self_404_when_missing():
    _as_caller("missing")
    with patch("app.main.db.client", _mock_client(select_rows=[])):
        response = client.get("/profiles/missing")
    assert response.status_code == 404


def test_get_profile_other_user_forbidden_for_non_admin():
    _as_caller("2")
    with patch("app.main.db.client", _mock_client(select_rows=_USER_ROW)):
        response = client.get("/profiles/1")
    assert response.status_code == 403


def test_get_profile_other_user_allowed_for_admin():
    _as_caller("99")
    # Two distinct .select().eq().execute() calls happen here - the
    # _is_admin check on the caller, then the actual profile fetch on the
    # target - so unlike the other guard tests they can't share one mocked
    # return value; the real profile row must come back second.
    mock_client = _mock_client(select_rows=_ADMIN_ROW)
    mock_client.table.return_value.select.return_value.eq.return_value.execute.side_effect = [
        MagicMock(data=_ADMIN_ROW),
        MagicMock(data=[_PROFILE_ROW]),
    ]
    with patch("app.main.db.client", mock_client):
        response = client.get("/profiles/1")
    assert response.status_code == 200
    assert response.json()["id"] == "1"


# --- GET /profiles: admin only -----------------------------------------


def test_list_profiles_forbidden_for_non_admin():
    _as_caller("1")
    with patch("app.main.db.client", _mock_client(select_rows=_USER_ROW)):
        response = client.get("/profiles")
    assert response.status_code == 403


def test_list_profiles_allowed_for_admin():
    _as_caller("99")
    with patch("app.main.db.client", _mock_client(select_rows=_ADMIN_ROW)):
        response = client.get("/profiles")
    assert response.status_code == 200


# --- POST /profiles: id/role_id forced server-side ----------------------


def test_create_profile_forces_own_id_and_default_role_for_non_admin():
    _as_caller("caller-id")
    mock_client = _mock_client(select_rows=[], insert_rows=[_PROFILE_ROW])
    with patch("app.main.db.client", mock_client):
        response = client.post(
            "/profiles",
            json={"id": "someone-else", "role_id": 2},
        )
    assert response.status_code == 200
    inserted = mock_client.table.return_value.insert.call_args[0][0]
    assert inserted["id"] == "caller-id"
    assert inserted["role_id"] == 1


def test_create_profile_lets_admin_set_role_id():
    _as_caller("admin-id")
    mock_client = _mock_client(select_rows=_ADMIN_ROW, insert_rows=[_PROFILE_ROW])
    with patch("app.main.db.client", mock_client):
        response = client.post("/profiles", json={"id": "x", "role_id": 2})
    assert response.status_code == 200
    inserted = mock_client.table.return_value.insert.call_args[0][0]
    assert inserted["id"] == "admin-id"
    assert inserted["role_id"] == 2


# --- PATCH /profiles/{id} ------------------------------------------------


def test_update_profile_self_non_role_fields_allowed():
    _as_caller("1")
    with patch(
        "app.main.db.client",
        _mock_client(select_rows=[], update_rows=[_PROFILE_ROW]),
    ):
        response = client.patch("/profiles/1", json={"full_name": "New Name"})
    assert response.status_code == 200


def test_update_profile_self_cannot_set_role_id():
    _as_caller("1")
    with patch("app.main.db.client", _mock_client(select_rows=[])):
        response = client.patch("/profiles/1", json={"role_id": 2})
    assert response.status_code == 403


def test_update_profile_self_cannot_set_is_active():
    _as_caller("1")
    with patch("app.main.db.client", _mock_client(select_rows=[])):
        response = client.patch("/profiles/1", json={"is_active": False})
    assert response.status_code == 403


def test_update_profile_other_user_forbidden_for_non_admin():
    _as_caller("2")
    with patch("app.main.db.client", _mock_client(select_rows=_USER_ROW)):
        response = client.patch("/profiles/1", json={"full_name": "Hacked"})
    assert response.status_code == 403


def test_update_profile_admin_can_set_role_id_on_others():
    _as_caller("99")
    with patch(
        "app.main.db.client",
        _mock_client(select_rows=_ADMIN_ROW, update_rows=[_PROFILE_ROW]),
    ):
        response = client.patch("/profiles/1", json={"role_id": 2})
    assert response.status_code == 200


# --- DELETE /profiles/{id}: admin only -----------------------------------


def test_delete_profile_forbidden_for_non_admin():
    _as_caller("1")
    with patch("app.main.db.client", _mock_client(select_rows=_USER_ROW)):
        response = client.delete("/profiles/1")
    assert response.status_code == 403


def test_delete_profile_allowed_for_admin():
    _as_caller("99")
    with patch("app.main.db.client", _mock_client(select_rows=_ADMIN_ROW)):
        response = client.delete("/profiles/1")
    assert response.status_code == 200


# --- /roles: unguarded, read-only reference data -------------------------


def _mock_select_eq_result(rows):
    mock_client = MagicMock()
    mock_client.table.return_value.select.return_value.eq.return_value.execute.return_value.data = rows
    return mock_client


def test_get_role_returns_single_object():
    with patch(
        "app.main.db.client", _mock_select_eq_result([{"id": 1, "name": "user"}])
    ):
        response = client.get("/roles/1")
    assert response.status_code == 200
    assert response.json()["id"] == 1


def test_get_role_404_when_missing():
    with patch("app.main.db.client", _mock_select_eq_result([])):
        response = client.get("/roles/99")
    assert response.status_code == 404
