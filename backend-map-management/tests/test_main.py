from unittest.mock import MagicMock, patch

import pytest
from fastapi.testclient import TestClient
from supabase import AuthApiError

from app.main import app, get_caller_id

client = TestClient(app)

_BAD_JWT = AuthApiError("invalid JWT: token is expired", 403, "bad_jwt")


@pytest.fixture(autouse=True)
def _clear_overrides():
    # Every test either overrides get_caller_id explicitly (to act as a
    # given caller) or relies on there being none (to hit the real 401
    # path) - always start from a clean slate and clean up after.
    yield
    app.dependency_overrides.clear()


def _as_caller(caller_id: str) -> None:
    app.dependency_overrides[get_caller_id] = lambda: caller_id


_ADMIN_ROW = [{"role_id": 2}]
_USER_ROW = [{"role_id": 1}]


def test_root():
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {"service": "backend-map-management", "status": "ok"}


# --- authentication -----------------------------------------------------


def test_no_token_is_rejected():
    response = client.get("/anchor-points")
    assert response.status_code == 401


def test_garbage_token_is_rejected():
    with patch("app.main.db.get_user_id_from_token", side_effect=_BAD_JWT):
        response = client.get(
            "/anchor-points", headers={"Authorization": "Bearer garbage"}
        )
    assert response.status_code == 401


def _mock_select_eq_result(rows):
    mock_client = MagicMock()
    mock_client.table.return_value.select.return_value.eq.return_value.execute.return_value.data = rows
    return mock_client


def _mock_insert_result(rows):
    # select().eq() defaults to an admin row - every endpoint that uses this
    # helper is admin-only, and none of them otherwise call select().eq()
    # (see the per-endpoint notes below), so this single chain can serve
    # both the _is_admin check and (where applicable) the real business logic.
    mock_client = MagicMock()
    mock_client.table.return_value.insert.return_value.execute.return_value.data = rows
    mock_client.table.return_value.select.return_value.eq.return_value.execute.return_value.data = _ADMIN_ROW
    return mock_client


def _mock_select_result(rows):
    mock_client = MagicMock()
    select = mock_client.table.return_value.select.return_value
    select.execute.return_value.data = rows
    # List endpoints page through select_all: select().order().range().
    select.order.return_value.range.return_value.execute.return_value.data = rows
    return mock_client


def _mock_delete_eq_result():
    mock_client = MagicMock()
    # One row deleted - an empty result now means "not found" (404).
    mock_client.table.return_value.delete.return_value.eq.return_value.execute.return_value.data = [
        {"id": "deleted"}
    ]
    mock_client.table.return_value.select.return_value.eq.return_value.execute.return_value.data = _ADMIN_ROW
    return mock_client


def _mock_update_eq_result(rows):
    mock_client = MagicMock()
    mock_client.table.return_value.update.return_value.eq.return_value.execute.return_value.data = rows
    mock_client.table.return_value.select.return_value.eq.return_value.execute.return_value.data = _ADMIN_ROW
    return mock_client


def _mock_select_or_result(rows):
    mock_client = MagicMock()
    mock_client.table.return_value.select.return_value.or_.return_value.execute.return_value.data = rows
    return mock_client


def _mock_multi_table_client(table_mocks):
    mock_client = MagicMock()
    mock_client.table.side_effect = lambda name: table_mocks[name]
    return mock_client


def _profiles_table(admin: bool) -> MagicMock:
    profiles_table = MagicMock()
    profiles_table.select.return_value.eq.return_value.execute.return_value.data = (
        _ADMIN_ROW if admin else _USER_ROW
    )
    return profiles_table


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
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_eq_result([_ANCHOR_POINT_ROW])):
        response = client.get("/anchor-points/1")
    assert response.status_code == 200
    assert response.json()["id"] == "1"


def test_get_anchor_point_404_when_missing():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_eq_result([])):
        response = client.get("/anchor-points/missing")
    assert response.status_code == 404


def test_create_anchor_point_forbidden_for_non_admin():
    _as_caller("u1")
    payload = {
        "building_id": "b1",
        "latitude": 6.24,
        "longitude": -75.58,
        "location_description": "Front door",
    }
    with patch("app.main.db.client", _mock_select_eq_result(_USER_ROW)):
        response = client.post("/anchor-points", json=payload)
    assert response.status_code == 403


def test_create_anchor_point_returns_created_row():
    _as_caller("admin1")
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


def test_create_anchor_point_allows_unnamed_in_between_point():
    _as_caller("admin1")
    payload = {
        "building_id": "b1",
        "latitude": 6.24,
        "longitude": -75.58,
        "location_type_id": 10,  # hallway
        "location_description": "   ",
    }
    mock_client = _mock_insert_result([{**payload, "id": "1"}])
    with patch("app.main.db.client", mock_client):
        response = client.post("/anchor-points", json=payload)
    assert response.status_code == 200
    insert_payload = mock_client.table.return_value.insert.call_args.args[0]
    assert insert_payload["location_description"] is None


def test_create_anchor_point_requires_description_for_destination_type():
    _as_caller("admin1")
    payload = {
        "building_id": "b1",
        "latitude": 6.24,
        "longitude": -75.58,
        "location_type_id": 5,  # classroom
    }
    mock_client = _mock_insert_result([])
    with patch("app.main.db.client", mock_client):
        response = client.post("/anchor-points", json=payload)
    assert response.status_code == 400
    assert "description" in response.json()["detail"]
    mock_client.table.return_value.insert.assert_not_called()


