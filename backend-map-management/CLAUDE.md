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

Backs the mobile app's admin view: creating/listing anchor points (`anchor_points` table), reading building/map info (`buildings` table), and now uploading the anchor-point photo itself (`POST /anchor-points/upload-image`, to a Storage bucket named `"anchor-points"`). Like the other CRUD-stub services, `app/main.py` talks straight to Supabase via `db.client.table(...)` — no business logic (no anchor-point verification workflow, no admin-role auth check, no map-tile serving).

## How it connects to the rest of the system

There's no service-to-service HTTP call here — only shared-table relationships via `packages.supabase.SupaBase`:

- `buildings.place_id` → the `places` table, which **no service manages** — `places` rows have to be seeded by hand (there's no CRUD for them anywhere in the repo).
- `anchor_points.location_type_id` → the `location_type` table, also unmanaged — it's a small static lookup (`entrance`, `intersection`, `elevator`, etc.) seeded directly in `db_schema/location_type.sql`, same pattern as `roles`. The app's `CaptureScreen` hardcodes this same list rather than fetching it.
- `anchor_points.captured_by` → `profiles(id)`, owned by `backend-user-management`, and it's `NOT NULL` in `db_schema/anchor_points.sql`. `AnchorPointCreate` (`app/models.py`) requires `captured_by: str` to satisfy this — the app's `CaptureScreen` sets it to the signed-in admin's Supabase Auth user id.
- `anchor_points.id` is what `backend-navigation-management`'s `navigation_logs.anchor_match_id` points at, once a real-time correction pipeline exists to populate it (see `backend-ai-training/CLAUDE.md`) — no code dependency today, just the eventual FK relationship.
- `anchor_points.image_url` is now actually populated by this service's own upload endpoint (`POST /anchor-points/upload-image`, via `packages.supabase.SupaBase.upload_image`) rather than requiring a pre-hosted URL from elsewhere — the app calls it, then `POST /anchor-points` with the returned URL.

## Complete workflow

1. **`POST /anchor-points/upload-image`** — accepts a multipart `file`, uploads it to the `"anchor-points"` Storage bucket via `db.upload_image(...)` (`packages/src/packages/supabase.py`, a generic bucket-upload helper shared with any future service that needs one), and returns `{"url": <public URL>}`. The bucket itself isn't created by this service — it must already exist in the Supabase project.
2. **`POST /anchor-points`** — caller (the app's `CaptureScreen`) sends `AnchorPointCreate` (`building_id`, `location_type_id`, `floor`, `heading`, `image_url` — from step 1, `latitude`, `longitude`, `altitude`, `location_description`, `captured_by`) → inserted as-is into `anchor_points`.
3. **`GET /anchor-points`** / **`GET /anchor-points/{id}`** — plain `select("*")` (list) / `.eq("id", id)` (single row via `result.data[0]`, 404 if not found — Supabase's client always returns a list from `.execute().data`, even filtered to one row).
4. **`GET /buildings`** / **`GET /buildings/{id}`** — same pattern over the `buildings` table; there's no `POST /buildings` here, so buildings (and by extension `places`) currently have to be created by hand in Supabase before any anchor point can reference them.
