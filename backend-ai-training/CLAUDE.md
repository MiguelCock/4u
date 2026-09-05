# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

See the repo root `CLAUDE.md` for overall project context. This service is for training/running the visual feature extractor (PyTorch) used to match anchor point photos, with OpenCV handling image preprocessing.

## Commands

```bash
uv sync
uv run dev          # project.scripts entry -> backend_ai_training.main:main
uv run pytest
```

## Structure

- `src/backend_ai_training/main.py` — currently a stub: prints the installed `torch` and `cv2` versions and a hello message. No training loop, embedding extraction, or inference pipeline is implemented yet — don't assume the README-described pipeline (EfficientNet fine-tuning, Qdrant indexing) exists in code.
- `tests/test_main.py` — smoke test that `main()` runs and prints the expected line (via `capsys`).
- `pyproject.toml` pins `torch`/`torchvision` to the CPU wheel index (`[[tool.uv.index]] name = "pytorch-cpu"`, `[tool.uv.sources]`) — keep that source override if you add more torch-ecosystem packages, or `uv sync` may pull CUDA wheels instead.
- `opencv-python-headless` is a declared dependency for the planned image preprocessing step (resize/normalize before embedding extraction) — it's wired in as an import in `main.py` but not yet used for actual preprocessing.
