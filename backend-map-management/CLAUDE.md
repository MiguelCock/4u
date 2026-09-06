# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

See the repo root `CLAUDE.md` for overall project context.

## Commands

```bash
uv sync
uv run fastapi dev
uv run pytest
docker build -t backend-map-management .
docker run -p 8000:80 backend-map-management
```

## What this service does

Backs the mobile app's admin view: creating/listing anchor points (`anchor_points` table) and reading building/map info (`buildings` table). Like the other CRUD-stub services, `app/main.py` talks straight to Supabase via `db.client.table(...)` — no business logic (no anchor-point verification workflow, no admin-role auth check, no map-tile serving).

## How it connects to the rest of the system

There's no service-to-service HTTP call here — only shared-table relationships via `packages.supabase.SupaBase`:

- `buildings.place_id` → the `places` table, which **no service manages** — `places` rows have to be seeded by hand (there's no CRUD for them anywhere in the repo).
- `anchor_points.location_type_id` → the `location_type` table, also unmanaged — it's a small static lookup (`entrance`, `intersection`, `elevator`, etc.) seeded directly in `db_schema/location_type.sql`, same pattern as `roles`.
- `anchor_points.captured_by` → `profiles(id)`, owned by `backend-user-management`, and it's `NOT NULL` in `db_schema/anchor_points.sql`. `AnchorPointCreate` (`app/models.py`) requires `captured_by: str` (the id of the admin who captured the point) to satisfy this.
- `anchor_points.id` is what `backend-navigation-management`'s `navigation_logs.anchor_match_id` points at, once a real-time correction pipeline exists to populate it (see `backend-ai-training/CLAUDE.md`) — no code dependency today, just the eventual FK relationship.
- `anchor_points.image_url` is meant to be a Supabase Storage URL, but nothing in this service (or any other) currently uploads an image and hands back that URL — `backend-data-collection`'s Storage upload writes to the separate `"Photo"` table/bucket, not to anything `anchor_points`-specific. A caller has to already have a hosted image URL before calling `POST /anchor-points`.

## Complete workflow

1. **`POST /anchor-points`** — caller (intended: the app's admin capture screen) sends `AnchorPointCreate` (`building_id`, `location_type_id`, `floor`, `heading`, `image_url`, `latitude`, `longitude`, `altitude`, `location_description`, `captured_by`) → inserted as-is into `anchor_points`. The image itself must already be hosted somewhere before this call — there's no upload step here.
2. **`GET /anchor-points`** / **`GET /anchor-points/{id}`** — plain `select("*")` (list) / `.eq("id", id)` (single row, 404 if not found), returned as `AnchorPointResponse` (adds `id`/`status` on top of the create fields). Note the by-id lookup pulls `result.data[0]`, not `result.data` — Supabase's client always returns a list from `.execute().data` even filtered to one row; returning the list directly against a single-object response model would raise a `ResponseValidationError`.
3. **`GET /buildings`** / **`GET /buildings/{id}`** — same pattern over the `buildings` table; there's no `POST /buildings` here, so buildings (and by extension `places`) currently have to be created by hand in Supabase before any anchor point can reference them.
