# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

See the repo root `CLAUDE.md` for overall project context.

## Commands

```bash
uv sync
uv run fastapi dev
uv run pytest
# Docker build context must be the repo root (Dockerfile also copies sibling packages/):
(cd .. && docker build -f backend-map-management/Dockerfile -t backend-map-management .)
docker run -p 8000:80 --env-file .env backend-map-management
```

## What this service does

Backs the mobile app's admin view: creating/listing/editing/deleting anchor points (`anchor_points` table) and their photos (`anchor_point_photos` table), and creating/listing/editing/deleting buildings and places (`buildings`/`places` tables). Uploading a photo's bytes (`POST /anchor-points/upload-image`, to a Storage bucket named `"anchor-points"`) is a separate step from recording it against an anchor point. Like the other CRUD-stub services, `app/main.py` talks straight to Supabase via `db.client.table(...)` — no business logic (no anchor-point verification workflow beyond a plain `status` field, no admin-role auth check, no map-tile serving).

## Schema: anchor points vs. anchor point photos

One physical anchor point is captured with ~4-8 photos facing different directions (so the visual-matching pipeline has coverage regardless of which way a user is facing), so `anchor_points` and photos are two tables, not one:

- `anchor_points` — position/metadata only: `building_id`, `location_type_id`, `floor`, `latitude`, `longitude`, `altitude`, `location_description`, `status`, `metadata`. No `image_url`/`heading`/`captured_by`/`captured_at` anymore — those moved out.
- `anchor_point_photos` — one row per photo: `anchor_point_id` (FK, `ON DELETE CASCADE`), `image_url`, `heading`, `captured_by`, `captured_at`. Deleting an anchor point deletes all its photos automatically via the FK.

This was a live-data migration (see `db_schema/anchor_point_photos.sql` and the PR that introduced it for the exact `INSERT ... SELECT` + `ALTER TABLE ... DROP COLUMN` sequence) — not something this service applies itself, since `db_schema/` is hand-maintained, not a migration tool.

`AnchorPointResponse` (`app/models.py`) is deliberately *not* declared as `AnchorPointResponse(AnchorPointCreate)` like every other Create/Response pair in this file — `location_description` is required on create (it doubles as the anchor point's display name, so an admin needs a way to tell points apart) but stays optional on the response model, since rows captured before that rule existed may still have a null value and a required response field would 500 on them.

## How it connects to the rest of the system

There's no service-to-service HTTP call here — only shared-table relationships via `packages.supabase.SupaBase`:

- `buildings.place_id` → the `places` table, managed by this same service (`POST /places`, `GET /places`, `GET /places/{id}`, `PATCH /places/{id}`, `DELETE /places/{id}`) — an admin can create/edit/delete a place from the app (`AddPlaceScreen`/`EditPlaceScreen`) rather than seeding it by hand in Supabase.
- `anchor_points.location_type_id` → the `location_type` table, also unmanaged — it's a small static lookup (`entrance`, `intersection`, `elevator`, etc.) seeded directly in `db_schema/location_type.sql`, same pattern as `roles`. The app's `CaptureScreen` hardcodes this same list rather than fetching it.
- `anchor_point_photos.captured_by` → `profiles(id)`, owned by `backend-user-management`, and it's `NOT NULL` in `db_schema/anchor_point_photos.sql`. `AnchorPointPhotoCreate` (`app/models.py`) requires `captured_by: str` — the app's `capture_photo_screen.dart` sets it to the signed-in admin's Supabase Auth user id, once per photo.
- `anchor_points.id` is what `backend-navigation-management`'s `navigation_logs.anchor_match_id` points at, once a real-time correction pipeline exists to populate it (see `backend-ai-training/CLAUDE.md`) — no code dependency today, just the eventual FK relationship.
- `anchor_point_photos.image_url` is populated by this service's own upload endpoint (`POST /anchor-points/upload-image`, via `packages.supabase.SupaBase.upload_image`) rather than requiring a pre-hosted URL from elsewhere — the app calls it, then `POST /anchor-points/{id}/photos` with the returned URL.

## Complete workflow

1. **`POST /anchor-points/upload-image`** — accepts a multipart `file`, uploads it to the `"anchor-points"` Storage bucket via `db.upload_image(...)` (`packages/src/packages/supabase.py`, a generic bucket-upload helper shared with any future service that needs one), and returns `{"url": <public URL>}`. The bucket itself isn't created by this service — it must already exist in the Supabase project. `upload_image` reads the `UploadFile`'s bytes (`file.read()`) before handing them to `storage3` — passing the raw `SpooledTemporaryFile` object directly used to crash (`storage3` only accepts `BufferedReader`/`bytes`/`FileIO`/`str`/`Path`, and silently tried `open()`-ing the file object as if it were a path).
2. **`POST /anchor-points`** — caller (the app's `CaptureScreen`) sends `AnchorPointCreate` (`building_id`, `location_type_id`, `floor`, `latitude`, `longitude`, `altitude`, `location_description` — required) → inserted as-is into `anchor_points`. No photo yet at this point.
3. **`GET /anchor-points`** / **`GET /anchor-points/{id}`** — plain `select("*")` (list) / `.eq("id", id)` (single row via `result.data[0]`, 404 if not found — Supabase's client always returns a list from `.execute().data`, even filtered to one row). **`PATCH /anchor-points/{id}`** (`AnchorPointUpdate`, all fields optional, `exclude_unset=True` so unset fields aren't overwritten — same pattern as `backend-user-management`'s `update_profile`) covers editing the description, moving the position, and the verify workflow (`status`). **`DELETE /anchor-points/{id}`** — same `.delete().eq("id", id).execute()` pattern as `backend-route-management`'s `delete_route`, returns `"ok"`, cascades to that point's photos.
4. **`POST /anchor-points/{id}/photos`** — `AnchorPointPhotoCreate` (`image_url` from step 1, `heading`, `captured_by`) with `anchor_point_id` taken from the URL path, not the body. **`GET /anchor-points/{id}/photos`** — one anchor point's photos. **`GET /anchor-point-photos`** — every photo, flat, so the app can fetch once and group client-side (same "fetch all" pattern every other list in this app uses). **`DELETE /anchor-point-photos/{id}`** — removes a single bad/duplicate photo without touching the anchor point itself.
5. **`GET /buildings`** / **`GET /buildings/{id}`** — same pattern over the `buildings` table. **`POST /buildings`** (`BuildingCreate`: `place_id`, `code`, `name`, `latitude`, `longitude`, plus optional `address`/`floors`/`has_elevator`/`has_stairs`) creates one under an existing place, via the app's `AddBuildingScreen`. **`PATCH /buildings/{id}`** / **`DELETE /buildings/{id}`** — edit/delete, same `exclude_unset` PATCH pattern; delete cascades to that building's anchor points (and their photos).
6. **`POST /places`** / **`GET /places`** / **`GET /places/{id}`** — same CRUD pattern over `places` (`PlaceCreate`: `code`, `name`, `latitude`, `longitude`, plus optional `address`), via the app's `AddPlaceScreen`. **`PATCH /places/{id}`** / **`DELETE /places/{id}`** — edit/delete; delete cascades through buildings all the way to anchor points and photos, so the app warns with counts before calling it.
