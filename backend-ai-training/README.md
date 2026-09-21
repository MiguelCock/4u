# backend-ai-training

FastAPI service turning anchor-point photos into Qdrant-searchable embeddings: `POST /index_anchor` and `POST /search_similar`, both using a pretrained `torchvision.models.efficientnet_b0` (no fine-tuning) as a fixed feature extractor.

## Stack

- **PyTorch / torchvision**: the embedding model (`efficientnet_b0`, ImageNet-pretrained, CPU wheel index — this component doesn't need GPU support to run).
- **OpenCV (`opencv-python-headless`)**: image decode/resize before embedding extraction.
- **Qdrant** (via the shared `packages` library): vector storage and top-k similarity search.
- **FastAPI**: same conventions as every other `backend-*` service in this repo (`app/main.py`/`app/models.py`, no installable package).

## Setup

```bash
uv sync
uv run fastapi dev
```

Needs a `.env` with `QDRANT_URL`/`QDRANT_KEY` (see `.env.example`) — no Supabase credentials required, since it never queries Postgres directly; callers pass anchor-point/photo data straight in the request body.

## Testing

```bash
uv run pytest
```

Tests mock the Qdrant client and the embedding/image-download functions directly (`unittest.mock.patch`) — no real model weights are downloaded and no real network calls happen during `pytest`. `tests/test_embedding.py` exercises the real OpenCV decode/resize logic (fast, no model involved); `tests/test_main.py` exercises the FastAPI routes with everything else mocked.
