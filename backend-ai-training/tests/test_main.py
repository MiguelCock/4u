from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_root():
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {"service": "backend-ai-training", "status": "ok"}


def test_index_anchor_upserts_one_point_per_photo():
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
        patch("app.main.qdrant", mock_qdrant),
        patch("app.main.download_image", return_value=b"fake-bytes"),
        patch("app.main.extract_embedding", return_value=[0.1] * 1280),
    ):
        response = client.post("/index_anchor", json=payload)

    assert response.status_code == 200
    assert response.json() == {"indexed": 2}
    mock_qdrant.ensure_collection.assert_called_once_with("anchor_point_photos", 1280)
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
    payload = {
        "anchor_point_id": "a1",
        "latitude": 6.24,
        "longitude": -75.58,
        "building_id": "b1",
        "photos": [],
    }
    mock_qdrant = MagicMock()
    with patch("app.main.qdrant", mock_qdrant):
        response = client.post("/index_anchor", json=payload)
    assert response.status_code == 200
    assert response.json() == {"indexed": 0}
    mock_qdrant.client.upsert.assert_not_called()


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
    mock_qdrant.ensure_collection.assert_called_once_with("anchor_point_photos", 1280)
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
