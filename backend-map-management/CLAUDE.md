# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

See the repo root `CLAUDE.md` for overall project context. This is the admin-view service: creating/listing anchor points and reading building/map info.

## Commands

```bash
uv sync
uv run fastapi dev
uv run pytest
docker build -t backend-map-management .
docker run -p 8000:80 backend-map-management
```

## Structure

- `app/main.py` — FastAPI app; instantiates `packages.supabase.SupaBase` at import time. Exposes `GET /`, `POST/GET /anchor-points`, `GET /anchor-points/{id}`, `GET /buildings`, `GET /buildings/{id}`.
- `app/models.py` — pydantic schemas mirroring `db_schema/anchor_points.sql` and `db_schema/buildings.sql` (as plain `str` ids rather than typed UUIDs, matching the rest of the codebase's minimal-typing style).
- `SupaBase` (in `packages`) doesn't wrap `anchor_points`/`buildings` table access, so endpoints call `db.client.table(...)` directly. If this pattern starts repeating across services, promote it into `SupaBase` instead of duplicating per-service.
- `tests/conftest.py` sets dummy `SUPABASE_URL`/`SUPABASE_PUBLISHABLE_KEY` before import so `pytest` doesn't need real credentials — only `GET /` is currently safe to test without hitting Supabase for real.
- Currently CRUD-stub level only — no anchor point verification workflow, admin auth/role check, or map-tile serving implemented yet.
