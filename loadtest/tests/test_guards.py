import pytest

from loadtool.guards import UnsafeWrite, WriteGuard


def admin():
    guard = WriteGuard(building_id="sandbox")
    guard.points.add("mine")
    guard.points.add("mine2")
    return guard


def nav():
    guard = WriteGuard(route=("a", "b"))
    guard.sessions.add("my-trip")
    return guard


def test_reads_are_always_allowed():
    WriteGuard().check("GET", "/map/anchor-points")


@pytest.mark.parametrize(
    "method,path,body",
    [
        ("POST", "/map/anchor-points", {"building_id": "sandbox"}),
        ("POST", "/map/anchor-points/upload-image", None),
        ("POST", "/map/anchor-points/mine/photos", {}),
        ("PATCH", "/map/anchor-points/mine", {"status": "verified"}),
        (
            "POST",
            "/map/anchor-point-connections",
            {"anchor_point_a_id": "mine", "anchor_point_b_id": "mine2"},
        ),
        ("POST", "/ai-training/index_anchor", {"anchor_point_id": "mine"}),
    ],
)
def test_an_admin_may_change_its_own_sandbox_data(method, path, body):
    admin().check(method, path, body)


@pytest.mark.parametrize(
    "method,path,body",
    [
        ("POST", "/map/anchor-points", {"building_id": "real-building"}),
        ("POST", "/map/anchor-points", {}),
        ("PATCH", "/map/anchor-points/real-point", {"status": "verified"}),
        ("POST", "/map/anchor-points/real-point/photos", {}),
        ("DELETE", "/map/anchor-points/mine", None),
        ("DELETE", "/map/places/real", None),
        ("DELETE", "/map/anchor-point-connections/real", None),
        (
            "POST",
            "/map/anchor-point-connections",
            {"anchor_point_a_id": "mine", "anchor_point_b_id": "real-point"},
        ),
        ("POST", "/ai-training/index_anchor", {"anchor_point_id": "real-point"}),
        ("POST", "/ai-training/reconcile", {}),
        ("PATCH", "/user/profiles/someone", {"role_id": 2}),
        ("POST", "/route/routes", {}),
        ("PATCH", "/map/buildings/real", {}),
    ],
)
def test_nothing_else_may_be_changed(method, path, body):
    with pytest.raises(UnsafeWrite):
        admin().check(method, path, body)


def test_a_user_may_run_its_own_trip():
    guard = nav()
    guard.check(
        "POST",
        "/route/routes/find_or_create",
        {"start_anchor_id": "a", "end_anchor_id": "b"},
    )
    guard.check("POST", "/navigation/sessions", {})
    guard.check("POST", "/navigation/logs", {"session_id": "my-trip"})
    guard.check("POST", "/positioning/correct_position", {"session_id": "my-trip"})
    guard.check("PATCH", "/navigation/sessions/my-trip", {})


@pytest.mark.parametrize(
    "method,path,body",
    [
        (
            "POST",
            "/route/routes/find_or_create",
            {"start_anchor_id": "a", "end_anchor_id": "other"},
        ),
        ("POST", "/navigation/logs", {"session_id": "someone-else"}),
        ("POST", "/positioning/correct_position", {"session_id": "someone-else"}),
        ("PATCH", "/navigation/sessions/someone-else", {}),
        ("POST", "/map/anchor-points", {"building_id": "sandbox"}),
        ("POST", "/map/anchor-points/upload-image", None),
    ],
)
def test_a_user_can_touch_nothing_else(method, path, body):
    with pytest.raises(UnsafeWrite):
        nav().check(method, path, body)


def test_a_query_string_does_not_get_around_it():
    with pytest.raises(UnsafeWrite):
        admin().check("PATCH", "/map/anchor-points/real?x=/mine", {})
