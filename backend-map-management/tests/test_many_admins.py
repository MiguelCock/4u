"""Many admins editing at once (A5): a save that would overwrite another admin's
change is refused with 409, and GET /changes returns only what changed."""

from datetime import UTC, datetime, timedelta
from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient

from app.main import app, get_caller_id

client = TestClient(app)

POINT = {
    "id": "p1",
    "building_id": None,
    "floor": 0,
    "location_type_id": 3,
    "location_description": "Front door",
    "latitude": 6.24,
    "longitude": -75.58,
    "status": "pending",
    "metadata": {"indoor": True},
}


class FakeTable:
    """Records the filters of one update, and applies them like PostgREST."""

    def __init__(self, row):
        self.row = row
        self.updates = []
        self._filters = []
        self._pending = None

    def select(self, *_args, **_kwargs):
        self._pending = None
        self._filters = []
        return self

    def update(self, changes):
        self._pending = changes
        self._filters = []
        return self

    def eq(self, field, value):
        self._filters.append((field, value))
        return self

    def is_(self, field, _null):
        self._filters.append((field, None))
        return self

    def execute(self):
        matches = self.row is not None and all(
            self.row.get(f) == v for f, v in self._filters if f != "id"
        )
        if self._pending is None:
            return MagicMock(data=[dict(self.row)] if self.row else [])
        if not matches:
            return MagicMock(data=[])
        self.updates.append(self._pending)
        self.row = {**self.row, **self._pending}
        return MagicMock(data=[dict(self.row)])


def _client_with(point_table):
    profiles = MagicMock()
    profiles.select.return_value.eq.return_value.execute.return_value.data = [
        {"role_id": 2, "is_active": True}
    ]
    other = MagicMock()
    other.select.return_value.eq.return_value.execute.return_value.data = []
    other.select.return_value.eq.return_value.limit.return_value.execute.return_value.data = [
        {"id": "photo"}
    ]
    tables = {"profiles": profiles, "anchor_points": point_table}
    db_client = MagicMock()
    db_client.table.side_effect = lambda name: tables.get(name, other)
    return db_client


def _patch(body, row=POINT):
    app.dependency_overrides[get_caller_id] = lambda: "admin1"
    table = FakeTable(dict(row))
    try:
        with patch("app.main.db.client", _client_with(table)):
            return client.patch("/anchor-points/p1", json=body), table
    finally:
        app.dependency_overrides.clear()


def test_a_save_applies_when_nothing_changed_meanwhile():
    response, table = _patch(
        {
            "location_description": "Main door",
            "expected": {"location_description": "Front door"},
        }
    )
    assert response.status_code == 200
    assert table.updates == [{"location_description": "Main door"}]


def test_a_save_over_another_admins_change_is_refused():
    # Another admin renamed it to "Front door" after this admin saw "Old door".
    response, table = _patch(
        {
            "location_description": "Main door",
            "expected": {"location_description": "Old door"},
        }
    )
    assert response.status_code == 409
    detail = response.json()["detail"]
    assert detail["fields"] == ["location_description"]
    assert detail["current"]["location_description"] == "Front door"
    assert table.updates == []


def test_an_unrelated_change_meanwhile_doesnt_block_the_save():
    # Expected only for the field being changed; the description changed meanwhile.
    response, table = _patch(
        {
            "latitude": 6.2401,
            "longitude": -75.5801,
            "expected": {"latitude": 6.24, "longitude": -75.58},
        },
        row={**POINT, "location_description": "Renamed by someone else"},
    )
    assert response.status_code == 200
    assert table.updates == [{"latitude": 6.2401, "longitude": -75.5801}]


def test_without_expected_it_saves_as_before():
    response, table = _patch({"location_description": "Main door"})
    assert response.status_code == 200
    assert table.updates == [{"location_description": "Main door"}]


def test_verifying_a_point_already_verified_by_someone_else_is_a_conflict():
    response, table = _patch(
        {"status": "verified", "expected": {"status": "pending"}},
        row={**POINT, "status": "verified"},
    )
    assert response.status_code == 409
    assert response.json()["detail"]["fields"] == ["status"]
    assert table.updates == []


def test_metadata_is_checked_too():
    response, table = _patch(
        {"metadata": {"indoor": False}, "expected": {"metadata": {"indoor": False}}}
    )
    assert response.status_code == 409
    assert table.updates == []


def test_expected_values_for_fields_not_being_changed_are_ignored():
    response, _ = _patch(
        {"floor": 1, "expected": {"floor": 0, "location_description": "Something else"}}
    )
    assert response.status_code == 200


# --- GET /changes ---------------------------------------------------------


def _changes(since, rows_by_table=None, deletions=()):
    rows_by_table = rows_by_table or {}
    queried = {}

    def table(name):
        mock = MagicMock()
        if name == "profiles":
            mock.select.return_value.eq.return_value.execute.return_value.data = [
                {"role_id": 2, "is_active": True}
            ]
            return mock
        query = mock.select.return_value.gte.return_value.order.return_value
        data = (
            list(deletions) if name == "map_deletions" else rows_by_table.get(name, [])
        )
        query.range.return_value.execute.return_value.data = data
        queried[name] = mock
        return mock

    db_client = MagicMock()
    db_client.table.side_effect = table
    app.dependency_overrides[get_caller_id] = lambda: "admin1"
    try:
        with patch("app.main.db.client", db_client):
            return client.get("/changes", params={"since": since}), queried
    finally:
        app.dependency_overrides.clear()


def test_changes_returns_updated_rows_and_deletions():
    since = (datetime.now(UTC) - timedelta(minutes=2)).isoformat()
    response, queried = _changes(
        since,
        {"anchor_points": [{"id": "p1"}], "anchor_point_photos": [{"id": "ph1"}]},
        [
            {"table_name": "anchor_points", "row_id": "p2"},
            {"table_name": "buildings", "row_id": "b1"},
        ],
    )
    assert response.status_code == 200
    body = response.json()
    assert body["full"] is False
    assert body["anchor_points"] == [{"id": "p1"}]
    assert body["anchor_point_photos"] == [{"id": "ph1"}]
    assert body["deleted"]["anchor_points"] == ["p2"]
    assert body["deleted"]["buildings"] == ["b1"]
    assert datetime.fromisoformat(body["next_since"]) < datetime.now(UTC)
    # Old deletion entries are cleaned up.
    queried["map_deletions"].delete.return_value.lt.assert_called_once()


def test_changes_from_too_long_ago_asks_for_a_full_load():
    since = (datetime.now(UTC) - timedelta(hours=2)).isoformat()
    response, queried = _changes(since)
    assert response.status_code == 200
    assert response.json()["full"] is True
    assert queried == {}


def test_changes_are_for_admins_only():
    profiles = MagicMock()
    profiles.select.return_value.eq.return_value.execute.return_value.data = [
        {"role_id": 1, "is_active": True}
    ]
    db_client = MagicMock()
    db_client.table.return_value = profiles
    app.dependency_overrides[get_caller_id] = lambda: "user1"
    try:
        with patch("app.main.db.client", db_client):
            response = client.get(
                "/changes", params={"since": datetime.now(UTC).isoformat()}
            )
    finally:
        app.dependency_overrides.clear()
    assert response.status_code == 403
