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


def _mock_insert_result(rows):
    mock_client = MagicMock()
    mock_client.table.return_value.insert.return_value.execute.return_value.data = rows
    return mock_client


def _mock_select_result(rows):
    mock_client = MagicMock()
    mock_client.table.return_value.select.return_value.execute.return_value.data = rows
    return mock_client


def _mock_delete_eq_result():
    mock_client = MagicMock()
    mock_client.table.return_value.delete.return_value.eq.return_value.execute.return_value.data = []
    return mock_client


def _mock_update_eq_result(rows):
    mock_client = MagicMock()
    mock_client.table.return_value.update.return_value.eq.return_value.execute.return_value.data = rows
    return mock_client


_ANCHOR_POINT_ROW = {
    "id": "1",
    "building_id": "b1",
    "floor": 0,
    "latitude": 6.24,
    "longitude": -75.58,
    "location_description": "Front door",
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


def test_create_anchor_point_returns_created_row():
    payload = {
        "building_id": "b1",
        "latitude": 6.24,
        "longitude": -75.58,
        "location_description": "Front door",
    }
    with patch("app.main.db.client", _mock_insert_result([{**payload, "id": "1"}])):
        response = client.post("/anchor-points", json=payload)
    assert response.status_code == 200
    assert response.json() == [{**payload, "id": "1"}]


def test_create_anchor_point_requires_description():
    payload = {
        "building_id": "b1",
        "latitude": 6.24,
        "longitude": -75.58,
    }
    response = client.post("/anchor-points", json=payload)
    assert response.status_code == 422


def test_update_anchor_point_returns_updated_row():
    mock_client = _mock_update_eq_result([{**_ANCHOR_POINT_ROW, "floor": 2}])
    with patch("app.main.db.client", mock_client):
        response = client.patch("/anchor-points/1", json={"floor": 2})
    assert response.status_code == 200
    assert response.json() == [{**_ANCHOR_POINT_ROW, "floor": 2}]
    mock_client.table.return_value.update.assert_called_once_with({"floor": 2})


def test_delete_anchor_point_returns_ok():
    mock_client = _mock_delete_eq_result()
    with patch("app.main.db.client", mock_client):
        response = client.delete("/anchor-points/1")
    assert response.status_code == 200
    assert response.json() == "ok"
    mock_client.table.return_value.delete.return_value.eq.assert_called_once_with(
        "id", "1"
    )


_ANCHOR_POINT_PHOTO_ROW = {
    "id": "ph1",
    "anchor_point_id": "1",
    "image_url": "https://example.com/a.jpg",
    "heading": 90.0,
    "captured_by": "u1",
    "captured_at": "2026-01-01T00:00:00Z",
}


def test_create_anchor_point_photo_returns_created_row():
    payload = {
        "image_url": "https://example.com/a.jpg",
        "heading": 90.0,
        "captured_by": "u1",
    }
    with patch(
        "app.main.db.client",
        _mock_insert_result([{**payload, "id": "ph1", "anchor_point_id": "1"}]),
    ) as _:
        response = client.post("/anchor-points/1/photos", json=payload)
    assert response.status_code == 200
    assert response.json() == [{**payload, "id": "ph1", "anchor_point_id": "1"}]


def test_list_anchor_point_photos():
    with patch("app.main.db.client", _mock_select_eq_result([_ANCHOR_POINT_PHOTO_ROW])):
        response = client.get("/anchor-points/1/photos")
    assert response.status_code == 200
    assert response.json() == [_ANCHOR_POINT_PHOTO_ROW]


def test_list_all_anchor_point_photos():
    with patch("app.main.db.client", _mock_select_result([_ANCHOR_POINT_PHOTO_ROW])):
        response = client.get("/anchor-point-photos")
    assert response.status_code == 200
    assert response.json() == [_ANCHOR_POINT_PHOTO_ROW]


def test_delete_anchor_point_photo_returns_ok():
    mock_client = _mock_delete_eq_result()
    with patch("app.main.db.client", mock_client):
        response = client.delete("/anchor-point-photos/ph1")
    assert response.status_code == 200
    assert response.json() == "ok"
    mock_client.table.return_value.delete.return_value.eq.assert_called_once_with(
        "id", "ph1"
    )


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


def test_create_building_returns_created_row():
    payload = {
        "place_id": "p1",
        "code": "B2",
        "name": "Annex",
        "latitude": 6.24,
        "longitude": -75.58,
    }
    with patch("app.main.db.client", _mock_insert_result([{**payload, "id": "2"}])):
        response = client.post("/buildings", json=payload)
    assert response.status_code == 200
    assert response.json() == [{**payload, "id": "2"}]


def test_update_building_returns_updated_row():
    mock_client = _mock_update_eq_result([{**_BUILDING_ROW, "name": "Renamed"}])
    with patch("app.main.db.client", mock_client):
        response = client.patch("/buildings/1", json={"name": "Renamed"})
    assert response.status_code == 200
    assert response.json() == [{**_BUILDING_ROW, "name": "Renamed"}]
    mock_client.table.return_value.update.assert_called_once_with({"name": "Renamed"})


def test_delete_building_returns_ok():
    mock_client = _mock_delete_eq_result()
    with patch("app.main.db.client", mock_client):
        response = client.delete("/buildings/1")
    assert response.status_code == 200
    assert response.json() == "ok"
    mock_client.table.return_value.delete.return_value.eq.assert_called_once_with(
        "id", "1"
    )


_PLACE_ROW = {
    "id": "p1",
    "code": "CAMPUS",
    "name": "Main Campus",
    "latitude": 6.24,
    "longitude": -75.58,
}


def test_create_place_returns_created_row():
    payload = {
        "code": "CAMPUS",
        "name": "Main Campus",
        "latitude": 6.24,
        "longitude": -75.58,
    }
    with patch("app.main.db.client", _mock_insert_result([_PLACE_ROW])):
        response = client.post("/places", json=payload)
    assert response.status_code == 200
    assert response.json() == [_PLACE_ROW]


def test_list_places():
    with patch("app.main.db.client", _mock_select_result([_PLACE_ROW])):
        response = client.get("/places")
    assert response.status_code == 200
    assert response.json() == [{**_PLACE_ROW, "address": None}]


def test_get_place_404_when_missing():
    with patch("app.main.db.client", _mock_select_eq_result([])):
        response = client.get("/places/missing")
    assert response.status_code == 404


def test_update_place_returns_updated_row():
    mock_client = _mock_update_eq_result([{**_PLACE_ROW, "name": "Renamed Campus"}])
    with patch("app.main.db.client", mock_client):
        response = client.patch("/places/p1", json={"name": "Renamed Campus"})
    assert response.status_code == 200
    assert response.json() == [{**_PLACE_ROW, "name": "Renamed Campus"}]
    mock_client.table.return_value.update.assert_called_once_with(
        {"name": "Renamed Campus"}
    )


def test_delete_place_returns_ok():
    mock_client = _mock_delete_eq_result()
    with patch("app.main.db.client", mock_client):
        response = client.delete("/places/p1")
    assert response.status_code == 200
    assert response.json() == "ok"
    mock_client.table.return_value.delete.return_value.eq.assert_called_once_with(
        "id", "p1"
    )


def test_upload_anchor_point_image_returns_public_url():
    with patch(
        "app.main.db.upload_image",
        return_value="https://example.com/anchor-points/a.jpg",
    ) as mock:
        response = client.post(
            "/anchor-points/upload-image",
            files={"file": ("a.jpg", b"fake-bytes", "image/jpeg")},
        )
    assert response.status_code == 200
    assert response.json() == {"url": "https://example.com/anchor-points/a.jpg"}
    args = mock.call_args.args
    assert args[0] == "anchor-points"
    assert args[2] == "a.jpg"
