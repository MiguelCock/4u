# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

See the repo root `CLAUDE.md` for overall project context.

## Commands

```bash
uv sync
uv run fastapi dev
uv run pytest
# Docker build context must be the repo root (Dockerfile also copies sibling packages/):
(cd .. && docker build -f backend-ai-training/Dockerfile -t backend-ai-training .)
docker run -p 8000:80 --env-file .env backend-ai-training
```

## What this service does

The image → embedding → Qdrant half of the visual-correction pipeline, now real: `POST /index_anchor` downloads an anchor point's photos, extracts a fixed-size embedding from each with a **pretrained** `torchvision.models.efficientnet_b0` (ImageNet weights, no fine-tuning — `app/embedding.py`), and upserts them into Qdrant. `POST /search_similar` does the same extraction on an uploaded query photo and returns the top-k nearest matches. This is the same CRUD-stub-adjacent shape as the other backend services (`app/main.py` talks straight to `packages.qdrant.Qdrant`), just with an ML step in the middle instead of a database write.

**Not implemented**: fine-tuning (the README's Week 2 milestone calls for adapting the model to campus images — deferred, using the pretrained weights as-is for now, matches the "PoC with 20 anchor points" scope). **Nothing calls `/search_similar` yet** — no navigation/correction pipeline exists anywhere in this repo (see `backend-navigation-management/CLAUDE.md`), so this endpoint is real and tested but has no caller today, same "build the capability, wire it up later" pattern as `backend-map-management`'s anchor-point-connections graph.

## Restructured from a stub

Until recently this was a `src/backend_ai_training/` src-layout package (`uv init --package` style) whose only code printed `torch`/`cv2` version strings — no HTTP server, no dependency on `packages`. It's now the flat `app/main.py`/`app/models.py` layout every other `backend-*-management` service uses (no installable package, no `[project.scripts]` entry), and depends on `packages` (editable path) like they do — this was the only Python component with no `packages` dependency before this change.

## Architecture notes

- **`app/embedding.py`** is deliberately separate from `app/main.py`'s routing so the ML logic is testable without a running FastAPI app. `load_and_resize` uses OpenCV explicitly (`cv2.imdecode` → `cv2.resize` → BGR→RGB) — this is the literal "OpenCV preprocessing" step from the README's Week 2 milestone, and also what finally gives `opencv-python-headless` a real caller instead of being imported only to print its version. `extract_embedding` then tensor-ifies + ImageNet-normalizes and runs `model.features` → `model.avgpool` → flatten to get the 1280-dim penultimate-layer output (not the 1000-way ImageNet classification — we want the feature vector, not a class label).
- **The model loads lazily**, not eagerly like this repo's usual `db = SupaBase(...)`/`qdrant = Qdrant(...)` construction pattern (both of those are instant, no network call). Loading pretrained EfficientNet-B0 weights is a real ~20MB download from `download.pytorch.org` the first time it runs — eager-loading it at import time would mean every `pytest` run and every cold start pays that cost. `_get_model()` caches a module-level singleton after the first real call. Tests never trigger it: `extract_embedding`/`download_image` are patched directly (`patch("app.main.extract_embedding", ...)`), the same way other services mock `db.client` instead of hitting real Supabase.
- **Qdrant collection**: `anchor_point_photos` (not `anchor_points` — deliberately named after the photos table it mirrors, since it's genuinely one point per photo, not one per anchor point; a single anchor point has ~4-8 photos, see `backend-map-management/CLAUDE.md`'s schema-split notes). 1280-dim, Cosine distance, created lazily via `qdrant.ensure_collection(...)` before the first upsert/query rather than at service startup.
- **Point IDs**: the Qdrant point id is the photo's own `anchor_point_photos.id` UUID (Qdrant's client accepts UUID strings natively) — so re-indexing the same photo overwrites its existing vector instead of creating a duplicate.
- **No service-to-service HTTP calls**, consistent with every other pair of services in this repo — this service never queries `backend-map-management`'s tables. The caller (the app) fetches an anchor point's photos itself and passes `photo_id`/`image_url`/`heading` directly in the `POST /index_anchor` body.

## How it connects to the rest of the system

- **Trigger**: `application/lib/admin/edit_anchor_point_screen.dart` calls `POST /index_anchor` right after a successful `PATCH /anchor-points/{id}` (via `backend-map-management`) that sets `status: 'verified'` — only confirmed-good anchor points end up in the searchable index. Indexing failure is a non-fatal snackbar warning in the app; the verify itself already succeeded.
- **`anchor_point_photos.image_url`** (Supabase Storage, public) is what `download_image` fetches — plain `httpx.get`, no Supabase credentials needed here at all (this service's `.env` only has `QDRANT_URL`/`QDRANT_KEY`).
- **`packages.qdrant.Qdrant`** (`packages/src/packages/qdrant.py`) now has a real caller — previously only its own test file (`packages/tests/test_qdrant.py`) exercised it.
- Downstream: `/search_similar`'s response shape (`anchor_point_id`/`latitude`/`longitude`/`score` per match) is what a future `/correct_position`-style endpoint would consume to turn a live query photo into a GPS correction — not built anywhere yet (see `backend-navigation-management/CLAUDE.md`).

## Complete workflow

1. **`POST /index_anchor`** — `IndexAnchorRequest` (`anchor_point_id`, `latitude`, `longitude`, `building_id`, `photos: [{photo_id, image_url, heading}]`). For each photo: download → embed → build a `PointStruct` (id, vector, payload). One `qdrant.client.upsert(...)` call with all points from the request. Returns `{"indexed": <count>}`.
2. **`POST /search_similar`** — multipart `file` (mirrors `backend-map-management`'s `POST /anchor-points/upload-image` pattern, since a live query photo isn't hosted anywhere to reference by URL) + optional `limit` form field (default 5). Embeds the upload, `qdrant.client.query_points(...)` top-k, maps each result's `payload`/`score` to a `SearchMatch`.