def test_create_anchor_point_passes_metadata_through():
    _as_caller("admin1")
    payload = {
        "building_id": "b1",
        "latitude": 6.24,
        "longitude": -75.58,
        "location_description": "Front door",
        "metadata": {"indoor": False, "lighting": "bright", "surface": "concrete"},
    }
    mock_client = _mock_insert_result([{**payload, "id": "1"}])
    with patch("app.main.db.client", mock_client):
        response = client.post("/anchor-points", json=payload)
    assert response.status_code == 200
    insert_payload = mock_client.table.return_value.insert.call_args.args[0]
    assert insert_payload["metadata"] == {
        "indoor": False,
        "lighting": "bright",
        "surface": "concrete",
    }


def test_create_anchor_point_defaults_metadata_to_empty_fields():
    _as_caller("admin1")
    payload = {
        "building_id": "b1",
        "latitude": 6.24,
        "longitude": -75.58,
        "location_description": "Front door",
    }
    mock_client = _mock_insert_result([{**payload, "id": "1"}])
    with patch("app.main.db.client", mock_client):
        response = client.post("/anchor-points", json=payload)
    assert response.status_code == 200
    insert_payload = mock_client.table.return_value.insert.call_args.args[0]
    assert insert_payload["metadata"] == {
        "indoor": None,
        "lighting": None,
        "surface": None,
    }


def test_create_anchor_point_rejects_invalid_lighting():
    _as_caller("admin1")
    payload = {
        "building_id": "b1",
        "latitude": 6.24,
        "longitude": -75.58,
        "location_description": "Front door",
        "metadata": {"lighting": "pitch-black"},
    }
    with patch("app.main.db.client", _mock_insert_result([])):
        response = client.post("/anchor-points", json=payload)
    assert response.status_code == 422


def test_update_anchor_point_returns_updated_row():
    _as_caller("admin1")
    mock_client = _mock_update_eq_result([{**_ANCHOR_POINT_ROW, "floor": 2}])
    with patch("app.main.db.client", mock_client):
        response = client.patch("/anchor-points/1", json={"floor": 2})
    assert response.status_code == 200
    assert response.json() == [{**_ANCHOR_POINT_ROW, "floor": 2}]
    mock_client.table.return_value.update.assert_called_once_with({"floor": 2})


def test_update_anchor_point_persists_latitude_and_longitude():
    _as_caller("admin1")
    payload = {"latitude": 6.25, "longitude": -75.59}
    mock_client = _mock_update_eq_result([{**_ANCHOR_POINT_ROW, **payload}])
    with patch("app.main.db.client", mock_client):
        response = client.patch("/anchor-points/1", json=payload)
    assert response.status_code == 200
    mock_client.table.return_value.update.assert_called_once_with(payload)


def test_update_anchor_point_persists_metadata_when_provided():
    _as_caller("admin1")
    payload = {"metadata": {"indoor": True, "lighting": "dim", "surface": "tile"}}
    mock_client = _mock_update_eq_result([{**_ANCHOR_POINT_ROW, **payload}])
    with patch("app.main.db.client", mock_client):
        response = client.patch("/anchor-points/1", json=payload)
    assert response.status_code == 200
    mock_client.table.return_value.update.assert_called_once_with(payload)


def test_update_anchor_point_omits_metadata_when_not_provided():
    _as_caller("admin1")
    payload = {"floor": 2}
    mock_client = _mock_update_eq_result([{**_ANCHOR_POINT_ROW, **payload}])
    with patch("app.main.db.client", mock_client):
        response = client.patch("/anchor-points/1", json=payload)
    assert response.status_code == 200
    update_payload = mock_client.table.return_value.update.call_args.args[0]
    assert "metadata" not in update_payload


def test_get_anchor_point_includes_metadata():
    # metadata is a loose dict on the response model (not the strict
    # AnchorPointMetadata submodel), so it passes through exactly as
    # stored - no defaults get filled in for keys the row doesn't have.
    _as_caller("u1")
    row = {**_ANCHOR_POINT_ROW, "metadata": {"indoor": True, "lighting": "bright"}}
    with patch("app.main.db.client", _mock_select_eq_result([row])):
        response = client.get("/anchor-points/1")
    assert response.status_code == 200
    assert response.json()["metadata"] == {"indoor": True, "lighting": "bright"}


def test_get_anchor_point_defaults_metadata_when_row_has_none():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_eq_result([_ANCHOR_POINT_ROW])):
        response = client.get("/anchor-points/1")
    assert response.status_code == 200
    assert response.json()["metadata"] == {}


def test_delete_anchor_point_forbidden_for_non_admin():
    _as_caller("u1")
    mock_client = _mock_multi_table_client({"profiles": _profiles_table(admin=False)})
    with patch("app.main.db.client", mock_client):
        response = client.delete("/anchor-points/1")
    assert response.status_code == 403


def test_delete_anchor_point_returns_ok():
    _as_caller("admin1")
    photos_table = MagicMock()
    photos_table.select.return_value.in_.return_value.execute.return_value.data = [
        {"image_url": "https://example.com/a.jpg"},
        {"image_url": "https://example.com/b.jpg"},
    ]
    photos_table.select.return_value.in_.return_value.order.return_value.range.return_value.execute.return_value.data = [
        {"image_url": "https://example.com/a.jpg"},
        {"image_url": "https://example.com/b.jpg"},
    ]
    anchor_points_table = MagicMock()
    anchor_points_table.delete.return_value.eq.return_value.execute.return_value.data = [
        {"id": "1"}
    ]
    mock_client = _mock_multi_table_client(
        {
            "anchor_point_photos": photos_table,
            "anchor_points": anchor_points_table,
            "profiles": _profiles_table(admin=True),
        }
    )
    with (
        patch("app.main.db.client", mock_client),
        patch("app.main.db.delete_images_by_url") as mock_delete_images,
    ):
        response = client.delete("/anchor-points/1")
    assert response.status_code == 200
    assert response.json() == "ok"
    photos_table.select.return_value.in_.assert_called_once_with(
        "anchor_point_id", ["1"]
    )
    anchor_points_table.delete.return_value.eq.assert_called_once_with("id", "1")
    mock_delete_images.assert_called_once_with(
        "anchor-points",
        ["https://example.com/a.jpg", "https://example.com/b.jpg"],
    )


