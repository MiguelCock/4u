"""Two admins editing at once (A5): no silent overwrite, and GET /changes."""

from datetime import UTC, datetime, timedelta

import pytest

import stack


@pytest.fixture
def point(admin, campus, ok):
    latitude, longitude = stack.offset(-8)
    created = ok(
        admin.client().post(
            "/map/anchor-points",
            json={
                "building_id": campus["building"]["id"],
                "location_type_id": 1,
                "latitude": latitude,
                "longitude": longitude,
                "floor": 0,
                "location_description": stack.unique("Puerta"),
                "metadata": {"indoor": True},
            },
        )
    )[0]
    yield created
    admin.client().delete(f"/map/anchor-points/{created['id']}")


@pytest.fixture(scope="module")
def other_admin():
    return stack.sign_up("admin")


def test_a_save_over_another_admins_change_is_a_409(admin, other_admin, point, ok):
    seen = point["location_description"]
    with admin.client() as api:
        ok(
            api.patch(
                f"/map/anchor-points/{point['id']}",
                json={
                    "location_description": "A",
                    "expected": {"location_description": seen},
                },
            )
        )
    with other_admin.client() as api:
        refused = api.patch(
            f"/map/anchor-points/{point['id']}",
            json={
                "location_description": "B",
                "expected": {"location_description": seen},
            },
        )
    assert refused.status_code == 409
    detail = refused.json()["detail"]
    assert detail["fields"] == ["location_description"]
    assert detail["current"]["location_description"] == "A"


def test_edits_to_different_fields_both_apply(admin, other_admin, point, ok):
    with admin.client() as api:
        ok(
            api.patch(
                f"/map/anchor-points/{point['id']}",
                json={
                    "location_description": "Renamed",
                    "expected": {"location_description": point["location_description"]},
                },
            )
        )
    with other_admin.client() as api:
        moved = api.patch(
            f"/map/anchor-points/{point['id']}",
            json={
                "latitude": point["latitude"] + 0.00001,
                "expected": {"latitude": point["latitude"]},
            },
        )
        assert moved.status_code == 200
        now = ok(api.get(f"/map/anchor-points/{point['id']}"))
    assert now["location_description"] == "Renamed"
    assert now["latitude"] == pytest.approx(point["latitude"] + 0.00001)


def test_older_apps_without_expected_still_save(other_admin, point, ok):
    with other_admin.client(version=stack.MIN_SUPPORTED) as api:
        ok(api.patch(f"/map/anchor-points/{point['id']}", json={"floor": 1}))


def test_changes_lists_edits_and_deletions(admin, point, ok):
    since = (datetime.now(UTC) - timedelta(seconds=30)).isoformat()
    with admin.client() as api:
        ok(
            api.patch(
                f"/map/anchor-points/{point['id']}",
                json={"location_description": stack.unique("Changed")},
            )
        )
        changes = ok(api.get("/map/changes", params={"since": since}))
        assert changes["full"] is False
        assert point["id"] in {p["id"] for p in changes["anchor_points"]}
        ok(api.delete(f"/map/anchor-points/{point['id']}"))
        after = ok(api.get("/map/changes", params={"since": since}))
    assert point["id"] in after["deleted"]["anchor_points"]
    assert point["id"] not in {p["id"] for p in after["anchor_points"]}


def test_changes_from_too_long_ago_ask_for_a_full_load(admin, ok):
    since = (datetime.now(UTC) - timedelta(hours=2)).isoformat()
    with admin.client() as api:
        assert ok(api.get("/map/changes", params={"since": since}))["full"] is True
