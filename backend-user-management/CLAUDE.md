# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

See the repo root `CLAUDE.md` for overall project context.

## Commands

```bash
uv sync
uv run fastapi dev
uv run pytest
# Docker build context must be the repo root (Dockerfile also copies sibling packages/):
(cd .. && docker build -f backend-user-management/Dockerfile -t backend-user-management .)
docker run -p 8000:80 --env-file .env backend-user-management
```

## What this service does

Manages user information and configuration: profile data and preferences (`profiles` table) plus the static `roles` reference table (`user`/`admin`, seeded in `db_schema/roles.sql`). Unlike the other 5 services, `/profiles` endpoints are no longer unauthenticated CRUD stubs — see **Authorization** below for the real guard pattern now in place. `/roles` is still a plain, unauthenticated read (static reference data, nothing sensitive).

## How it connects to the rest of the system

No service-to-service HTTP calls — but `profiles` is the single most depended-upon table in the whole schema, via foreign keys owned by other services:

- `anchor_points.captured_by` (`backend-map-management`) → `profiles(id)`, `NOT NULL`. As noted in `backend-map-management/CLAUDE.md`, that service's create model currently omits this field entirely, so it can't actually satisfy this FK yet.
- `navigation_sessions.user_id` and `user_feedback.user_id` (`backend-navigation-management`) → `profiles(id)`.
- `profiles.place_id` → the unmanaged `places` table (same gap noted in `backend-map-management/CLAUDE.md` — no service creates `places` rows).
- `profiles.role_id` → this service's own `roles` table.

So although this was one of the later services scaffolded, almost every other service's "who did this" column ultimately points here.

## Authorization

Every `/profiles` endpoint depends on `get_caller_id` (`app/main.py`), which reads the `Authorization: Bearer <token>` header and verifies it for real against Supabase Auth itself via `packages.supabase.SupaBase.get_user_id_from_token` (a live call to `client.auth.get_user(token)`, not a local signature check) — 401 on a missing or invalid/expired token. A small `_is_admin(caller_id)` helper then looks up the caller's own `role_id` (seeded in `db_schema/roles.sql`: `1` = user, `2` = admin) to gate admin-only actions. This closed a real, previously-exploitable hole where `PATCH /profiles/{any_id}` with `{"role_id": 2}` let anyone self-promote to admin with no auth at all.

- **`POST /profiles`** — `id` and (unless the caller is already an admin) `role_id` are forced server-side to the verified caller's own id / the default `user` role, overriding whatever the request body sent. A caller can only ever create their own profile.
- **`GET /profiles`** — admin only.
- **`GET /profiles/{id}`** — admin, or the caller fetching their own profile.
- **`PATCH /profiles/{id}`** — admin, or the caller editing their own profile *and* the payload doesn't touch `role_id`/`is_active` (403 if it does) — this is the direct fix for the self-promotion exploit.
- **`DELETE /profiles/{id}`** — admin only.
- **`GET /roles`** / **`GET /roles/{id}`** — unauthenticated; static reference data, nothing sensitive.

This is the first service in the repo with real per-request auth — issue #24 tracks rolling the same `get_caller_id`/`_is_admin` pattern out to the other 5 backend services, which are all still fully unauthenticated.

## Complete workflow

1. **Signup flow** — `application/lib/auth/signup_screen.dart` calls Supabase Auth's `signUp`, then `POST /profiles` with the new auth user's id as the bearer-token-verified caller — see Authorization above for why the `id`/`role_id` in that request body no longer matter on their own.
2. **`POST /profiles`** — requires the caller to pass `id` (see Known issue below for why it can't come from a DB default), plus optional `place_id`/`full_name`/`avatar_url`/`phone`/`preferences`/`is_active`; `id`/`role_id` are overridden server-side as described above.
3. **`GET /profiles`** / **`GET /profiles/{id}`** — plain `select("*")` (list) / `.eq("id", id)` (single row via `result.data[0]`, 404 if not found — Supabase's client always returns a list from `.execute().data`, even filtered to one row), behind the admin/self guards above.
4. **`PATCH /profiles/{id}`** — partial update via `ProfileUpdate` (`model_dump(exclude_unset=True)`), the mechanism for changing "configuration" (e.g. `preferences.verbosity`/`feedback_type`) after the profile exists; `role_id`/`is_active` changes are admin-only.
5. **`DELETE /profiles/{id}`** — admin-only; nothing here checks whether `anchor_points.captured_by`/`navigation_sessions.user_id`/`user_feedback.user_id` reference this profile first (a real FK constraint would reject the delete or cascade, depending on how each table's `ON DELETE` is defined — `db_schema/anchor_points.sql` uses `ON DELETE CASCADE` on `building_id` but no explicit action on `captured_by`).
6. **`GET /roles`** / **`GET /roles/{id}`** — read-only access to the static `roles` reference table; nothing creates or modifies roles through this API (by design — it's seeded data).

## Known issue

`db_schema/profiles.sql` sets `id UUID PRIMARY KEY DEFAULT auth.uid()`, which only resolves inside an authenticated Supabase Auth request context. This service talks to Supabase with the **service_role** key (a trusted server-side process, not a per-request user JWT — see repo root `CLAUDE.md`), so that default never populates — `ProfileCreate.id` stays a required field the caller must set explicitly instead. The value itself is now trustworthy (forced to the verified caller id on create, see Authorization above), so this is a DB-schema wart, not a security gap.
