# backend-ai-training

PyTorch/OpenCV component for training and running the visual feature extractor (embedding model) used to match a live phone photo against the anchor point database. This is an offline/batch component — it has no HTTP API of its own (unlike the other `backend-*` services).

Built following the [uv + FastAPI guide](https://docs.astral.sh/uv/guides/integration/fastapi/#migrating-an-existing-fastapi-project) (the project scaffolding conventions carry over even though this component isn't a FastAPI service).

## Stack

- **PyTorch / torchvision**: training and running the visual feature extractor (embedding model) used to match anchor point photos. Installed from the CPU-only wheel index (`[[tool.uv.index]]` in `pyproject.toml`) rather than PyPI, since this component doesn't need GPU support to run.
- **OpenCV (`opencv-python-headless`)**: image preprocessing before embedding extraction — resizing and normalizing photos coming from the mobile app and from anchor point capture.

## Setup

```bash
uv sync
```

## Run manually

```bash
uv run dev
```

This runs `backend_ai_training.main:main` (the `dev` entry point declared in `pyproject.toml`), which currently just prints the installed `torch`/`cv2` versions as a sanity check that the environment is set up correctly. The actual training pipeline (embedding extraction, fine-tuning, Qdrant indexing described in the repo root `README.md`) is not implemented yet.

## Testing

```bash
uv run pytest
```

`tests/test_main.py` is a smoke test asserting `main()` runs and prints the expected output.
