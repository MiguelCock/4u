from unittest.mock import MagicMock

from fastapi import FastAPI
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from packages.db_errors import install_db_error_handlers, select_all


def _app_raising(code: str) -> TestClient:
    app = FastAPI()
    install_db_error_handlers(app)

    def boom():
        raise APIError({"code": code, "message": "db said no"})

    app.delete("/thing")(boom)
    app.post("/thing")(boom)
    return TestClient(app, raise_server_exceptions=False)


def test_fk_violation_on_delete_is_a_409():
    response = _app_raising("23503").delete("/thing")
    assert response.status_code == 409
    assert "still used" in response.json()["detail"]


def test_fk_violation_on_write_is_a_400():
    response = _app_raising("23503").post("/thing")
    assert response.status_code == 400


def test_duplicate_is_a_409():
    assert _app_raising("23505").post("/thing").status_code == 409


def test_check_violation_is_a_400():
    assert _app_raising("23514").post("/thing").status_code == 400


def test_malformed_id_is_a_404():
    assert _app_raising("22P02").delete("/thing").status_code == 404


def test_unknown_error_stays_a_500():
    response = _app_raising("XX000").post("/thing")
    assert response.status_code == 500
    assert response.json() == {"detail": "Database error."}


def _paged_query(total: int):
    calls = []

    def make_query():
        query = MagicMock()

        def ranged(start, end):
            calls.append((start, end))
            result = MagicMock()
            result.execute.return_value.data = [
                {"id": i} for i in range(start, min(end + 1, total))
            ]
            return result

        query.range.side_effect = ranged
        return query

    return make_query, calls


def test_select_all_pages_past_the_row_cap():
    make_query, calls = _paged_query(2500)
    rows = select_all(make_query, page_size=1000)
    assert len(rows) == 2500
    assert calls == [(0, 999), (1000, 1999), (2000, 2999)]


def test_select_all_single_short_page():
    make_query, calls = _paged_query(3)
    assert len(select_all(make_query, page_size=1000)) == 3
    assert calls == [(0, 999)]
