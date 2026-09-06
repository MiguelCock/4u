# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

See the repo root `CLAUDE.md` for overall project context. This service manages user information and configuration: profile data and preferences (`profiles` table) plus the static `roles` reference table.

## Commands

```bash
uv sync
uv run fastapi dev
uv run pytest
docker build -t backend-user-management .
docker run -p 8000:80 backend-user-management
```

## Structure

- `app/main.py` — FastAPI app; instantiates `packages.supabase.SupaBase` at import time. Exposes `GET /`, `POST/GET /profiles`, `GET /profiles/{id}`, `PATCH /profiles/{id}`, `DELETE /profiles/{id}`, `GET /roles`, `GET /roles/{id}`, all via `db.client.table(...)` directly (no `profiles`/`roles`-specific wrapper in `packages` yet).
- `app/models.py` — pydantic schemas mirroring `db_schema/profiles.sql` and `db_schema/roles.sql`: `ProfileCreate`/`ProfileUpdate`/`ProfileResponse`, `RoleResponse`.
- `tests/conftest.py` sets dummy `SUPABASE_URL`/`SUPABASE_PUBLISHABLE_KEY` before import so `pytest` doesn't need real credentials — only `GET /` is currently safe to test without hitting Supabase for real.
- Currently CRUD-stub level only — no admin-role auth check or real Supabase Auth integration.

## Known issue

`db_schema/profiles.sql` sets `id UUID PRIMARY KEY DEFAULT auth.uid()`, which only resolves inside an authenticated Supabase Auth request context. This service talks to Supabase with the publishable key, so that default won't populate correctly — `ProfileCreate.id` is a required field the caller must set explicitly (the Supabase Auth user id) instead. Fix this once the service has real per-request auth.
