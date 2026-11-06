from unittest.mock import AsyncMock, patch

import httpx
import pytest
from fastapi.testclient import TestClient
from supabase import AuthApiError

from app.main import _search_similar, app, get_caller_id

client = TestClient(app)

_BAD_JWT = AuthApiError("invalid JWT: token is expired", 403, "bad_jwt")


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
    with patch("app.main.db.get_user_id_from_token", side_effect=_BAD_JWT):
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
    with patch("app.main._search_similar", AsyncMock(return_value=[match])):
        response = _post_correction(session_id="test-fuse")

    assert response.status_code == 200
    body = response.json()
    assert body["anchor_match_id"] == "a1"
    assert body["confidence_score"] == 0.95
    assert body["raw_image_url"] is None
    assert isinstance(body["corrected_lat"], float)
    assert isinstance(body["correction_error"], float)
    assert body["debug"]["candidates"][0]["verdict"] == "applied"


def test_correct_position_says_when_the_model_was_busy():
    async def busy(*_args, timing=None):
        timing["busy"] = True
        return []

    with patch("app.main._search_similar", busy):
        response = _post_correction(session_id="test-busy")

    assert response.status_code == 200
    body = response.json()
    assert body["server_busy"] is True
    assert body["anchor_match_id"] is None
    assert body["debug"]["server_busy"] is True
    assert "busy" not in body["debug"].get("search_timing", {})


def test_correct_position_degrades_to_gps_only_when_visual_match_unavailable():
    with patch("app.main._search_similar", AsyncMock(return_value=[])):
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


def _search_client(side_effect):
    mock_client = AsyncMock()
    mock_client.post.side_effect = side_effect
    mock_client.__aenter__.return_value = mock_client
    mock_client.__aexit__.return_value = None
    return mock_client


@pytest.mark.asyncio
async def test_search_similar_doesnt_retry_a_timeout():
    mock_client = _search_client(httpx.ReadTimeout("timed out"))
    timing = {}
    with patch("app.main.httpx.AsyncClient", return_value=mock_client):
        result = await _search_similar(
            b"fake", "frame.jpg", 6.24, -75.58, timing=timing
        )

    assert result == []
    assert mock_client.post.call_count == 1
    assert timing["busy"] is True


@pytest.mark.asyncio
async def test_search_similar_doesnt_retry_a_busy_answer():
    mock_client = _search_client([httpx.Response(503, json={"detail": "Busy"})])
    timing = {}
    with patch("app.main.httpx.AsyncClient", return_value=mock_client):
        result = await _search_similar(
            b"fake", "frame.jpg", 6.24, -75.58, timing=timing
        )

    assert result == []
    assert mock_client.post.call_count == 1
    assert timing["busy"] is True


@pytest.mark.asyncio
async def test_search_similar_retries_a_failed_connection_once():
    mock_client = _search_client(httpx.ConnectError("refused"))
    timing = {}
    with patch("app.main.httpx.AsyncClient", return_value=mock_client):
        result = await _search_similar(
            b"fake", "frame.jpg", 6.24, -75.58, timing=timing
        )

    assert result == []
    assert mock_client.post.call_count == 2
    assert timing["busy"] is True


@pytest.mark.asyncio
async def test_search_similar_recovers_when_the_retry_connects():
    request = httpx.Request("POST", "http://ai-training/search_similar")
    answer = httpx.Response(200, json={"matches": [{"id": 1}]}, request=request)
    mock_client = _search_client([httpx.ConnectError("refused"), answer])
    timing = {}
    with patch("app.main.httpx.AsyncClient", return_value=mock_client):
        result = await _search_similar(
            b"fake", "frame.jpg", 6.24, -75.58, timing=timing
        )

    assert result == [{"id": 1}]
    assert "busy" not in timing


@pytest.mark.asyncio
async def test_search_similar_isnt_busy_on_a_server_error():
    request = httpx.Request("POST", "http://ai-training/search_similar")
    mock_client = _search_client([httpx.Response(500, request=request)])
    timing = {}
    with patch("app.main.httpx.AsyncClient", return_value=mock_client):
        result = await _search_similar(
            b"fake", "frame.jpg", 6.24, -75.58, timing=timing
        )

    assert result == []
    assert "busy" not in timing


@pytest.mark.asyncio
async def test_search_similar_forwards_latitude_and_longitude():
    ok_response = AsyncMock()
    ok_response.raise_for_status = lambda: None
    ok_response.json = lambda: {"matches": []}

    mock_client = AsyncMock()
    mock_client.post.return_value = ok_response
    mock_client.__aenter__.return_value = mock_client
    mock_client.__aexit__.return_value = None

    with patch("app.main.httpx.AsyncClient", return_value=mock_client):
        await _search_similar(b"fake-bytes", "frame.jpg", 6.24, -75.58)

    call = mock_client.post.call_args
    assert call.kwargs["data"]["latitude"] == "6.24"
    assert call.kwargs["data"]["longitude"] == "-75.58"
    # Several candidates within a tight radius, not the top-1 of 150 m.
    assert call.kwargs["data"]["limit"] == "5"
    assert call.kwargs["data"]["radius_meters"] == "60.0"


# --- /correct_position_once: stateless, no session ----------------------


def _post_once(lat=6.2, lng=-75.6, accuracy=5.0):
    _as_caller("u1")
    return client.post(
        "/correct_position_once",
        data={"latitude": lat, "longitude": lng, "accuracy": accuracy},
        files={"photo": ("frame.jpg", b"fake-bytes", "image/jpeg")},
    )


def test_correct_position_once_rejects_missing_token():
    response = client.post(
        "/correct_position_once",
        data={"latitude": 6.2, "longitude": -75.6, "accuracy": 5.0},
        files={"photo": ("frame.jpg", b"fake-bytes", "image/jpeg")},
    )
    assert response.status_code == 401