def test_delete_anchor_point_does_not_call_storage_when_no_photos():
    _as_caller("admin1")
    photos_table = MagicMock()
    photos_table.select.return_value.in_.return_value.execute.return_value.data = []
    photos_table.select.return_value.in_.return_value.order.return_value.range.return_value.execute.return_value.data = []
    anchor_points_table = MagicMock()
    anchor_points_table.delete.return_value.eq.return_value.execute.return_value.data = [
        {"id": "1"}
    ]
    mock_client = _mock_multi_table_client(
        {
            "anchor_point_photos": photos_table,
            "anchor_points": anchor_points_table,
            "profiles": _profiles_table(admin=True),
        }
    )
    with (
        patch("app.main.db.client", mock_client),
        patch("app.main.db.delete_images_by_url") as mock_delete_images,
    ):
        response = client.delete("/anchor-points/1")
    assert response.status_code == 200
    mock_delete_images.assert_not_called()


def test_delete_anchor_point_succeeds_even_if_storage_cleanup_fails():
    _as_caller("admin1")
    photos_table = MagicMock()
    photos_table.select.return_value.in_.return_value.execute.return_value.data = [
        {"image_url": "https://example.com/a.jpg"}
    ]
    photos_table.select.return_value.in_.return_value.order.return_value.range.return_value.execute.return_value.data = [
        {"image_url": "https://example.com/a.jpg"}
    ]
    anchor_points_table = MagicMock()
    anchor_points_table.delete.return_value.eq.return_value.execute.return_value.data = [
        {"id": "1"}
    ]
    mock_client = _mock_multi_table_client(
        {
            "anchor_point_photos": photos_table,
            "anchor_points": anchor_points_table,
            "profiles": _profiles_table(admin=True),
        }
    )
    with (
        patch("app.main.db.client", mock_client),
        patch("app.main.db.delete_images_by_url", side_effect=RuntimeError("boom")),
    ):
        response = client.delete("/anchor-points/1")
    assert response.status_code == 200
    assert response.json() == "ok"


_ANCHOR_POINT_PHOTO_ROW = {
    "id": "ph1",
    "anchor_point_id": "1",
    "image_url": "https://example.com/a.jpg",
    "heading": 90.0,
    "captured_by": "u1",
    "captured_at": "2026-01-01T00:00:00Z",
}


def test_create_anchor_point_photo_returns_created_row():
    _as_caller("admin1")
    payload = {
        "image_url": "https://example.com/a.jpg",
        "heading": 90.0,
        "captured_by": "u1",
    }
    mock_client = _mock_insert_result(
        [{**payload, "id": "ph1", "anchor_point_id": "1", "captured_by": "admin1"}]
    )
    with patch("app.main.db.client", mock_client):
        response = client.post("/anchor-points/1/photos", json=payload)
    assert response.status_code == 200


def test_create_anchor_point_photo_forces_captured_by():
    # captured_by is an audit field - the body's value must be ignored in
    # favor of the verified caller, same "don't trust a client-supplied
    # identity field" principle #111 applied to profiles.id.
    _as_caller("admin1")
    payload = {
        "image_url": "https://example.com/a.jpg",
        "heading": 90.0,
        "captured_by": "someone-else",
    }
    mock_client = _mock_insert_result([{}])
    with patch("app.main.db.client", mock_client):
        response = client.post("/anchor-points/1/photos", json=payload)
    assert response.status_code == 200
    insert_payload = mock_client.table.return_value.insert.call_args.args[0]
    assert insert_payload["captured_by"] == "admin1"


def test_create_anchor_point_photo_forbidden_for_non_admin():
    _as_caller("u1")
    payload = {
        "image_url": "https://example.com/a.jpg",
        "heading": 90.0,
        "captured_by": "u1",
    }
    with patch("app.main.db.client", _mock_select_eq_result(_USER_ROW)):
        response = client.post("/anchor-points/1/photos", json=payload)
    assert response.status_code == 403


def test_list_anchor_point_photos():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_eq_result([_ANCHOR_POINT_PHOTO_ROW])):
        response = client.get("/anchor-points/1/photos")
    assert response.status_code == 200
    assert response.json() == [_ANCHOR_POINT_PHOTO_ROW]


def test_list_all_anchor_point_photos():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_result([_ANCHOR_POINT_PHOTO_ROW])):
        response = client.get("/anchor-point-photos")
    assert response.status_code == 200
    assert response.json() == [_ANCHOR_POINT_PHOTO_ROW]


