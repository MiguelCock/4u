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

Receives a photo plus GPS metadata from the mobile app and persists them via Supabase: the image goes to Supabase Storage (bucket `"Photo"`), and the metadata goes to a Postgres `"Photo"` table. Note this `"Photo"` table is *not* one of the `db_schema/*.sql` files — every other service's tables are defined there, but this one predates (or sits outside) the formal schema. `app/models.py`'s `ImageMetaData`/`ImageMetaDataResponse` just carry `latitude`/`longitude`/`accuracy`; there's no heading/IMU field despite the root README describing the real-time flow as sending "photo + GPS + heading + accelerometer/gyroscope".

## How it connects to the rest of the system

This is the one backend service with an intended (currently broken) network client: `application/lib/camera.dart`'s `_sendPhotoToServer`. See `application/CLAUDE.md` for the full three-way break (hardcoded URL bypassing `BACKEND_URL`, `photo`-vs-`image` field name mismatch, and the body/File signature issue described below). Every other cross-component relationship here is aspirational, not code: this service is meant to be entry point #1 of the root README's real-time inference pipeline ("App sends photo+GPS+IMU" → "Server (FastAPI) receives and authenticates" → OpenCV preprocessing → PyTorch embedding → Qdrant search → Kalman filter → corrected position returned). None of the steps after "receives" exist in this repo yet — no OpenCV/PyTorch/Qdrant code runs here, and this service never returns a corrected position, only `"ok"`. It has no foreign-key relationship to any other service's tables (the `"Photo"` table isn't referenced by, or doesn't reference, `anchor_points`/`profiles`/etc.).

## Complete workflow

1. **`POST /upload`** — as *intended*: app sends a photo + `ImageMetaData` (lat/lng/accuracy) → `db.post_photos(img)` uploads the raw file to the `"Photo"` Storage bucket, keyed by the incoming filename (`packages/src/packages/supabase.py`'s `post_photos`). As *actually written*: the handler signature `async def process_image_json(request: ImageMetaData, image: UploadFile = File(...))` mixes a JSON pydantic body with `File(...)` — FastAPI can't parse both a body model and a file from the same multipart/JSON request this way, so this endpoint doesn't work as written regardless of what the client sends. It also never uses `request` (the metadata is accepted but discarded — nothing writes lat/lng/accuracy anywhere, only the image file). Also, note the app's client sends field name `photo`, but this parameter is named `image` (see `application/CLAUDE.md`).
2. **`GET /upload`** — calls `db.get_photos()` (a real `select("*")` on the `"Photo"` table) but then discards the result and returns an empty, hardcoded `result: list[ImageMetaDataResponse] = []` — always returns `[]` regardless of what's actually stored.
3. **`GET /upload:id`** / **`DELETE /upload:id`** — the `:id` in the route path is a literal colon character, not FastAPI's `{id}` path-parameter syntax, so `id` is never bound from the URL; it silently falls back to being an unbound query parameter (`?id=`) that will 422 without one. `GET` also has the same discard-the-result bug as above (returns a hardcoded empty placeholder instead of `a`). `DELETE` does call `db.dele_photo(id)` for real, so `/upload:id?id=5` (not `/upload/5`) is the only way to actually hit that code path today.
4. All four route handlers are named `process_image_json`, which doesn't break FastAPI routing (each `@app.<verb>` decorator registers independently) but makes the code confusing to read or grep — worth renaming if touching this file.

## Known issues

Summarized in the workflow above: the `POST` body/File mismatch, the discarded `GET` results, the `:id` vs `{id}` bug, and the duplicate handler names. Fix the `POST /upload` signature and the app-side field name/URL together (see `application/CLAUDE.md`) — fixing only one side won't make an end-to-end upload work.
