"""Every read the app makes keeps the fields the app uses (contracts.py), and the
version policy holds: the current and the oldest supported app work, an older
one gets 426, and a signed-in request with no version counts as old."""

from datetime import UTC, datetime, timedelta

import httpx
import pytest

import contracts
import stack


@pytest.fixture(scope="module")
def names(user, campus, ok):
    """Values for the paths' {names}: a trip of the test user, so sessions,
    logs and feedback have rows to check."""
    start, _, end = campus["points"]
    with user.client() as api:
        route = ok(
            api.post(
                "/route/routes/find_or_create",
                json={"start_anchor_id": start["id"], "end_anchor_id": end["id"]},
            )
        )
        session = ok(
            api.post(
                "/navigation/sessions",
                json={"user_id": user.id, "route_id": route["id"], "device_info": {}},
            )
        )[0]
        ok(
            api.post(
                "/navigation/logs",
                json={"session_id": session["id"], "gps_lat": 6.2, "gps_long": -75.5},
            )
        )
        ok(
            api.post(
                "/navigation/feedback",
                json={"user_id": user.id, "session_id": session["id"], "comment": "ok"},
            )
        )
    return {
        "point": start["id"],
        "route": route["id"],
        "session": session["id"],
        "user": user.id,
        "since": (datetime.now(UTC) - timedelta(minutes=5))
        .isoformat()
        .replace("+", "%2B"),
    }


def _check(response: httpx.Response, fields: set[str], what: str) -> None:
    assert response.status_code == 200, (
        f"{what}: {response.status_code} {response.text[:300]}"
    )
    body = response.json()
    items = body if isinstance(body, list) else [body]
    assert items, f"{what}: empty, so nothing could be checked"
    for item in items:
        missing = fields - set(item)
        assert not missing, f"{what}: the app reads {sorted(missing)}, which are gone"


@pytest.mark.parametrize(("what", "path", "fields"), contracts.ADMIN_READS)
def test_admin_reads(admin, names, what, path, fields):
    with admin.client() as api:
        _check(api.get(path.format(**names)), fields, what)


@pytest.mark.parametrize(("what", "path", "fields"), contracts.USER_READS)
def test_user_reads(user, names, what, path, fields):
    with user.client() as api:
        _check(api.get(path.format(**names)), fields, what)


@pytest.mark.parametrize(("what", "path", "fields"), contracts.PUBLIC_READS)
def test_public_reads(what, path, fields):
    with httpx.Client(base_url=stack.GATEWAY, timeout=30) as api:
        _check(api.get(path), fields, what)


@pytest.mark.parametrize("version", [stack.LATEST, stack.MIN_SUPPORTED])
def test_supported_app_versions_work(user, version):
    with user.client(version=version) as api:
        assert api.get("/map/places").status_code == 200


@pytest.mark.parametrize(
    "version", [stack.older_than_supported(), None], ids=["older", "no header"]
)
def test_older_apps_are_told_to_update(user, version):
    """No header with a token means an app from before the header (<= 0.5.1)."""
    with user.client(version=version) as api:
        response = api.get("/map/places")
    assert response.status_code == 426
    policy = response.json()
    assert policy["min_supported"] == stack.MIN_SUPPORTED


def test_the_photo_correction_answer_has_what_the_trip_reads(user, names, campus, ok):
    point = campus["points"][0]
    with user.client() as api:
        answer = ok(
            api.post(
                "/positioning/correct_position",
                data={
                    "session_id": names["session"],
                    "latitude": str(point["latitude"]),
                    "longitude": str(point["longitude"]),
                    "accuracy": "8",
                },
                files={"photo": ("frame.jpg", stack.photo(1), "image/jpeg")},
            )
        )
    assert {
        "corrected_lat",
        "corrected_long",
        "correction_error",
        "anchor_match_id",
        "confidence_score",
        "server_busy",
        "debug",
    } <= set(answer)