def test_delete_anchor_point_photo_returns_ok():
    _as_caller("admin1")
    photos_table = MagicMock()
    photos_table.select.return_value.eq.return_value.execute.return_value.data = [
        _ANCHOR_POINT_PHOTO_ROW
    ]
    photos_table.delete.return_value.eq.return_value.execute.return_value.data = [
        {"id": "1"}
    ]
    mock_client = _mock_multi_table_client(
        {
            "anchor_point_photos": photos_table,
            "profiles": _profiles_table(admin=True),
        }
    )
    with (
        patch("app.main.db.client", mock_client),
        patch("app.main.db.delete_images_by_url") as mock_delete_images,
    ):
        response = client.delete("/anchor-point-photos/ph1")
    assert response.status_code == 200
    assert response.json() == "ok"
    photos_table.delete.return_value.eq.assert_called_once_with("id", "ph1")
    mock_delete_images.assert_called_once_with(
        "anchor-points", ["https://example.com/a.jpg"]
    )


def test_delete_anchor_point_photo_forbidden_for_non_admin():
    _as_caller("u1")
    mock_client = _mock_multi_table_client({"profiles": _profiles_table(admin=False)})
    with patch("app.main.db.client", mock_client):
        response = client.delete("/anchor-point-photos/ph1")
    assert response.status_code == 403


_CONNECTION_ROW = {
    "id": "c1",
    "anchor_point_a_id": "a1",
    "anchor_point_b_id": "a2",
    "distance_meters": 12.5,
    "notes": None,
    "created_by": "u1",
    "created_at": "2026-01-01T00:00:00Z",
    "distance_manual": False,
}


def test_create_anchor_point_connection_forbidden_for_non_admin():
    _as_caller("u1")
    payload = {
        "anchor_point_a_id": "a1",
        "anchor_point_b_id": "a2",
        "created_by": "u1",
    }
    with patch("app.main.db.client", _mock_select_eq_result(_USER_ROW)):
        response = client.post("/anchor-point-connections", json=payload)
    assert response.status_code == 403


def test_create_anchor_point_connection_rejects_self_connection():
    _as_caller("admin1")
    payload = {
        "anchor_point_a_id": "a1",
        "anchor_point_b_id": "a1",
        "created_by": "u1",
    }
    with patch("app.main.db.client", _mock_select_eq_result(_ADMIN_ROW)):
        response = client.post("/anchor-point-connections", json=payload)
    assert response.status_code == 400


def test_create_anchor_point_connection_uses_explicit_distance():
    _as_caller("admin1")
    payload = {
        "anchor_point_a_id": "a1",
        "anchor_point_b_id": "a2",
        "distance_meters": 12.5,
        "created_by": "someone-else",
    }
    mock_client = _mock_insert_result([{**payload, "id": "c1", "notes": None}])
    with patch("app.main.db.client", mock_client):
        response = client.post("/anchor-point-connections", json=payload)
    assert response.status_code == 200
    insert_payload = mock_client.table.return_value.insert.call_args.args[0]
    assert insert_payload["distance_meters"] == 12.5


def test_create_anchor_point_connection_forces_created_by():
    _as_caller("admin1")
    payload = {
        "anchor_point_a_id": "a1",
        "anchor_point_b_id": "a2",
        "distance_meters": 12.5,
        "created_by": "someone-else",
    }
    mock_client = _mock_insert_result([{}])
    with patch("app.main.db.client", mock_client):
        response = client.post("/anchor-point-connections", json=payload)
    assert response.status_code == 200
    insert_payload = mock_client.table.return_value.insert.call_args.args[0]
    assert insert_payload["created_by"] == "admin1"


def test_create_anchor_point_connection_normalizes_id_order():
    _as_caller("admin1")
    payload = {
        "anchor_point_a_id": "zzzz",
        "anchor_point_b_id": "aaaa",
        "distance_meters": 5.0,
        "created_by": "u1",
    }
    mock_client = _mock_insert_result(
        [
            {
                **payload,
                "id": "c1",
                "anchor_point_a_id": "aaaa",
                "anchor_point_b_id": "zzzz",
                "notes": None,
            }
        ]
    )
    with patch("app.main.db.client", mock_client):
        response = client.post("/anchor-point-connections", json=payload)
    assert response.status_code == 200
    insert_payload = mock_client.table.return_value.insert.call_args.args[0]
    assert insert_payload["anchor_point_a_id"] == "aaaa"
    assert insert_payload["anchor_point_b_id"] == "zzzz"


def test_create_anchor_point_connection_computes_distance_when_omitted():
    _as_caller("admin1")
    anchor_points_table = MagicMock()
    anchor_points_table.select.return_value.in_.return_value.execute.return_value.data = [
        {"id": "a1", "latitude": 6.2442, "longitude": -75.5812},
        {"id": "a2", "latitude": 6.2445, "longitude": -75.5810},
    ]
    anchor_points_table.select.return_value.in_.return_value.order.return_value.range.return_value.execute.return_value.data = [
        {"id": "a1", "latitude": 6.2442, "longitude": -75.5812},
        {"id": "a2", "latitude": 6.2445, "longitude": -75.5810},
    ]
    connections_table = MagicMock()
    connections_table.insert.return_value.execute.return_value.data = [
        {
            "id": "c1",
            "anchor_point_a_id": "a1",
            "anchor_point_b_id": "a2",
            "distance_meters": 39.0,
            "notes": None,
            "created_by": "u1",
            "created_at": "2026-01-01T00:00:00Z",
        }
    ]
    mock_client = _mock_multi_table_client(
        {
            "anchor_points": anchor_points_table,
            "anchor_point_connections": connections_table,
            "profiles": _profiles_table(admin=True),
        }
    )

    payload = {
        "anchor_point_a_id": "a1",
        "anchor_point_b_id": "a2",
        "created_by": "u1",
    }
    with patch("app.main.db.client", mock_client):
        response = client.post("/anchor-point-connections", json=payload)

    assert response.status_code == 200
    insert_payload = connections_table.insert.call_args.args[0]
    assert insert_payload["distance_meters"] is not None
    assert insert_payload["distance_meters"] > 0


