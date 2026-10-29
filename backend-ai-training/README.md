# backend-ai-training

FastAPI service turning anchor-point photos into Qdrant-searchable embeddings: `POST /index_anchor` and `POST /search_similar`, using a pretrained place-recognition model as a fixed feature extractor (no fine-tuning): EigenPlaces ResNet50 by default, or EfficientNet-B0 with `EMBEDDING_MODEL=effnet`. Admin endpoints `GET /index_status` and `POST /reconcile` show and repair gaps between the database and the index. `/search_similar` is internal: only `backend-positioning` calls it, and the gateway refuses it from outside.

## Stack

- **PyTorch / torchvision**: the embedding model (EigenPlaces' published ResNet50 weights, pinned by SHA-256 and baked into the image; or `efficientnet_b0`), CPU wheel index — no GPU needed.
- **OpenCV (`opencv-python-headless`)**: image decode/resize before embedding extraction.
- **Qdrant** (via the shared `packages` library): vector storage and top-k similarity search.
- **FastAPI**: same conventions as every other `backend-*` service in this repo (`app/main.py`/`app/models.py`, no installable package).

## Setup

```bash
uv sync
uv run fastapi dev
```

Needs a `.env` with `QDRANT_URL`/`QDRANT_KEY` and `SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY` (see `.env.example`): Supabase verifies callers on the admin endpoints, and `/reconcile` reads which photos should be indexed. Callers still pass the photos to index straight in the request body.

## Testing

```bash
uv run pytest
```

Tests mock the Qdrant client and the embedding/image-download functions directly (`unittest.mock.patch`) — no real model weights are downloaded and no real network calls happen during `pytest`. `tests/test_embedding.py` exercises the real OpenCV decode/resize logic (fast, no model involved); `tests/test_main.py` exercises the FastAPI routes with everything else mocked.
