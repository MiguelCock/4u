from unittest.mock import patch

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_root():
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {"service": "backend-data-collection", "status": "ok"}


def test_list_photos_returns_db_result():
    with patch("app.main.db.get_photos", return_value=[{"id": 1, "name": "a.jpg"}]) as mock:
        response = client.get("/upload")
    assert response.status_code == 200
    assert response.json() == [{"id": 1, "name": "a.jpg"}]
    mock.assert_called_once()


def test_get_photo_by_id_binds_path_param():
    with patch("app.main.db.get_photo", return_value={"id": 5, "name": "b.jpg"}) as mock:
        response = client.get("/upload/5")
    assert response.status_code == 200
    assert response.json() == {"id": 5, "name": "b.jpg"}
    mock.assert_called_once_with(5)


def test_delete_photo_by_id_binds_path_param():
    with patch("app.main.db.dele_photo") as mock:
        response = client.delete("/upload/5")
    assert response.status_code == 200
    assert response.json() == "ok"
    mock.assert_called_once_with(5)


def test_upload_photo_accepts_multipart_form_and_file():
    with patch("app.main.db.post_photos") as mock:
        response = client.post(
            "/upload",
            data={"latitude": "6.24", "longitude": "-75.58", "accuracy": "5.0"},
            files={"image": ("test.jpg", b"fake-bytes", "image/jpeg")},
        )
    assert response.status_code == 200
    assert response.json() == "ok"
    mock.assert_called_once()
    _, latitude, longitude, accuracy = mock.call_args.args
    assert (latitude, longitude, accuracy) == (6.24, -75.58, 5.0)
