# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

See the repo root `CLAUDE.md` for overall project context.

## Commands

```bash
uv sync
uv run fastapi dev
uv run pytest
docker build -t backend-user-management .
docker run -p 8000:80 backend-user-management
```

## What this service does

Manages user information and configuration: profile data and preferences (`profiles` table) plus the static `roles` reference table (`user`/`admin`, seeded in `db_schema/roles.sql`). Same CRUD-stub shape as the other services — `app/main.py` talks straight to Supabase via `db.client.table(...)`, no admin-role auth check, no real Supabase Auth integration.

## How it connects to the rest of the system

No service-to-service HTTP calls — but `profiles` is the single most depended-upon table in the whole schema, via foreign keys owned by other services:

- `anchor_points.captured_by` (`backend-map-management`) → `profiles(id)`, `NOT NULL`. As noted in `backend-map-management/CLAUDE.md`, that service's create model currently omits this field entirely, so it can't actually satisfy this FK yet.
- `navigation_sessions.user_id` and `user_feedback.user_id` (`backend-navigation-management`) → `profiles(id)`.
- `profiles.place_id` → the unmanaged `places` table (same gap noted in `backend-map-management/CLAUDE.md` — no service creates `places` rows).
- `profiles.role_id` → this service's own `roles` table.

So although this was one of the later services scaffolded, almost every other service's "who did this" column ultimately points here.

## Complete workflow

1. **Intended signup flow** — Supabase Auth creates a row in its own `auth.users` table when someone signs up; something (a Postgres trigger/function, or the app calling this API right after signup) is then supposed to call `POST /profiles` to create the matching `profiles` row with that same `id`. **Nothing triggers this today** — the app has no signup/login screen at all (see `application/CLAUDE.md`), and there's no DB trigger defined in `db_schema/`.
2. **`POST /profiles`** — as written, requires the caller to pass `id` explicitly (see Known issue below for why), plus optional `place_id`/`role_id`/`full_name`/`avatar_url`/`phone`/`preferences`/`is_active` → inserted as-is.
3. **`GET /profiles`** / **`GET /profiles/{id}`** — plain `select("*")` (optionally `.eq("id", id)`).
4. **`PATCH /profiles/{id}`** — partial update via `ProfileUpdate` (`model_dump(exclude_unset=True)`), the mechanism for changing "configuration" (e.g. `preferences.verbosity`/`feedback_type`) after the profile exists.
5. **`DELETE /profiles/{id}`** — deletes the row; nothing here checks whether `anchor_points.captured_by`/`navigation_sessions.user_id`/`user_feedback.user_id` reference this profile first (a real FK constraint would reject the delete or cascade, depending on how each table's `ON DELETE` is defined — `db_schema/anchor_points.sql` uses `ON DELETE CASCADE` on `building_id` but no explicit action on `captured_by`).
6. **`GET /roles`** / **`GET /roles/{id}`** — read-only access to the static `roles` reference table; nothing creates or modifies roles through this API (by design — it's seeded data).

## Known issue

`db_schema/profiles.sql` sets `id UUID PRIMARY KEY DEFAULT auth.uid()`, which only resolves inside an authenticated Supabase Auth request context. This service talks to Supabase with the publishable key, so that default won't populate correctly — `ProfileCreate.id` is a required field the caller must set explicitly (the Supabase Auth user id) instead. Fix this once the service has real per-request auth.
