# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

See the repo root `CLAUDE.md` for overall project context.

## Commands

```bash
uv sync
uv run fastapi dev     # local dev server with reload
uv run pytest
docker build -t fastapi-app .
docker run -p 8000:80 fastapi-app
```

## What this service does

Receives a photo plus GPS metadata from the mobile app and persists them via Supabase: the image goes to Supabase Storage (bucket `"Photo"`), and the metadata (`latitude`/`longitude`/`accuracy`) goes to a Postgres `"Photo"` table via `packages.supabase.SupaBase.post_photos`. Note this `"Photo"` table is *not* one of the `db_schema/*.sql` files — every other service's tables are defined there, but this one predates (or sits outside) the formal schema; `post_photos`'s insert assumes `name`/`latitude`/`longitude`/`accuracy` columns since there's nothing to confirm the real shape against. There's no heading/IMU field despite the root README describing the real-time flow as sending "photo + GPS + heading + accelerometer/gyroscope".

## How it connects to the rest of the system

This is the one backend service with a real network client: `application/lib/camera.dart`'s `_sendPhotoToServer`, which posts a multipart request (file field `image`, form fields `latitude`/`longitude`/`accuracy`) to whichever URL `BACKEND_URL` points at. Every other cross-component relationship here is aspirational, not code: this service is meant to be entry point #1 of the root README's real-time inference pipeline ("App sends photo+GPS+IMU" → "Server (FastAPI) receives and authenticates" → OpenCV preprocessing → PyTorch embedding → Qdrant search → Kalman filter → corrected position returned). None of the steps after "receives" exist in this repo yet — no OpenCV/PyTorch/Qdrant code runs here, and this service never returns a corrected position, only `"ok"`. It has no foreign-key relationship to any other service's tables (the `"Photo"` table isn't referenced by, or doesn't reference, `anchor_points`/`profiles`/etc.).

## Complete workflow

1. **`POST /upload`** — app sends a multipart request with an `image` file plus `latitude`/`longitude`/`accuracy` form fields (`Annotated[float, Form()]` parameters, not a JSON body — combining a Pydantic "form model" with `File(...)` turned out to be unreliable in this FastAPI version, so the fields are declared individually) → `db.post_photos(image.file, latitude, longitude, accuracy)` uploads the raw file to the `"Photo"` Storage bucket (keyed by filename) and inserts a matching metadata row into the `"Photo"` table.
2. **`GET /upload`** — returns `db.get_photos()`'s real result (a `select("*")` on the `"Photo"` table) directly, with no response-model validation (the table's real shape isn't confirmed against a schema file).
3. **`GET /upload/{id}`** / **`DELETE /upload/{id}`** — proper FastAPI path params (`{id}`, not a literal colon) bind `id` from the URL. `GET` returns `db.get_photo(id)`'s real result; `DELETE` calls `db.dele_photo(id)`, which itself looks up the stored filename and removes both the Storage object and the table row.
4. Handlers are named distinctly (`upload_photo`, `list_photos`, `get_photo`, `delete_photo`) rather than sharing one name across all four routes.

## Known limitations

- The `"Photo"` table's real column names are unconfirmed (see above) — if the actual deployed table differs from `name`/`latitude`/`longitude`/`accuracy`, update `packages/src/packages/supabase.py`'s `post_photos` to match.
- No IMU/heading fields, no auth, no admin-role check.
