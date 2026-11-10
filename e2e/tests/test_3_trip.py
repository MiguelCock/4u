"""A user's trip, start to end, as the app runs it (user_home_screen,
navigation_screen): a route, a session, photos corrected against the map, logs,
the end, and feedback. Then what an admin sees of it."""

import itertools
from datetime import UTC, datetime

import pytest

import contracts
import stack


@pytest.fixture(scope="module")
def trip(user, campus, ok):
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
                json={
                    "user_id": user.id,
                    "building_id": campus["building"]["id"],
                    "route_id": route["id"],
                    "start_position": {
                        "lat": start["latitude"],
                        "lng": start["longitude"],
                    },
                    "device_info": {"platform": "e2e"},
                },
            )
        )[0]
    return {"route": route, "session": session}


def test_the_route_walks_the_connections(trip, campus):
    route = trip["route"]
    ids = [p["id"] for p in campus["points"]]
    assert [
        route["start_anchor_id"],
        *route["waypoint_anchor_ids"],
        route["end_anchor_id"],
    ] == ids


def test_the_same_trip_reuses_its_route(user, trip, campus, ok):
    start, _, end = campus["points"]
    with user.client() as api:
        again = ok(
            api.post(
                "/route/routes/find_or_create",
                json={"start_anchor_id": start["id"], "end_anchor_id": end["id"]},
            )
        )
    assert again["id"] == trip["route"]["id"]


def test_a_photo_of_a_point_corrects_the_position_to_it(user, trip, campus, ok):
    """The middle point's own photo, from a GPS fix 6 m off: photo search finds
    it, and positioning reports the match."""
    point = campus["points"][1]
    latitude, longitude = stack.offset(10 + 6)
    with user.client() as api:
        answer = ok(
            api.post(
                "/positioning/correct_position",
                data={
                    "session_id": trip["session"]["id"],
                    "latitude": str(latitude),
                    "longitude": str(longitude),
                    "accuracy": "8",
                    "heading": "90",
                    "gps_time": datetime.now(UTC).isoformat(),
                },
                files={"photo": ("frame.jpg", stack.photo(101), "image/jpeg")},
            )
        )
    assert answer["anchor_match_id"] == point["id"], answer.get("debug")
    assert answer["server_busy"] is False
    for field in ("corrected_lat", "corrected_long", "correction_error"):
        assert isinstance(answer[field], float)


def test_logs_are_kept_and_the_trip_ends(user, admin, trip, campus, ok):
    session = trip["session"]
    point = campus["points"][1]
    with user.client() as api:
        ok(
            api.post(
                "/navigation/logs",
                json={
                    "session_id": session["id"],
                    "gps_lat": point["latitude"],
                    "gps_long": point["longitude"],
                    "gps_accuracy": 8,
                    "corrected_lat": point["latitude"],
                    "corrected_long": point["longitude"],
                    "anchor_match_id": point["id"],
                    "confidence_score": 0.9,
                    "debug": {
                        "e2e": True,
                        "timing_ms": {"capture": 900, "correct": 1200},
                    },
                },
            )
        )
        active = ok(api.get("/navigation/sessions/active"))
        assert session["id"] in {s["id"] for s in active}
        ok(
            api.patch(
                f"/navigation/sessions/{session['id']}",
                json={"status": "completed", "end_time": datetime.now(UTC).isoformat()},
            )
        )
        assert session["id"] not in {
            s["id"] for s in ok(api.get("/navigation/sessions/active"))
        }
        ok(
            api.post(
                "/navigation/feedback",
                json={
                    "user_id": user.id,
                    "session_id": session["id"],
                    "comment": "Bien",
                },
            )
        )
    with admin.client() as api:
        logs = ok(api.get("/navigation/logs", params={"session_id": session["id"]}))
        feedback = ok(api.get("/navigation/feedback"))
    assert logs[0]["anchor_match_id"] == point["id"]
    assert any(
        f["comment"] == "Bien" and f["session_id"] == session["id"] for f in feedback
    )


def test_a_user_cant_read_another_users_trip(user, trip):
    other = stack.sign_up()
    with other.client() as api:
        response = api.get(
            "/navigation/logs", params={"session_id": trip["session"]["id"]}
        )
    assert response.status_code in (403, 404) or response.json() == []


def test_a_guidance_report_is_saved(user, trip, ok):
    with user.client() as api:
        ok(
            api.post(
                "/navigation/guidance-reports",
                json={
                    "session_id": trip["session"]["id"],
                    "instruction_text": "Gira a la izquierda",
                    "cue_type": "turn",
                },
            )
        )


def test_a_trip_starts_with_one_request_for_its_points(user, trip, campus, ok):
    """GET /anchor-points/by-ids: the route's points in order, and the
    connections between them, as NavigationScreen needs them (E2)."""
    route = trip["route"]
    ids = [
        route["start_anchor_id"],
        *route["waypoint_anchor_ids"],
        route["end_anchor_id"],
    ]
    with user.client() as api:
        body = ok(api.get("/map/anchor-points/by-ids", params={"ids": ",".join(ids)}))
    assert [p["id"] for p in body["points"]] == ids
    for point in body["points"]:
        assert contracts.POINT <= set(point)
    pairs = {
        frozenset((c["anchor_point_a_id"], c["anchor_point_b_id"]))
        for c in body["connections"]
    }
    assert {frozenset(pair) for pair in itertools.pairwise(ids)} <= pairs
    for connection in body["connections"]:
        assert contracts.CONNECTION <= set(connection)