def test_list_anchor_point_connections():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_result([_CONNECTION_ROW])):
        response = client.get("/anchor-point-connections")
    assert response.status_code == 200
    assert response.json() == [_CONNECTION_ROW]


def test_list_anchor_point_connections_for_point():
    _as_caller("u1")
    mock_client = _mock_select_or_result([_CONNECTION_ROW])
    with patch("app.main.db.client", mock_client):
        response = client.get("/anchor-points/a1/connections")
    assert response.status_code == 200
    assert response.json() == [_CONNECTION_ROW]
    mock_client.table.return_value.select.return_value.or_.assert_called_once_with(
        "anchor_point_a_id.eq.a1,anchor_point_b_id.eq.a1"
    )


def test_delete_anchor_point_connection_forbidden_for_non_admin():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_eq_result(_USER_ROW)):
        response = client.delete("/anchor-point-connections/c1")
    assert response.status_code == 403


def test_delete_anchor_point_connection_returns_ok():
    _as_caller("admin1")
    mock_client = _mock_delete_eq_result()
    with patch("app.main.db.client", mock_client):
        response = client.delete("/anchor-point-connections/c1")
    assert response.status_code == 200
    assert response.json() == "ok"
    mock_client.table.return_value.delete.return_value.eq.assert_called_once_with(
        "id", "c1"
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
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_eq_result([_BUILDING_ROW])):
        response = client.get("/buildings/1")
    assert response.status_code == 200
    assert response.json()["id"] == "1"


def test_get_building_404_when_missing():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_eq_result([])):
        response = client.get("/buildings/missing")
    assert response.status_code == 404


def test_create_building_forbidden_for_non_admin():
    _as_caller("u1")
    payload = {
        "place_id": "p1",
        "code": "B2",
        "name": "Annex",
        "latitude": 6.24,
        "longitude": -75.58,
    }
    with patch("app.main.db.client", _mock_select_eq_result(_USER_ROW)):
        response = client.post("/buildings", json=payload)
    assert response.status_code == 403


def test_create_building_returns_created_row():
    _as_caller("admin1")
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
    _as_caller("admin1")
    mock_client = _mock_update_eq_result([{**_BUILDING_ROW, "name": "Renamed"}])
    with patch("app.main.db.client", mock_client):
        response = client.patch("/buildings/1", json={"name": "Renamed"})
    assert response.status_code == 200
    assert response.json() == [{**_BUILDING_ROW, "name": "Renamed"}]
    mock_client.table.return_value.update.assert_called_once_with({"name": "Renamed"})


def test_update_building_persists_latitude_and_longitude():
    _as_caller("admin1")
    payload = {"latitude": 6.25, "longitude": -75.59}
    mock_client = _mock_update_eq_result([{**_BUILDING_ROW, **payload}])
    with patch("app.main.db.client", mock_client):
        response = client.patch("/buildings/1", json=payload)
    assert response.status_code == 200
    mock_client.table.return_value.update.assert_called_once_with(payload)


def test_update_building_persists_place_id():
    _as_caller("admin1")
    payload = {"place_id": "2"}
    mock_client = _mock_update_eq_result([{**_BUILDING_ROW, **payload}])
    with patch("app.main.db.client", mock_client):
        response = client.patch("/buildings/1", json=payload)
    assert response.status_code == 200
    mock_client.table.return_value.update.assert_called_once_with(payload)


def test_delete_building_forbidden_for_non_admin():
    _as_caller("u1")
    mock_client = _mock_multi_table_client({"profiles": _profiles_table(admin=False)})
    with patch("app.main.db.client", mock_client):
        response = client.delete("/buildings/1")
    assert response.status_code == 403


def test_delete_building_returns_ok():
    _as_caller("admin1")
    anchor_points_table = MagicMock()
    anchor_points_table.select.return_value.in_.return_value.execute.return_value.data = [
        {"id": "a1"},
        {"id": "a2"},
    ]
    anchor_points_table.select.return_value.in_.return_value.order.return_value.range.return_value.execute.return_value.data = [
        {"id": "a1"},
        {"id": "a2"},
    ]
    photos_table = MagicMock()
    photos_table.select.return_value.in_.return_value.execute.return_value.data = [
        {"image_url": "https://example.com/a.jpg"}
    ]
    photos_table.select.return_value.in_.return_value.order.return_value.range.return_value.execute.return_value.data = [
        {"image_url": "https://example.com/a.jpg"}
    ]
    buildings_table = MagicMock()
    buildings_table.delete.return_value.eq.return_value.execute.return_value.data = [
        {"id": "1"}
    ]
    mock_client = _mock_multi_table_client(
        {
            "anchor_points": anchor_points_table,
            "anchor_point_photos": photos_table,
            "buildings": buildings_table,
            "profiles": _profiles_table(admin=True),
        }
    )
    with (
        patch("app.main.db.client", mock_client),
        patch("app.main.db.delete_images_by_url") as mock_delete_images,
    ):
        response = client.delete("/buildings/1")
    assert response.status_code == 200
    assert response.json() == "ok"
    anchor_points_table.select.return_value.in_.assert_called_once_with(
        "building_id", ["1"]
    )
    photos_table.select.return_value.in_.assert_called_once_with(
        "anchor_point_id", ["a1", "a2"]
    )
    buildings_table.delete.return_value.eq.assert_called_once_with("id", "1")
    mock_delete_images.assert_called_once_with(
        "anchor-points", ["https://example.com/a.jpg"]
    )


