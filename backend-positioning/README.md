# backend-positioning

FastAPI service fusing raw GPS with a visual anchor-point match into a corrected position: `POST /correct_position`, via an Unscented Kalman Filter (`filterpy`).

## Stack

- **filterpy**: the UKF implementation (`app/kalman.py`).
- **httpx**: calls `backend-ai-training`'s `POST /search_similar` directly over the Docker Compose network — the first service-to-service HTTP call in this repo.
- **FastAPI**: same conventions as every other `backend-*` service in this repo (`app/main.py`/`app/models.py`, no installable package).

No Supabase or Qdrant credentials — the only env var is `AI_TRAINING_URL` (see `.env.example`).

## Setup

```bash
uv sync
uv run fastapi dev
```

## Testing

```bash
uv run pytest
```

`tests/test_kalman.py` exercises the UKF math in isolation (no FastAPI, no I/O). `tests/test_main.py` mocks the httpx call to `backend-ai-training`, matching `backend-ai-training/tests/test_main.py`'s own mocking convention — no real network calls happen during `pytest`.
