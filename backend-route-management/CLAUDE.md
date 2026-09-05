# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

See the repo root `CLAUDE.md` for overall project context. This service creates and manages user-facing navigation routes.

## Commands

```bash
uv sync
uv run fastapi dev
uv run pytest
docker build -t backend-route-management .
docker run -p 8000:80 backend-route-management
```

## Structure

- `app/main.py` — FastAPI app; instantiates `packages.supabase.SupaBase` at import time. Exposes `GET /`, `POST/GET /routes`, `GET /routes/{id}`, `DELETE /routes/{id}`, all via `db.client.table("routes")` directly (no `routes`-specific wrapper in `packages` yet).
- `app/models.py` — `RouteCreate`/`RouteResponse` pydantic schemas (`building_id`, `name`, `start_anchor_id`, `end_anchor_id`, `waypoint_anchor_ids`) — these are a reasonable guess at the shape, not derived from `db_schema/routes.sql`.
- `tests/conftest.py` sets dummy `SUPABASE_URL`/`SUPABASE_PUBLISHABLE_KEY` before import so `pytest` doesn't need real credentials — only `GET /` is currently safe to test without hitting Supabase for real.

## Known issue

`db_schema/routes.sql` currently contains a copy-paste of `anchor_points.sql`, not an actual `routes` table definition. Fix that schema file (and reconcile it with `app/models.py` here) before wiring this service to a real database.
