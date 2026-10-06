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
    assert response.json() == {"service": "backend-ai-training", "status": "ok"}


def test_no_token_is_rejected():
    response = client.post("/index_anchor", json={})
    assert response.status_code == 401


def test_garbage_token_is_rejected():
    with patch("app.main.db.get_user_id_from_token", side_effect=Exception("bad")):
        response = client.delete(
            "/index_photo/p1", headers={"Authorization": "Bearer garbage"}
        )
    assert response.status_code == 401


def test_index_anchor_forbidden_for_non_admin():
    _as_caller("u1")
    payload = {
        "anchor_point_id": "a1",
        "latitude": 6.24,
        "longitude": -75.58,
        "building_id": "b1",
        "photos": [],
    }
    with patch("app.main.db.client", _mock_admin_check_client(_USER_ROW)):
        response = client.post("/index_anchor", json=payload)
    assert response.status_code == 403


def test_index_anchor_upserts_one_point_per_photo():
    _as_caller("admin1")
    payload = {
        "anchor_point_id": "a1",
        "latitude": 6.24,
        "longitude": -75.58,
        "building_id": "b1",
        "photos": [
            {
                "photo_id": "p1",
                "image_url": "https://example.com/1.jpg",
                "heading": 90.0,
            },
            {"photo_id": "p2", "image_url": "https://example.com/2.jpg"},
        ],
    }
    mock_qdrant = MagicMock()
    with (
        patch("app.main.db.client", _mock_admin_check_client(_ADMIN_ROW)),
        patch("app.main.qdrant", mock_qdrant),
        patch("app.main.download_image", return_value=b"fake-bytes"),
        patch("app.main.extract_embedding", return_value=[0.1] * 1280),
    ):
        response = client.post("/index_anchor", json=payload)

    assert response.status_code == 200
    assert response.json() == {"indexed": 2}
    mock_qdrant.ensure_collection.assert_called_once_with(
        "anchor_point_photos", 1280, indexed_fields=["anchor_point_id", "building_id"]
    )
    upsert_call = mock_qdrant.client.upsert.call_args
    assert upsert_call.args[0] == "anchor_point_photos"
    points = upsert_call.kwargs["points"]
    assert len(points) == 2
    assert points[0].id == "p1"
    assert points[0].vector == [0.1] * 1280
    assert points[0].payload == {
        "anchor_point_id": "a1",
        "latitude": 6.24,
        "longitude": -75.58,
        "building_id": "b1",
        "heading": 90.0,
    }
    assert points[1].payload["heading"] is None


def test_index_anchor_with_no_photos_upserts_nothing():
    _as_caller("admin1")
    payload = {
        "anchor_point_id": "a1",
        "latitude": 6.24,
        "longitude": -75.58,
        "building_id": "b1",
        "photos": [],
    }
    mock_qdrant = MagicMock()
    with (
        patch("app.main.db.client", _mock_admin_check_client(_ADMIN_ROW)),
        patch("app.main.qdrant", mock_qdrant),
    ):
        response = client.post("/index_anchor", json=payload)
    assert response.status_code == 200
    assert response.json() == {"indexed": 0}
    mock_qdrant.client.upsert.assert_not_called()


def test_search_similar_has_no_auth_requirement():
    # Deliberate exception (#24): called server-to-server by
    # backend-positioning with no end-user token to forward.
    mock_result = MagicMock()
    mock_result.points = []
    mock_qdrant = MagicMock()
    mock_qdrant.client.query_points.return_value = mock_result
    with (
        patch("app.main.qdrant", mock_qdrant),
        patch("app.main.extract_embedding", return_value=[0.1] * 1280),
    ):
        response = client.post(
            "/search_similar",
            files={"file": ("query.jpg", b"fake-bytes", "image/jpeg")},
        )
    assert response.status_code == 200