_PLACE_ROW = {
    "id": "p1",
    "code": "CAMPUS",
    "name": "Main Campus",
    "latitude": 6.24,
    "longitude": -75.58,
}


def test_create_place_forbidden_for_non_admin():
    _as_caller("u1")
    payload = {
        "code": "CAMPUS",
        "name": "Main Campus",
        "latitude": 6.24,
        "longitude": -75.58,
    }
    with patch("app.main.db.client", _mock_select_eq_result(_USER_ROW)):
        response = client.post("/places", json=payload)
    assert response.status_code == 403


def test_create_place_returns_created_row():
    _as_caller("admin1")
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
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_result([_PLACE_ROW])):
        response = client.get("/places")
    assert response.status_code == 200
    assert response.json() == [{**_PLACE_ROW, "address": None, "is_active": True}]


def test_get_place_404_when_missing():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_eq_result([])):
        response = client.get("/places/missing")
    assert response.status_code == 404


def test_update_place_returns_updated_row():
    _as_caller("admin1")
    mock_client = _mock_update_eq_result([{**_PLACE_ROW, "name": "Renamed Campus"}])
    with patch("app.main.db.client", mock_client):
        response = client.patch("/places/p1", json={"name": "Renamed Campus"})
    assert response.status_code == 200
    assert response.json() == [{**_PLACE_ROW, "name": "Renamed Campus"}]
    mock_client.table.return_value.update.assert_called_once_with(
        {"name": "Renamed Campus"}
    )


def test_update_place_persists_latitude_and_longitude():
    _as_caller("admin1")
    payload = {"latitude": 6.25, "longitude": -75.59}
    mock_client = _mock_update_eq_result([{**_PLACE_ROW, **payload}])
    with patch("app.main.db.client", mock_client):
        response = client.patch("/places/p1", json=payload)
    assert response.status_code == 200
    mock_client.table.return_value.update.assert_called_once_with(payload)


def test_delete_place_forbidden_for_non_admin():
    _as_caller("u1")
    mock_client = _mock_multi_table_client({"profiles": _profiles_table(admin=False)})
    with patch("app.main.db.client", mock_client):
        response = client.delete("/places/p1")
    assert response.status_code == 403


def test_delete_place_returns_ok():
    _as_caller("admin1")
    buildings_table = MagicMock()
    buildings_table.select.return_value.eq.return_value.execute.return_value.data = [
        {"id": "b1"}
    ]
    anchor_points_table = MagicMock()
    anchor_points_table.select.return_value.in_.return_value.execute.return_value.data = [
        {"id": "a1"}
    ]
    anchor_points_table.select.return_value.in_.return_value.order.return_value.range.return_value.execute.return_value.data = [
        {"id": "a1"}
    ]
    photos_table = MagicMock()
    photos_table.select.return_value.in_.return_value.execute.return_value.data = [
        {"image_url": "https://example.com/a.jpg"}
    ]
    photos_table.select.return_value.in_.return_value.order.return_value.range.return_value.execute.return_value.data = [
        {"image_url": "https://example.com/a.jpg"}
    ]
    places_table = MagicMock()
    places_table.delete.return_value.eq.return_value.execute.return_value.data = [
        {"id": "1"}
    ]
    mock_client = _mock_multi_table_client(
        {
            "buildings": buildings_table,
            "anchor_points": anchor_points_table,
            "anchor_point_photos": photos_table,
            "places": places_table,
            "profiles": _profiles_table(admin=True),
        }
    )
    with (
        patch("app.main.db.client", mock_client),
        patch("app.main.db.delete_images_by_url") as mock_delete_images,
    ):
        response = client.delete("/places/p1")
    assert response.status_code == 200
    assert response.json() == "ok"
    buildings_table.select.return_value.eq.assert_called_once_with("place_id", "p1")
    anchor_points_table.select.return_value.in_.assert_called_once_with(
        "building_id", ["b1"]
    )
    places_table.delete.return_value.eq.assert_called_once_with("id", "p1")
    mock_delete_images.assert_called_once_with(
        "anchor-points", ["https://example.com/a.jpg"]
    )


def test_upload_anchor_point_image_forbidden_for_non_admin():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_eq_result(_USER_ROW)):
        response = client.post(
            "/anchor-points/upload-image",
            files={"file": ("a.jpg", b"fake-bytes", "image/jpeg")},
        )
    assert response.status_code == 403


def test_upload_anchor_point_image_returns_public_url():
    _as_caller("admin1")
    with (
        patch("app.main.db.client", _mock_select_eq_result(_ADMIN_ROW)),
        patch(
            "app.main.db.upload_image",
            return_value="https://example.com/anchor-points/a.jpg",
        ) as mock,
    ):
        response = client.post(
            "/anchor-points/upload-image",
            files={"file": ("a.jpg", b"fake-bytes", "image/jpeg")},
        )
    assert response.status_code == 200
    assert response.json() == {"url": "https://example.com/anchor-points/a.jpg"}
    args = mock.call_args.args
    assert args[0] == "anchor-points"
    assert args[2] == "a.jpg"


def _mock_current_then_update(current_row, updated_rows):
    mock_client = MagicMock()
    # select().eq().execute() serves both is_admin (role_id) and the
    # current-row lookup, so return a row that satisfies both.
    mock_client.table.return_value.select.return_value.eq.return_value.execute.return_value.data = [
        {"role_id": 2, **current_row}
    ]
    mock_client.table.return_value.update.return_value.eq.return_value.execute.return_value.data = updated_rows
    return mock_client


