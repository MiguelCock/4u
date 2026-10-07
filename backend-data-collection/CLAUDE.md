# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

See the repo root `CLAUDE.md` for overall project context.

## Commands

```bash
uv sync
uv run fastapi dev     # local dev server with reload
uv run pytest
# Docker build context must be the repo root (Dockerfile also copies sibling packages/):
(cd .. && docker build -f backend-data-collection/Dockerfile -t fastapi-app .)
docker run -p 8000:80 --env-file .env fastapi-app
```

## What this service does

Receives a photo plus GPS+heading metadata from the mobile app and persists them via Supabase: the image goes to Supabase Storage (bucket `"Photo"` — capitalized, a legacy name kept as-is since renaming a live bucket is riskier than renaming a table), and the metadata (`latitude`/`longitude`/`accuracy`/`heading`) goes to a Postgres `photos` table via `packages.supabase.SupaBase.post_photos`. `photos` is now a real `db_schema/photos.sql` file (it used to be an undocumented, unconfirmed-schema table referenced only as `"Photo"` — case-sensitive/quoted, inconsistent with every other snake_case table in this repo — and in fact **didn't exist at all** in the real Supabase project until this was fixed: `POST /upload` was silently broken in production, uploading the file to Storage successfully and then 500ing on the insert). `heading` is optional (nullable) since not every capture happens with a live compass reading available.

## How it connects to the rest of the system

This is the one backend service with a real network client: `application/lib/camera.dart`'s `_sendPhotoToServer`, which posts a multipart request (file field `image`, form fields `latitude`/`longitude`/`accuracy`, optional `heading`) via `DataCollectionApi` to the API gateway's `/data-collection` prefix, which routes here. `heading` comes from a live `flutter_compass` subscription (same pattern as the admin anchor-point capture flow, `capture_photo_screen.dart`) frozen at the moment the photo is taken; it's omitted from the form entirely when no compass reading is available yet, rather than sent as a literal null. Every other cross-component relationship here is aspirational, not code: this service is meant to be entry point #1 of the root README's real-time inference pipeline ("App sends photo+GPS+IMU" → "Server (FastAPI) receives and authenticates" → OpenCV preprocessing → PyTorch embedding → Qdrant search → Kalman filter → corrected position returned). None of the steps after "receives" exist in this repo yet — no OpenCV/PyTorch/Qdrant code runs here, and this service never returns a corrected position, only `"ok"`. It has no foreign-key relationship to any other service's tables (`photos` isn't referenced by, or doesn't reference, `anchor_points`/`profiles`/etc.).

## Complete workflow

1. **`POST /upload`** — app sends a multipart request with an `image` file plus `latitude`/`longitude`/`accuracy` form fields and an optional `heading` field (`Annotated[float, Form()]` parameters, not a JSON body — combining a Pydantic "form model" with `File(...)` turned out to be unreliable in this FastAPI version, so the fields are declared individually) → `db.post_photos(image.file, image.filename, latitude, longitude, accuracy, heading)` uploads the file to the `"Photo"` Storage bucket (keyed by the real uploaded `filename`) and inserts a matching metadata row into the `photos` table. `post_photos` takes an **explicit** `filename: str` parameter (mirroring `upload_image`'s signature) rather than trying to read one off the file object — it used to do `path=img.name`, but `image.file` is a `SpooledTemporaryFile` whose `.name` is an internal fd/`None`, never the real filename; this crashed for real (`yarl.URL` rejecting a non-str path) the first time `/upload` was exercised against a live device, since it had never been tested against real infra before. `post_photos` also sets `file_options={"content-type": ...}` from `mimetypes.guess_type(filename)` (same as `upload_image`) — without it, `storage3` defaults to `text/plain`, which the real `"Photo"` bucket's MIME-type restriction rejects (also only caught by live verification, not mocks). `post_photos` reads the `UploadFile`'s bytes (`img.read()`) before handing them to `storage3` — the raw `SpooledTemporaryFile` object isn't one of the types `storage3`'s `upload()` accepts and used to crash with a `TypeError`.
2. **`GET /upload`** — returns `db.get_photos()`'s real result (a `select("*")` on the `photos` table) directly, with no response-model validation.
3. **`GET /upload/{id}`** / **`DELETE /upload/{id}`** — proper FastAPI path params (`{id}`, not a literal colon) bind `id` from the URL. `GET` returns `db.get_photo(id)`'s real result; `DELETE` calls `db.dele_photo(id)`, which looks up the stored filename first (a list of row dicts from `select(...).data` — `dele_photo` reads the real filename string out of the first row rather than passing that list straight to `storage3`, a bug of the same shape as `post_photos`'s above, also only surfaced by live testing), deletes the table row, then best-effort removes the Storage object if a row was actually found (a no-op, not an error, if the id was already gone).
4. Handlers are named distinctly (`upload_photo`, `list_photos`, `get_photo`, `delete_photo`) rather than sharing one name across all four routes.

## Known limitations

- No auth, no admin-role check.
- `db_schema/photos.sql` must be applied by hand against the real Supabase project (same "hand-maintained, not a migration tool" convention as every other file in `db_schema/`) before `/upload` will actually work there.