def test_search_similar_returns_matches():
    mock_point = MagicMock()
    mock_point.id = "p1"
    mock_point.score = 0.98
    mock_point.payload = {
        "anchor_point_id": "a1",
        "latitude": 6.24,
        "longitude": -75.58,
        "building_id": "b1",
    }
    mock_result = MagicMock()
    mock_result.points = [mock_point]

    mock_qdrant = MagicMock()
    mock_qdrant.client.query_points.return_value = mock_result

    with (
        patch("app.main.qdrant", mock_qdrant),
        patch("app.main.extract_embedding", return_value=[0.1] * 1280),
    ):
        response = client.post(
            "/search_similar",
            files={"file": ("query.jpg", b"fake-bytes", "image/jpeg")},
        )

    assert response.status_code == 200
    assert response.json() == {
        "matches": [
            {
                "anchor_point_id": "a1",
                "photo_id": "p1",
                "latitude": 6.24,
                "longitude": -75.58,
                "building_id": "b1",
                "score": 0.98,
            }
        ]
    }
    mock_qdrant.ensure_collection.assert_called_once_with(
        "anchor_point_photos", 1280, indexed_fields=["anchor_point_id", "building_id"]
    )
    mock_qdrant.client.query_points.assert_called_once_with(
        "anchor_point_photos", query=[0.1] * 1280, limit=5
    )


def test_search_similar_respects_limit_form_field():
    mock_result = MagicMock()
    mock_result.points = []
    mock_qdrant = MagicMock()
    mock_qdrant.client.query_points.return_value = mock_result

    with (
        patch("app.main.qdrant", mock_qdrant),
        patch("app.main.extract_embedding", return_value=[0.1] * 1280),
    ):
        response = client.post(
            "/search_similar",
            files={"file": ("query.jpg", b"fake-bytes", "image/jpeg")},
            data={"limit": "10"},
        )

    assert response.status_code == 200
    mock_qdrant.client.query_points.assert_called_once_with(
        "anchor_point_photos", query=[0.1] * 1280, limit=10
    )


def test_delete_indexed_photo_forbidden_for_non_admin():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_admin_check_client(_USER_ROW)):
        response = client.delete("/index_photo/p1")
    assert response.status_code == 403


def test_delete_indexed_photo():
    _as_caller("admin1")
    mock_qdrant = MagicMock()
    with (
        patch("app.main.db.client", _mock_admin_check_client(_ADMIN_ROW)),
        patch("app.main.qdrant", mock_qdrant),
    ):
        response = client.delete("/index_photo/p1")

    assert response.status_code == 200
    assert response.json() == "ok"
    mock_qdrant.ensure_collection.assert_called_once_with(
        "anchor_point_photos", 1280, indexed_fields=["anchor_point_id", "building_id"]
    )
    mock_qdrant.client.delete.assert_called_once_with(
        "anchor_point_photos", points_selector=["p1"]
    )


def test_delete_indexed_anchor_forbidden_for_non_admin():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_admin_check_client(_USER_ROW)):
        response = client.delete("/index_anchor/a1")
    assert response.status_code == 403


def test_delete_indexed_anchor_filters_by_anchor_point_id():
    _as_caller("admin1")
    mock_qdrant = MagicMock()
    with (
        patch("app.main.db.client", _mock_admin_check_client(_ADMIN_ROW)),
        patch("app.main.qdrant", mock_qdrant),
    ):
        response = client.delete("/index_anchor/a1")

    assert response.status_code == 200
    assert response.json() == "ok"
    call = mock_qdrant.client.delete.call_args
    assert call.args[0] == "anchor_point_photos"
    condition = call.kwargs["points_selector"].must[0]
    assert condition.key == "anchor_point_id"
    assert condition.match.value == "a1"


def test_delete_indexed_building_forbidden_for_non_admin():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_admin_check_client(_USER_ROW)):
        response = client.delete("/index_building/b1")
    assert response.status_code == 403


def test_delete_indexed_building_filters_by_building_id():
    _as_caller("admin1")
    mock_qdrant = MagicMock()
    with (
        patch("app.main.db.client", _mock_admin_check_client(_ADMIN_ROW)),
        patch("app.main.qdrant", mock_qdrant),
    ):
        response = client.delete("/index_building/b1")

    assert response.status_code == 200
    assert response.json() == "ok"
    call = mock_qdrant.client.delete.call_args
    assert call.args[0] == "anchor_point_photos"
    condition = call.kwargs["points_selector"].must[0]
    assert condition.key == "building_id"
    assert condition.match.value == "b1"