def test_update_anchor_point_rejects_destination_type_on_unnamed_point():
    _as_caller("admin1")
    mock_client = _mock_current_then_update(
        {"location_type_id": 10, "location_description": None}, []
    )
    with patch("app.main.db.client", mock_client):
        response = client.patch("/anchor-points/1", json={"location_type_id": 7})
    assert response.status_code == 400
    mock_client.table.return_value.update.assert_not_called()


def test_update_anchor_point_rejects_clearing_a_destination_description():
    _as_caller("admin1")
    mock_client = _mock_current_then_update(
        {"location_type_id": 5, "location_description": "Room 101"}, []
    )
    with patch("app.main.db.client", mock_client):
        response = client.patch("/anchor-points/1", json={"location_description": ""})
    assert response.status_code == 400


def test_update_anchor_point_allows_clearing_an_in_between_description():
    _as_caller("admin1")
    mock_client = _mock_current_then_update(
        {"location_type_id": 10, "location_description": "Hall"},
        [{**_ANCHOR_POINT_ROW, "location_description": None}],
    )
    with patch("app.main.db.client", mock_client):
        response = client.patch("/anchor-points/1", json={"location_description": ""})
    assert response.status_code == 200
    mock_client.table.return_value.update.assert_called_once_with(
        {"location_description": None}
    )


def test_destination_types_match_the_app():
    # The app enforces the same rule client-side (and filters the user's
    # destination list with it) - the two sets must not drift apart.
    import re
    from pathlib import Path

    from app.models import DESTINATION_LOCATION_TYPE_IDS

    dart = (
        Path(__file__).resolve().parents[2]
        / "application/lib/services/destinations.dart"
    ).read_text()
    match = re.search(r"kDestinationLocationTypes = \{([^}]*)\}", dart)
    assert match
    app_ids = {int(x) for x in match.group(1).split(",") if x.strip()}
    assert app_ids == DESTINATION_LOCATION_TYPE_IDS


# --- CRUD audit fixes -------------------------------------------------------


def _anchor_patch_client(current, photos=None, connections=None, points=None):
    """profiles (admin), anchor_points (current row + update), photos and
    connections as separate tables, so each query is checked on its own."""
    anchors = MagicMock()
    anchors.select.return_value.eq.return_value.execute.return_value.data = (
        [current] if current else []
    )
    anchors.update.return_value.eq.return_value.execute.return_value.data = [
        {**(current or {}), "id": "p1"}
    ]
    anchors.select.return_value.in_.return_value.execute.return_value.data = (
        points or []
    )
    photos_table = MagicMock()
    photos_table.select.return_value.eq.return_value.limit.return_value.execute.return_value.data = (
        photos or []
    )
    connections_table = MagicMock()
    connections_table.select.return_value.or_.return_value.execute.return_value.data = (
        connections or []
    )
    return (
        _mock_multi_table_client(
            {
                "profiles": _profiles_table(admin=True),
                "anchor_points": anchors,
                "anchor_point_photos": photos_table,
                "anchor_point_connections": connections_table,
            }
        ),
        anchors,
        connections_table,
    )


_CURRENT = {
    "location_type_id": 10,
    "location_description": None,
    "latitude": 6.2,
    "longitude": -75.58,
    "status": "pending",
}


def test_update_unknown_anchor_point_is_404():
    _as_caller("admin1")
    mock_client, _, _ = _anchor_patch_client(None)
    with patch("app.main.db.client", mock_client):
        response = client.patch("/anchor-points/nope", json={"floor": 1})
    assert response.status_code == 404


def test_verify_without_photos_is_rejected():
    _as_caller("admin1")
    mock_client, anchors, _ = _anchor_patch_client(_CURRENT, photos=[])
    with patch("app.main.db.client", mock_client):
        response = client.patch("/anchor-points/p1", json={"status": "verified"})
    assert response.status_code == 400
    assert "photo" in response.json()["detail"]
    anchors.update.assert_not_called()


def test_verify_with_a_photo_is_allowed():
    _as_caller("admin1")
    mock_client, anchors, _ = _anchor_patch_client(_CURRENT, photos=[{"id": "ph"}])
    with patch("app.main.db.client", mock_client):
        response = client.patch("/anchor-points/p1", json={"status": "verified"})
    assert response.status_code == 200
    anchors.update.assert_called_once_with({"status": "verified"})


def test_invalid_status_is_rejected_before_the_database():
    _as_caller("admin1")
    mock_client, anchors, _ = _anchor_patch_client(_CURRENT)
    with patch("app.main.db.client", mock_client):
        response = client.patch("/anchor-points/p1", json={"status": "approved"})
    assert response.status_code == 422
    anchors.update.assert_not_called()


def test_out_of_range_latitude_is_rejected():
    _as_caller("admin1")
    mock_client, _, _ = _anchor_patch_client(_CURRENT)
    with patch("app.main.db.client", mock_client):
        response = client.patch("/anchor-points/p1", json={"latitude": 123})
    assert response.status_code == 422


