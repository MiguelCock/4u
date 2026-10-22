"""Shared handling for database errors and for lists longer than one page.

Without this, every Postgres error raised through supabase-py (a foreign
key, a duplicate, a CHECK constraint, a malformed id) reached FastAPI as an
unhandled `postgrest.exceptions.APIError` and became a plain 500. The app
then said "the server had a problem, try again", although retrying could
never work.
"""

import logging
from collections.abc import Callable
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from postgrest.exceptions import APIError

logger = logging.getLogger(__name__)

# Supabase's PostgREST returns at most this many rows per request
# (the project's "Max rows" setting, 1000 by default).
PAGE_SIZE = 1000


def _response_for(error: APIError, method: str) -> tuple[int, str] | None:
    code = error.code
    if code == "23503":  # foreign_key_violation
        if method == "DELETE":
            return 409, (
                "This is still used by other data, so it can't be deleted yet."
            )
        return 400, "This refers to something that doesn't exist anymore."
    if code == "23505":  # unique_violation
        return 409, "That already exists."
    if code == "23514":  # check_violation
        return 400, "One of the values isn't allowed."
    if code == "22P02":  # invalid_text_representation, e.g. a malformed UUID
        return 404, "Not found."
    return None


def install_db_error_handlers(app: FastAPI) -> None:
    """Turns known Postgres errors into readable 4xx responses whose
    `detail` the app shows as-is. Anything else stays a logged 500."""

    @app.exception_handler(APIError)
    async def _handle_api_error(request: Request, error: APIError) -> JSONResponse:
        mapped = _response_for(error, request.method)
        if mapped is None:
            logger.error("Unhandled database error %s: %s", error.code, error.message)
            return JSONResponse(status_code=500, content={"detail": "Database error."})
        status, detail = mapped
        logger.info(
            "Database error %s on %s %s mapped to %s: %s",
            error.code,
            request.method,
            request.url.path,
            status,
            error.message,
        )
        return JSONResponse(status_code=status, content={"detail": detail})


def select_all(make_query: Callable[[], Any], page_size: int = PAGE_SIZE) -> list[dict]:
    """Every row of a query, paging past PostgREST's per-request cap.

    [make_query] builds a fresh query each call, e.g.
    `lambda: db.client.table("x").select("*").order("id")`. A builder can't
    be reused for several `.range()` calls. Order by a unique column so
    pages don't overlap or skip rows.
    """
    rows: list[dict] = []
    start = 0
    while True:
        page = make_query().range(start, start + page_size - 1).execute().data
        rows.extend(page)
        if len(page) < page_size:
            return rows
        start += page_size
