# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

See the repo root `CLAUDE.md` for overall project context.

## Commands

```bash
uv sync
uv run dev          # project.scripts entry -> backend_ai_training.main:main
uv run pytest
```

## What this service does

Meant to be the offline half of the visual-correction pipeline: train/fine-tune a pretrained CNN (EfficientNet-B0, per the root README's Week 2 milestone) that turns an anchor-point photo into a fixed-size embedding, preprocess images with OpenCV first, and index the resulting embeddings in Qdrant alongside their coordinates. None of that exists yet — `src/backend_ai_training/main.py` is a stub that imports `torch`/`cv2` and prints their versions plus a hello message. There is no training loop, no embedding extraction function, and no Qdrant client usage anywhere in this directory.

## How it connects to the rest of the system

This is the only Python component with **no dependency on `packages` at all** — check `pyproject.toml`: unlike the four `backend-*-management` services, it has no `packages` entry in `dependencies` and no `[tool.uv.sources]` override. That's notable because once real indexing is implemented, this service will need `packages.qdrant.SupaBase` (the Qdrant client wrapper — yes, it's also named `SupaBase`, a copy-paste naming leftover in `packages/src/packages/qdrant.py`) to actually write embeddings anywhere. Today it's fully disconnected from the shared library.

The data it would eventually need to read is `anchor_points.image_url`, owned by `backend-map-management` (Supabase Storage-hosted images) — there's no code here that fetches those images either. `opencv-python-headless` is a declared dependency for the preprocessing step (resize/normalize before embedding extraction) and is imported in `main.py`, but only to print its version — it isn't called on any actual image yet. `pyproject.toml` pins `torch`/`torchvision` to the CPU wheel index (`[[tool.uv.index]] name = "pytorch-cpu"`); keep that source override if more torch-ecosystem packages are added, or `uv sync` may pull CUDA wheels instead.

Downstream, this service's output (a Qdrant collection of anchor-point embeddings) is what a real-time inference step would query against — but no such inference endpoint exists in any service (see `backend-data-collection/CLAUDE.md` and `backend-navigation-management/CLAUDE.md` for where that gap shows up on the other end: `navigation_logs.corrected_lat`/`anchor_match_id` have columns waiting for a result this pipeline would eventually produce).

## Complete workflow

Today: `uv run dev` runs `main()`, which prints `torch.__version__`, `cv2.__version__`, and a hello line — that's the entire behavior, verified by `tests/test_main.py`'s smoke test via `capsys`.

Intended (from the root README, **not implemented**, described here only so it isn't confused with current behavior): (1) admin captures anchor point photos via the not-yet-existing app admin UI → `backend-map-management` stores metadata + `image_url`; (2) this service loads those images, preprocesses with OpenCV (resize/normalize), and runs them through the fine-tuned EfficientNet-B0 to get a 1280-dim embedding; (3) embeddings are indexed in Qdrant via `packages.qdrant` alongside the anchor point's id/coordinates; (4) the feature extractor is trained once and doesn't need retraining when new anchor points are added — only new embeddings get indexed.