def test_moving_a_point_recomputes_automatic_distances_only():
    _as_caller("admin1")
    connections = [
        {"id": "auto", "anchor_point_a_id": "p1", "anchor_point_b_id": "p2"},
        {
            "id": "manual",
            "anchor_point_a_id": "p1",
            "anchor_point_b_id": "p3",
            "distance_manual": True,
        },
    ]
    points = [
        {"id": "p1", "latitude": 6.2001, "longitude": -75.58},
        {"id": "p2", "latitude": 6.2, "longitude": -75.58},
    ]
    mock_client, _, connections_table = _anchor_patch_client(
        _CURRENT, connections=connections, points=points
    )
    with patch("app.main.db.client", mock_client):
        response = client.patch("/anchor-points/p1", json={"latitude": 6.2001})
    assert response.status_code == 200
    connections_table.update.assert_called_once()
    distance = connections_table.update.call_args.args[0]["distance_meters"]
    assert 10 < distance < 12  # 0.0001 deg of latitude is ~11.1 m
    connections_table.update.return_value.eq.assert_called_once_with("id", "auto")


def test_editing_without_moving_leaves_distances_alone():
    _as_caller("admin1")
    mock_client, _, connections_table = _anchor_patch_client(_CURRENT)
    with patch("app.main.db.client", mock_client):
        client.patch("/anchor-points/p1", json={"floor": 2})
    connections_table.select.assert_not_called()


def test_photo_for_missing_anchor_point_is_404():
    _as_caller("admin1")
    anchors = MagicMock()
    anchors.select.return_value.eq.return_value.execute.return_value.data = []
    photos_table = MagicMock()
    mock_client = _mock_multi_table_client(
        {
            "profiles": _profiles_table(admin=True),
            "anchor_points": anchors,
            "anchor_point_photos": photos_table,
        }
    )
    with patch("app.main.db.client", mock_client):
        response = client.post(
            "/anchor-points/gone/photos", json={"image_url": "https://x/a.jpg"}
        )
    assert response.status_code == 404
    photos_table.insert.assert_not_called()


def test_deleting_something_that_does_not_exist_is_404():
    _as_caller("admin1")
    connections_table = MagicMock()
    connections_table.delete.return_value.eq.return_value.execute.return_value.data = []
    mock_client = _mock_multi_table_client(
        {
            "profiles": _profiles_table(admin=True),
            "anchor_point_connections": connections_table,
        }
    )
    with patch("app.main.db.client", mock_client):
        response = client.delete("/anchor-point-connections/gone")
    assert response.status_code == 404


def test_a_typed_distance_is_marked_manual():
    _as_caller("admin1")
    connections_table = MagicMock()
    connections_table.insert.return_value.execute.return_value.data = [{"id": "c"}]
    mock_client = _mock_multi_table_client(
        {
            "profiles": _profiles_table(admin=True),
            "anchor_point_connections": connections_table,
        }
    )
    with patch("app.main.db.client", mock_client):
        response = client.post(
            "/anchor-point-connections",
            json={
                "anchor_point_a_id": "a",
                "anchor_point_b_id": "b",
                "distance_meters": 30,
            },
        )
    assert response.status_code == 200
    assert connections_table.insert.call_args.args[0]["distance_manual"] is True


def test_still_referenced_delete_is_a_clear_409():
    from postgrest.exceptions import APIError

    _as_caller("admin1")
    buildings_table = MagicMock()
    buildings_table.delete.return_value.eq.return_value.execute.side_effect = APIError(
        {"code": "23503", "message": "violates foreign key constraint"}
    )
    mock_client = _mock_multi_table_client(
        {
            "profiles": _profiles_table(admin=True),
            "buildings": buildings_table,
            "anchor_points": MagicMock(),
        }
    )
    with patch("app.main.db.client", mock_client):
        response = TestClient(app, raise_server_exceptions=False).delete(
            "/buildings/b1"
        )
    assert response.status_code == 409
    assert "still used" in response.json()["detail"]


def test_orphaned_upload_can_be_cleaned_up():
    _as_caller("admin1")
    photos_table = MagicMock()
    photos_table.select.return_value.eq.return_value.limit.return_value.execute.return_value.data = []
    mock_client = _mock_multi_table_client(
        {"profiles": _profiles_table(admin=True), "anchor_point_photos": photos_table}
    )
    with (
        patch("app.main.db.client", mock_client),
        patch("app.main.db.delete_images_by_url") as delete_images,
    ):
        response = client.delete(
            "/anchor-points/upload-image", params={"url": "https://x/a.jpg"}
        )
    assert response.status_code == 200
    delete_images.assert_called_once_with("anchor-points", ["https://x/a.jpg"])


def test_upload_still_used_by_a_photo_is_kept():
    _as_caller("admin1")
    photos_table = MagicMock()
    photos_table.select.return_value.eq.return_value.limit.return_value.execute.return_value.data = [
        {"id": "ph"}
    ]
    mock_client = _mock_multi_table_client(
        {"profiles": _profiles_table(admin=True), "anchor_point_photos": photos_table}
    )
    with (
        patch("app.main.db.client", mock_client),
        patch("app.main.db.delete_images_by_url") as delete_images,
    ):
        response = client.delete(
            "/anchor-points/upload-image", params={"url": "https://x/a.jpg"}
        )
    assert response.status_code == 409
    delete_images.assert_not_called()


def test_list_places_includes_is_active():
    _as_caller("u1")
    row = {
        "id": "p1",
        "code": "U",
        "name": "Uni",
        "latitude": 6.2,
        "longitude": -75.5,
        "is_active": False,
    }
    with patch("app.main.db.client", _mock_select_result([row])):
        response = client.get("/places")
    assert response.json()[0]["is_active"] is False


def test_connections_for_a_malformed_id_are_404_not_a_filter():
    app.dependency_overrides[get_caller_id] = lambda: "u1"
    try:
        response = client.get("/anchor-points/x),id.neq.0/connections")
    finally:
        app.dependency_overrides.clear()
    assert response.status_code == 404
