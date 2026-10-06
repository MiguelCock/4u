from unittest.mock import AsyncMock, patch

import httpx
import pytest
from fastapi.testclient import TestClient

from app.main import _search_similar, app, get_caller_id

client = TestClient(app)


@pytest.fixture(autouse=True)
def _clear_overrides():
    yield
    app.dependency_overrides.clear()


def _as_caller(caller_id: str) -> None:
    app.dependency_overrides[get_caller_id] = lambda: caller_id


def _post_correction(session_id="s1", lat=6.2, lng=-75.6, accuracy=5.0):
    _as_caller("u1")
    return client.post(
        "/correct_position",
        data={
            "session_id": session_id,
            "latitude": lat,
            "longitude": lng,
            "accuracy": accuracy,
        },
        files={"photo": ("frame.jpg", b"fake-bytes", "image/jpeg")},
    )


def test_root():
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {"service": "backend-positioning", "status": "ok"}


def test_no_token_is_rejected():
    response = client.post(
        "/correct_position",
        data={"session_id": "s1", "latitude": 6.2, "longitude": -75.6, "accuracy": 5.0},
        files={"photo": ("frame.jpg", b"fake-bytes", "image/jpeg")},
    )
    assert response.status_code == 401


def test_garbage_token_is_rejected():
    with patch("app.main.db.get_user_id_from_token", side_effect=Exception("bad")):
        response = client.post(
            "/correct_position",
            data={
                "session_id": "s1",
                "latitude": 6.2,
                "longitude": -75.6,
                "accuracy": 5.0,
            },
            files={"photo": ("frame.jpg", b"fake-bytes", "image/jpeg")},
            headers={"Authorization": "Bearer garbage"},
        )
    assert response.status_code == 401


def test_correct_position_fuses_gps_and_visual_match():
    match = {
        "anchor_point_id": "a1",
        "photo_id": "p1",
        "latitude": 6.20005,
        "longitude": -75.6,
        "building_id": "b1",
        "score": 0.95,
    }
    with patch("app.main._search_similar", AsyncMock(return_value=match)):
        response = _post_correction(session_id="test-fuse")

    assert response.status_code == 200
    body = response.json()
    assert body["anchor_match_id"] == "a1"
    assert body["confidence_score"] == 0.95
    assert body["raw_image_url"] is None
    assert isinstance(body["corrected_lat"], float)
    assert isinstance(body["correction_error"], float)


def test_correct_position_degrades_to_gps_only_when_visual_match_unavailable():
    with patch("app.main._search_similar", AsyncMock(return_value=None)):
        response = _post_correction(session_id="test-degrade")

    assert response.status_code == 200
    body = response.json()
    assert body["anchor_match_id"] is None
    assert body["confidence_score"] is None
    # Must still return a sane correction - a visual-service blip degrades
    # gracefully, it doesn't fail the whole request.
    assert abs(body["corrected_lat"] - 6.2) < 0.01


def test_correct_position_requires_session_id():
    _as_caller("u1")
    response = client.post(
        "/correct_position",
        data={"latitude": 6.2, "longitude": -75.6, "accuracy": 5.0},
        files={"photo": ("frame.jpg", b"fake-bytes", "image/jpeg")},
    )
    assert response.status_code == 422


@pytest.mark.asyncio
async def test_search_similar_retries_then_gives_up_on_persistent_failure():
    mock_client = AsyncMock()
    mock_client.post.side_effect = httpx.TimeoutException("timed out")
    mock_client.__aenter__.return_value = mock_client
    mock_client.__aexit__.return_value = None

    with patch("app.main.httpx.AsyncClient", return_value=mock_client):
        result = await _search_similar(b"fake-bytes", "frame.jpg")

    assert result is None
    # Initial attempt + the configured retries, not a single bare try.
    from app.main import _SEARCH_RETRIES

    assert mock_client.post.call_count == _SEARCH_RETRIES + 1


@pytest.mark.asyncio
async def test_search_similar_recovers_after_one_transient_failure():
    ok_response = AsyncMock()
    ok_response.raise_for_status = lambda: None
    ok_response.json = lambda: {"matches": [{"anchor_point_id": "a1", "score": 0.9}]}

    mock_client = AsyncMock()
    mock_client.post.side_effect = [httpx.TimeoutException("timed out"), ok_response]
    mock_client.__aenter__.return_value = mock_client
    mock_client.__aexit__.return_value = None

    with patch("app.main.httpx.AsyncClient", return_value=mock_client):
        result = await _search_similar(b"fake-bytes", "frame.jpg")

    assert result == {"anchor_point_id": "a1", "score": 0.9}
    assert mock_client.post.call_count == 2
