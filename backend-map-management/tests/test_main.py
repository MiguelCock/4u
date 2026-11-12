import inspect
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


def _points(*ids, step=0.00005, floor=0, type_id=10):
    """Anchor points about 5.5 m apart (step degrees of latitude) on one floor."""
    return [
        {
            "id": point_id,
            "latitude": 6.2 + i * step,
            "longitude": -75.58,
            "floor": floor,
            "location_type_id": type_id,
            "location_description": None,
        }
        for i, point_id in enumerate(ids)
    ]


def _with_points(mock_client, points):
    """Lets a single-table mock answer the connection endpoint's point lookup."""
    mock_client.table.return_value.select.return_value.in_.return_value.execute.return_value.data = points
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
    # A point's description is its name to admins (C9).
    assert "name" in response.json()["detail"]
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
    "updated_at": "2026-11-07T20:00:00+00:00",
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
    "updated_at": "2026-11-07T20:00:00+00:00",
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
    _with_points(mock_client, _points("a1", "a2"))
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
    _with_points(mock_client, _points("a1", "a2"))
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
    _with_points(mock_client, _points("aaaa", "zzzz"))
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
        {"id": "a2", "latitude": 6.2443, "longitude": -75.5811},
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


_NOTED_CONNECTION = {
    "id": "c1",
    "anchor_point_a_id": "a",
    "anchor_point_b_id": "b",
    "distance_meters": 6.0,
    "notes": "Tres escalones hacia abajo",
    "created_at": "2026-11-03T00:00:00Z",
}


def test_update_connection_notes():
    _as_caller("admin1")
    mock_client = _mock_update_eq_result([_NOTED_CONNECTION])
    with patch("app.main.db.client", mock_client):
        response = client.patch(
            "/anchor-point-connections/c1",
            json={"notes": "  Tres escalones hacia abajo "},
        )
    assert response.status_code == 200
    assert response.json()["notes"] == "Tres escalones hacia abajo"
    mock_client.table.return_value.update.assert_called_once_with(
        {"notes": "Tres escalones hacia abajo"}
    )


def test_blank_connection_notes_are_cleared():
    _as_caller("admin1")
    mock_client = _mock_update_eq_result([{**_NOTED_CONNECTION, "notes": None}])
    with patch("app.main.db.client", mock_client):
        client.patch("/anchor-point-connections/c1", json={"notes": "  "})
    mock_client.table.return_value.update.assert_called_once_with({"notes": None})


def test_update_connection_notes_forbidden_for_non_admin():
    _as_caller("u1")
    with patch("app.main.db.client", _mock_select_eq_result(_USER_ROW)):
        response = client.patch("/anchor-point-connections/c1", json={"notes": "x"})
    assert response.status_code == 403


def test_update_unknown_connection_is_404():
    _as_caller("admin1")
    with patch("app.main.db.client", _mock_update_eq_result([])):
        response = client.patch("/anchor-point-connections/gone", json={"notes": "x"})
    assert response.status_code == 404