def test_correct_position_once_pulls_toward_a_confident_match():
    # Match ~22m north of a fix with 20m GPS accuracy - accepted (within
    # 2.5 x accuracy) with a distance-scaled sigma of ~9.6 m, it still pulls
    # the result most of the way to it.
    match = {
        "anchor_point_id": "a1",
        "latitude": 6.2002,
        "longitude": -75.6,
        "score": 0.95,
    }
    with patch("app.main._search_similar", AsyncMock(return_value=[match])):
        response = _post_once(accuracy=20.0)

    assert response.status_code == 200
    body = response.json()
    assert body["anchor_match_id"] == "a1"
    assert body["confidence_score"] == 0.95
    assert 6.2 + 0.5 * 0.0002 < body["corrected_lat"] < 6.2002
    assert body["corrected_long"] == pytest.approx(-75.6, abs=1e-6)


def test_correct_position_once_ignores_a_low_score_match():
    match = {
        "anchor_point_id": "a1",
        "latitude": 6.2002,
        "longitude": -75.6,
        "score": 0.1,
    }
    with patch("app.main._search_similar", AsyncMock(return_value=[match])):
        response = _post_once()

    body = response.json()
    assert body["anchor_match_id"] is None
    assert body["corrected_lat"] == pytest.approx(6.2, abs=1e-6)


def test_correct_position_once_returns_gps_fix_without_a_match():
    with patch("app.main._search_similar", AsyncMock(return_value=[])):
        response = _post_once()

    assert response.status_code == 200
    body = response.json()
    assert body["anchor_match_id"] is None
    assert body["confidence_score"] is None
    assert body["corrected_lat"] == pytest.approx(6.2, abs=1e-6)
    assert body["corrected_long"] == pytest.approx(-75.6, abs=1e-6)


def test_correct_position_once_keeps_no_session_state():
    from app.main import _store

    before = dict(_store._sessions)
    with patch("app.main._search_similar", AsyncMock(return_value=[])):
        _post_once()
    assert _store._sessions == before


def _post_with_frame(caller="admin-1", admin=True):
    _as_caller(caller)
    storage = patch("app.main.db.client")
    with (
        patch("app.main._search_similar", AsyncMock(return_value=[])),
        patch("app.main.db.is_admin", return_value=admin),
        storage as mock_client,
        patch("app.main._store_frame") as store,
    ):
        mock_client.storage.from_.return_value.get_public_url.side_effect = (
            lambda name: f"https://example/{name}"
        )
        response = client.post(
            "/correct_position",
            data={
                "session_id": "frames",
                "latitude": 6.2,
                "longitude": -75.6,
                "accuracy": 5.0,
                "store_frame": "true",
            },
            files={"photo": ("frame.jpg", b"jpeg-bytes", "image/jpeg")},
        )
    return response, store


def test_an_admin_test_walk_keeps_its_frame():
    response, store = _post_with_frame()
    assert response.status_code == 200
    url = response.json()["raw_image_url"]
    assert url.startswith("https://example/frame-frames-")
    # Uploaded after the response, under the same name.
    store.assert_called_once()
    data, name = store.call_args.args
    assert data == b"jpeg-bytes" and url.endswith(name)


def test_only_admins_may_store_frames():
    response, store = _post_with_frame(caller="user-1", admin=False)
    assert response.status_code == 403
    store.assert_not_called()


def test_frames_are_not_stored_by_default():
    with (
        patch("app.main._search_similar", AsyncMock(return_value=[])),
        patch("app.main._store_frame") as store,
    ):
        response = _post_correction(session_id="no-frames")
    assert response.json()["raw_image_url"] is None
    assert "total_ms" in response.json()["debug"]
    store.assert_not_called()


def test_debug_splits_the_round_trip():
    async def fake_search(*args, timing=None, **kwargs):
        timing.update({"embed": 500, "qdrant": 40})
        return []

    with patch("app.main._search_similar", fake_search):
        response = _post_correction(session_id="test-timing")
    debug = response.json()["debug"]
    assert debug["search_timing"] == {"embed": 500, "qdrant": 40}
    assert debug["upload_ms"] >= 0
    assert debug["auth_ms"] >= 0


@pytest.mark.asyncio
async def test_search_similar_reports_its_timing():
    response = httpx.Response(
        200,
        json={"matches": [], "timing_ms": {"embed": 480, "qdrant": 35}},
        request=httpx.Request("POST", "http://ai-training/search_similar"),
    )
    timing = {}
    with patch("httpx.AsyncClient.post", AsyncMock(return_value=response)):
        await _search_similar(b"x", "frame.jpg", 6.2, -75.6, timing=timing)
    assert timing == {"embed": 480, "qdrant": 35}


def test_a_session_id_is_private_to_its_caller():
    from app.main import _store

    with patch("app.main._search_similar", AsyncMock(return_value=[])):
        _as_caller("alice")
        client.post(
            "/correct_position",
            data={
                "session_id": "shared",
                "latitude": 6.2,
                "longitude": -75.6,
                "accuracy": 5.0,
            },
            files={"photo": ("frame.jpg", b"x", "image/jpeg")},
        )
        _as_caller("mallory")
        client.post(
            "/correct_position",
            data={
                "session_id": "shared",
                "latitude": 6.3,
                "longitude": -75.7,
                "accuracy": 5.0,
            },
            files={"photo": ("frame.jpg", b"x", "image/jpeg")},
        )
    assert "alice:shared" in _store._sessions
    assert "mallory:shared" in _store._sessions
    assert _store._sessions["alice:shared"].lat0 == 6.2
