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


def _mock_admin_check_client(rows):
    mock_client = MagicMock()
    mock_client.table.return_value.select.return_value.eq.return_value.execute.return_value.data = rows
    return mock_client


def test_root():
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {"service": "backend-data-collection", "status": "ok"}


def test_no_token_is_rejected():
    response = client.get("/upload")
    assert response.status_code == 401


def test_garbage_token_is_rejected():
    with patch("app.main.db.get_user_id_from_token", side_effect=Exception("bad")):
        response = client.get("/upload", headers={"Authorization": "Bearer garbage"})
    assert response.status_code == 401


def test_list_photos_forbidden_for_non_admin():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_admin_check_client(_USER_ROW)):
        response = client.get("/upload")
    assert response.status_code == 403


def test_list_photos_returns_db_result():
    _as_caller("admin1")
    with (
        patch("app.main.db.client", _mock_admin_check_client(_ADMIN_ROW)),
        patch(
            "app.main.db.get_photos", return_value=[{"id": 1, "name": "a.jpg"}]
        ) as mock,
    ):
        response = client.get("/upload")
    assert response.status_code == 200
    assert response.json() == [{"id": 1, "name": "a.jpg"}]
    mock.assert_called_once()


def test_get_photo_by_id_forbidden_for_non_admin():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_admin_check_client(_USER_ROW)):
        response = client.get("/upload/5")
    assert response.status_code == 403


def test_get_photo_by_id_binds_path_param():
    _as_caller("admin1")
    with (
        patch("app.main.db.client", _mock_admin_check_client(_ADMIN_ROW)),
        patch("app.main.db.get_photo", return_value={"id": 5, "name": "b.jpg"}) as mock,
    ):
        response = client.get("/upload/5")
    assert response.status_code == 200
    assert response.json() == {"id": 5, "name": "b.jpg"}
    mock.assert_called_once_with(5)


def test_delete_photo_forbidden_for_non_admin():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_admin_check_client(_USER_ROW)):
        response = client.delete("/upload/5")
    assert response.status_code == 403


def test_delete_photo_by_id_binds_path_param():
    _as_caller("admin1")
    with (
        patch("app.main.db.client", _mock_admin_check_client(_ADMIN_ROW)),
        patch("app.main.db.dele_photo") as mock,
    ):
        response = client.delete("/upload/5")
    assert response.status_code == 200
    assert response.json() == "ok"
    mock.assert_called_once_with(5)


def test_upload_photo_accepts_multipart_form_and_file():
    _as_caller("u1")
    with patch("app.main.db.post_photos") as mock:
        response = client.post(
            "/upload",
            data={"latitude": "6.24", "longitude": "-75.58", "accuracy": "5.0"},
            files={"image": ("test.jpg", b"fake-bytes", "image/jpeg")},
        )
    assert response.status_code == 200
    assert response.json() == "ok"
    mock.assert_called_once()
    _, filename, latitude, longitude, accuracy, heading = mock.call_args.args
    assert (filename, latitude, longitude, accuracy, heading) == (
        "test.jpg",
        6.24,
        -75.58,
        5.0,
        None,
    )


def test_upload_photo_passes_heading_when_provided():
    _as_caller("u1")
    with patch("app.main.db.post_photos") as mock:
        response = client.post(
            "/upload",
            data={
                "latitude": "6.24",
                "longitude": "-75.58",
                "accuracy": "5.0",
                "heading": "182.5",
            },
            files={"image": ("test.jpg", b"fake-bytes", "image/jpeg")},
        )
    assert response.status_code == 200
    assert response.json() == "ok"
    _, _, _, _, _, heading = mock.call_args.args
    assert heading == 182.5


def test_upload_photo_requires_authentication():
    response = client.post(
        "/upload",
        data={"latitude": "6.24", "longitude": "-75.58", "accuracy": "5.0"},
        files={"image": ("test.jpg", b"fake-bytes", "image/jpeg")},
    )
    assert response.status_code == 401
