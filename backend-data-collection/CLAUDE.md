# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

See the repo root `CLAUDE.md` for overall project context. This service receives images + GPS metadata from the mobile app and persists them via Supabase (Postgres table + Storage bucket `"Photo"`).

## Commands

```bash
uv sync
uv run fastapi dev     # local dev server with reload
uv run pytest
docker build -t fastapi-app .
docker run -p 8000:80 fastapi-app
```

## Structure

- `app/main.py` — FastAPI app; instantiates `packages.supabase.SupaBase` at import time from `SUPABASE_URL`/`SUPABASE_PUBLISHABLE_KEY`, exposes `/upload` (POST/GET/DELETE) plus a `GET /` health check.
- `app/models.py` — `ImageMetaData`/`ImageMetaDataResponse` pydantic schemas (lat/lng/accuracy).
- `tests/conftest.py` sets dummy `SUPABASE_URL`/`SUPABASE_PUBLISHABLE_KEY` before import so `pytest` doesn't need real credentials or network access — only `GET /` is safe to assert against for real; the other endpoints hit Supabase at request time.

## Known issues

- The `GET`/`DELETE` `"/upload:id"` routes use a colon instead of FastAPI's `{id}` path-parameter syntax, so `id` is not actually bound from the URL path (it falls back to a query parameter). Don't assume these routes work as their names suggest without checking.
- All four route handlers are named `process_image_json`, which is harmless for FastAPI routing (each decorator registers independently) but confusing to read/grep — worth renaming if touching this file.