_BUILDING_ROW = {
    "updated_at": "2026-11-07T20:00:00+00:00",
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


def _building_client(taken_codes):
    """A client whose buildings table has [taken_codes] in the university
    and records what's inserted."""
    client_mock = MagicMock()
    table = client_mock.table.return_value
    table.select.return_value.eq.return_value.execute.return_value.data = [
        {"code": code} for code in taken_codes
    ]
    table.insert.return_value.execute.return_value.data = [{"id": "2"}]
    return client_mock


def _admin():
    """The caller is an admin, without the profile lookup sharing the mock."""
    return patch("app.main.db.is_admin", return_value=True)


def _inserted(client_mock) -> dict:
    return client_mock.table.return_value.insert.call_args.args[0]


def test_create_building_without_a_code_uses_its_name():
    _as_caller("admin1")
    payload = {
        "place_id": "p1",
        "name": "Bloque  20",
        "latitude": 6.24,
        "longitude": -75.58,
    }
    mock_client = _building_client([])
    with patch("app.main.db.client", mock_client), _admin():
        response = client.post("/buildings", json=payload)
    assert response.status_code == 200
    assert _inserted(mock_client)["code"] == "BLOQUE 20"


def test_create_building_code_from_name_skips_a_taken_one():
    _as_caller("admin1")
    payload = {
        "place_id": "p1",
        "name": "Biblioteca",
        "latitude": 6.24,
        "longitude": -75.58,
    }
    mock_client = _building_client(["BIBLIOTECA", "BIBLIOTECA 2"])
    with patch("app.main.db.client", mock_client), _admin():
        client.post("/buildings", json=payload)
    assert _inserted(mock_client)["code"] == "BIBLIOTECA 3"


def test_create_building_keeps_a_code_an_older_app_sends():
    _as_caller("admin1")
    payload = {
        "place_id": "p1",
        "code": "B2",
        "name": "Annex",
        "address": "Calle 1",
        "latitude": 6.24,
        "longitude": -75.58,
    }
    mock_client = _building_client(["B1"])
    with patch("app.main.db.client", mock_client), _admin():
        response = client.post("/buildings", json=payload)
    assert response.status_code == 200
    assert _inserted(mock_client)["code"] == "B2"
    assert _inserted(mock_client)["address"] == "Calle 1"


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
    "updated_at": "2026-11-07T20:00:00+00:00",
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
    connections_table.update.assert_not_called()


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
    anchors = MagicMock()
    anchors.select.return_value.in_.return_value.execute.return_value.data = _points(
        "a", "b"
    )
    mock_client = _mock_multi_table_client(
        {
            "profiles": _profiles_table(admin=True),
            "anchor_point_connections": connections_table,
            "anchor_points": anchors,
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


# --- guardrails (Icesi data, 2026-11-03) --------------------------------


def _connection_client(points):
    connections_table = MagicMock()
    connections_table.insert.return_value.execute.return_value.data = [{"id": "c"}]
    anchors = MagicMock()
    anchors.select.return_value.in_.return_value.execute.return_value.data = points
    client_mock = _mock_multi_table_client(
        {
            "profiles": _profiles_table(admin=True),
            "anchor_point_connections": connections_table,
            "anchor_points": anchors,
        }
    )
    return client_mock, connections_table


def _connect(points, **extra):
    mock_client, connections_table = _connection_client(points)
    with patch("app.main.db.client", mock_client):
        response = client.post(
            "/anchor-point-connections",
            json={"anchor_point_a_id": "a", "anchor_point_b_id": "b", **extra},
        )
    return response, connections_table


def test_connection_at_the_limit_is_allowed():
    _as_caller("admin1")
    # 0.00026 deg of latitude is about 28.9 m.
    response, connections_table = _connect(_points("a", "b", step=0.00026))
    assert response.status_code == 200
    connections_table.insert.assert_called_once()


def test_connection_over_30_m_is_refused():
    _as_caller("admin1")
    # 0.00045 deg is about 50 m, like the cross-building ones at Icesi.
    response, connections_table = _connect(_points("a", "b", step=0.00045))
    assert response.status_code == 400
    assert "50 m apart" in response.json()["detail"]
    connections_table.insert.assert_not_called()


def test_long_connection_is_refused_even_with_a_typed_distance():
    _as_caller("admin1")
    response, connections_table = _connect(
        _points("a", "b", step=0.00045), distance_meters=10
    )
    assert response.status_code == 400
    connections_table.insert.assert_not_called()


def test_typed_distance_shorter_than_the_straight_line_is_refused():
    _as_caller("admin1")
    response, _ = _connect(_points("a", "b", step=0.0001), distance_meters=3)
    assert response.status_code == 400
    assert "straight line" in response.json()["detail"]


def test_typed_distance_longer_than_the_straight_line_is_kept():
    _as_caller("admin1")
    response, connections_table = _connect(
        _points("a", "b", step=0.0001), distance_meters=25
    )
    assert response.status_code == 200
    assert connections_table.insert.call_args.args[0]["distance_meters"] == 25


def test_floor_change_between_hallways_is_refused():
    _as_caller("admin1")
    a, b = _points("a", "b")
    response, connections_table = _connect([a, {**b, "floor": 1}])
    assert response.status_code == 400
    assert "different floors" in response.json()["detail"]
    connections_table.insert.assert_not_called()


def test_floor_change_through_stairs_is_allowed():
    _as_caller("admin1")
    a, b = _points("a", "b")
    response, _ = _connect([a, {**b, "floor": 1, "location_type_id": 4}])
    assert response.status_code == 200


def _create_client(neighbours, building=None):
    anchors = MagicMock()
    anchors.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = neighbours
    anchors.insert.return_value.execute.return_value.data = [{"id": "new"}]
    buildings = MagicMock()
    buildings.select.return_value.eq.return_value.execute.return_value.data = (
        [building] if building else []
    )
    mock_client = _mock_multi_table_client(
        {
            "profiles": _profiles_table(admin=True),
            "anchor_points": anchors,
            "buildings": buildings,
        }
    )
    return mock_client, anchors


_NEW_POINT = {"building_id": "b1", "latitude": 6.2, "longitude": -75.58}


def test_point_on_top_of_another_is_refused():
    _as_caller("admin1")
    existing = {**_points("old")[0], "location_description": "Baño mujeres"}
    mock_client, anchors = _create_client([existing])
    with patch("app.main.db.client", mock_client):
        response = client.post("/anchor-points", json=_NEW_POINT)
    assert response.status_code == 409
    assert "Baño mujeres" in response.json()["detail"]
    anchors.insert.assert_not_called()


def test_point_on_top_of_another_is_saved_when_confirmed():
    _as_caller("admin1")
    mock_client, anchors = _create_client(_points("old"))
    with patch("app.main.db.client", mock_client):
        response = client.post(
            "/anchor-points", json={**_NEW_POINT, "allow_nearby": True}
        )
    assert response.status_code == 200
    assert "allow_nearby" not in anchors.insert.call_args.args[0]


def test_point_a_few_meters_away_is_saved():
    _as_caller("admin1")
    mock_client, anchors = _create_client(_points("x", "old")[1:])  # ~5.5 m
    with patch("app.main.db.client", mock_client):
        response = client.post("/anchor-points", json=_NEW_POINT)
    assert response.status_code == 200
    anchors.insert.assert_called_once()


def test_point_far_from_its_building_is_refused():
    _as_caller("admin1")
    mock_client, anchors = _create_client(
        [],
        building={"latitude": 6.21, "longitude": -75.58},  # ~1.1 km
    )
    with patch("app.main.db.client", mock_client):
        response = client.post("/anchor-points", json=_NEW_POINT)
    assert response.status_code == 400
    assert "from its building" in response.json()["detail"]
    anchors.insert.assert_not_called()


def test_moving_a_point_too_far_from_a_connected_one_is_refused():
    _as_caller("admin1")
    current = {**_CURRENT, "id": "p1", "floor": 0}
    connections = [{"id": "c", "anchor_point_a_id": "p1", "anchor_point_b_id": "p2"}]
    p2 = {**_points("p2")[0], "latitude": 6.2}
    mock_client, anchors, _ = _anchor_patch_client(
        current, connections=connections, points=[p2]
    )
    with patch("app.main.db.client", mock_client):
        response = client.patch("/anchor-points/p1", json={"latitude": 6.2005})
    assert response.status_code == 400
    assert "apart" in response.json()["detail"]
    anchors.update.assert_not_called()


def _named_building_client(point_row=None):
    """Bloque 20 at EAFIT, for the name a point is saved with."""
    tables = {
        name: MagicMock()
        for name in ("anchor_points", "buildings", "places", "profiles")
    }
    tables[
        "profiles"
    ].select.return_value.eq.return_value.execute.return_value.data = _ADMIN_ROW
    tables[
        "buildings"
    ].select.return_value.eq.return_value.execute.return_value.data = [
        {"name": "Bloque 20", "place_id": "p1", "latitude": 6.24, "longitude": -75.58}
    ]
    tables["places"].select.return_value.eq.return_value.execute.return_value.data = [
        {"name": "EAFIT"}
    ]
    points = tables["anchor_points"]
    points.select.return_value.eq.return_value.execute.return_value.data = (
        [point_row] if point_row else []
    )
    points.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = []
    points.insert.return_value.execute.return_value.data = [{"id": "1"}]
    points.update.return_value.eq.return_value.execute.return_value.data = [{"id": "1"}]
    mock_client = MagicMock()
    mock_client.table.side_effect = lambda name: tables[name]
    return mock_client, points


def test_new_point_is_saved_without_its_building_name():
    _as_caller("admin1")
    mock_client, points = _named_building_client()
    with patch("app.main.db.client", mock_client):
        response = client.post(
            "/anchor-points",
            json={
                "building_id": "b1",
                "latitude": 6.24,
                "longitude": -75.58,
                "location_description": "Entrada sur bloque 20",
                "allow_nearby": True,
            },
        )
    assert response.status_code == 200
    assert points.insert.call_args.args[0]["location_description"] == "Entrada sur"


def test_renamed_point_is_saved_without_its_building_name():
    _as_caller("admin1")
    mock_client, points = _named_building_client(
        {"id": "1", "building_id": "b1", "location_description": "Entrada"}
    )
    with patch("app.main.db.client", mock_client):
        response = client.patch(
            "/anchor-points/1",
            json={"location_description": "Entrada norte bloque 20"},
        )
    assert response.status_code == 200
    assert points.update.call_args.args[0]["location_description"] == "Entrada norte"


def test_endpoints_that_block_dont_hold_up_the_others():
    """A blocking Supabase call in an async endpoint stops the event loop, so
    requests queued one at a time: 3.8 s for a simple read during a trip."""
    from fastapi.routing import APIRoute

    slow = [
        route.path
        for route in app.routes
        if isinstance(route, APIRoute)
        and inspect.iscoroutinefunction(route.endpoint)
        and route.path != "/"
    ]
    assert slow == []
