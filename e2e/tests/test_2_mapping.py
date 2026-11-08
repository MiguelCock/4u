"""An admin building the map: capture, photos, connections, verify, photo
search, and the guardrails (capture_screen, capture_photo_screen,
connect_anchor_points_screen, admin_home_screen)."""

import stack


def test_the_campus_was_built_and_is_searchable(admin, campus, ok):
    """The fixture made 3 verified points; photo search holds all their photos."""
    with admin.client() as api:
        indexed = set(ok(api.get("/ai-training/index_status"))["photo_ids"])
        points = {p["id"]: p for p in ok(api.get("/map/anchor-points"))}
    for point in campus["points"]:
        assert points[point["id"]]["status"] == "verified"
        assert {photo["id"] for photo in point["photos"]} <= indexed


def test_a_connection_over_30_m_is_refused(admin, campus, ok):
    building = campus["building"]
    with admin.client() as api:
        latitude, longitude = stack.offset(60)
        far = ok(
            api.post(
                "/map/anchor-points",
                json={
                    "building_id": building["id"],
                    "location_type_id": 10,
                    "latitude": latitude,
                    "longitude": longitude,
                    "floor": 0,
                    "metadata": {"indoor": True},
                },
            )
        )[0]
        refused = api.post(
            "/map/anchor-point-connections",
            json={
                "anchor_point_a_id": campus["points"][0]["id"],
                "anchor_point_b_id": far["id"],
            },
        )
        assert refused.status_code == 400
        assert "detail" in refused.json()
        api.delete(f"/map/anchor-points/{far['id']}").raise_for_status()


def test_verifying_without_photos_is_refused(admin, campus, ok):
    with admin.client() as api:
        latitude, longitude = stack.offset(5)
        bare = ok(
            api.post(
                "/map/anchor-points",
                json={
                    "building_id": campus["building"]["id"],
                    "location_type_id": 10,
                    "latitude": latitude,
                    "longitude": longitude,
                    "floor": 0,
                    "metadata": {"indoor": True},
                    "allow_nearby": True,
                },
            )
        )[0]
        refused = api.patch(
            f"/map/anchor-points/{bare['id']}", json={"status": "verified"}
        )
        assert refused.status_code == 400
        api.delete(f"/map/anchor-points/{bare['id']}").raise_for_status()


def test_the_same_connection_twice_is_a_readable_409(admin, campus):
    first, second = campus["points"][:2]
    with admin.client() as api:
        again = api.post(
            "/map/anchor-point-connections",
            # The other order: still the same connection.
            json={"anchor_point_a_id": second["id"], "anchor_point_b_id": first["id"]},
        )
    assert again.status_code == 409
    assert isinstance(again.json()["detail"], str)


def test_a_photo_can_be_added_and_removed(admin, campus, ok, add_photo):
    point = campus["points"][1]
    with admin.client() as api:
        photo = add_photo(api, point, seed=999)
        ok(api.delete(f"/map/anchor-point-photos/{photo['id']}"))
        ok(api.delete(f"/ai-training/index_photo/{photo['id']}"))
        remaining = {
            p["id"] for p in ok(api.get(f"/map/anchor-points/{point['id']}/photos"))
        }
    assert photo["id"] not in remaining


def test_a_connection_warning_is_saved(admin, campus, ok):
    connection = campus["connections"][0]
    with admin.client() as api:
        ok(
            api.patch(
                f"/map/anchor-point-connections/{connection['id']}",
                json={"notes": "Atención: tres escalones"},
            )
        )
        saved = [
            c
            for c in ok(api.get("/map/anchor-point-connections"))
            if c["id"] == connection["id"]
        ]
    assert saved[0]["notes"] == "Atención: tres escalones"


def test_reconcile_keeps_every_verified_photo(admin, campus, ok):
    with admin.client() as api:
        result = ok(api.post("/ai-training/reconcile"))
    assert result["kept"] >= sum(len(p["photos"]) for p in campus["points"])
