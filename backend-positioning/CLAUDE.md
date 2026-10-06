# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

See the repo root `CLAUDE.md` for overall project context.

## Commands

```bash
uv sync
uv run fastapi dev
uv run pytest
# Docker build context must be the repo root:
(cd .. && docker build -f backend-positioning/Dockerfile -t backend-positioning .)
docker run -p 8000:80 --env-file .env backend-positioning
```

## What this service does

The Kalman-filter fusion half of the GPS positioning-correction pipeline (issues #31-34), real for the first time in this repo: `POST /correct_position` takes a live photo + GPS fix, calls `backend-ai-training`'s `POST /search_similar` to get a visual anchor-point match, and fuses the two via an Unscented Kalman Filter (`app/kalman.py`) into a corrected position. This is the piece the root README's Data Flow section describes as step 7 ("Kalman Filter: Fuses... to calculate the corrected position").

**No Qdrant credentials of its own** — it never queries Qdrant directly, only `backend-ai-training` via HTTP. It does now depend on `packages.supabase.SupaBase` (`SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY`, alongside `AI_TRAINING_URL`), added in the app-integration follow-up to #24 once the Flutter app became `POST /correct_position`'s first real end-user caller — `get_caller_id = db.get_caller_id` guards that endpoint the same way every other service's write endpoints are guarded, verifying the caller's bearer token live against Supabase Auth. This is purely an auth check: the service still never queries Postgres for anything else, and was the last service in the repo with no `packages` dependency at all before this (even `backend-ai-training`, the previous "lightest" service, already needed `packages.qdrant.Qdrant`).

## Scope: GPS + visual only, not GPS + IMU + visual

Issues #31-34's text says "GPS and IMU". Confirmed by an exhaustive grep across `application/lib/`: **no IMU (accelerometer/gyroscope) capture exists anywhere in the app** — only GPS (`geolocator`) and a magnetometer compass heading (`flutter_compass`). The original README's pipeline diagram names "IMU" as a planned input; nobody had confirmed it was never built until now. This service fuses GPS + visual match only. A follow-up issue tracks adding real IMU capture — not a deprioritization, there's genuinely no sensor data to fuse yet.

`heading` is accepted in the request body but not used in the filter math today — kept in the contract now so the IMU follow-up doesn't need a breaking API change.

## Architecture notes

- **`app/kalman.py`** is the pure math, deliberately separate from `app/main.py` and `app/session_store.py` so it's testable without FastAPI or any session bookkeeping (same separation `backend-ai-training/app/embedding.py` uses for its ML logic). State is `[x, y, vx, vy]` in a local tangent-plane (meters, equirectangular approximation, origin at the session's first GPS fix) — valid at campus scale. Both the process model (`fx`, constant-velocity) and measurement model (`hx`, direct `[x,y]` extraction, shared by both the GPS and visual updates) are linear, so a plain `KalmanFilter` would be mathematically equivalent to the UKF used here today — UKF is used anyway for forward-compatibility with a future nonlinear IMU update (bearing/angular-rate), not because today's math needs it. Don't read that as a mistake if you're reviewing the math.
- **Visual-match acceptance is a hard threshold, not a formula**: Qdrant's cosine-similarity `score` (confirmed via `backend-ai-training/app/main.py` and `packages/src/packages/qdrant.py`'s `Distance.COSINE` collection) is uncalibrated and can be negative — there's no real way to derive a measurement-noise magnitude from it without a calibration dataset this project doesn't have. `kalman.MIN_MATCH_SCORE` gates whether a match is used at all; an accepted match always gets the same fixed `kalman.VISUAL_SIGMA_METERS` noise, never a score-derived one. `kalman.clamp_confidence` clamps the returned score to `[0,1]` before it ever leaves this service, since `navigation_logs.confidence_score` has `CHECK (BETWEEN 0 AND 1)` and an unclamped negative value would violate that now that `NavigationScreen` forwards this response straight into `POST /logs`.
- **`app/session_store.py`** holds one UKF instance per `session_id`, in-memory only — lost on restart, doesn't work across multiple replicas. Accepted: Phase 1 is a single container per service, no horizontal scaling. Each session has its own `asyncio.Lock` held for the full predict→update sequence (concurrent requests for the same session, e.g. a client retry, would otherwise corrupt the filter's covariance — `UnscentedKalmanFilter` isn't safe for concurrent callers). Idle sessions (`SESSION_TTL_SECONDS`, default 15 min) are swept opportunistically on every call — nothing here subscribes to `navigation_sessions.status`, so without this every session ever started would stay in memory forever. A gap longer than `MAX_DT_SECONDS` (default 30s) since a session's last call re-initializes the filter from the new GPS fix rather than extrapolating a stale constant-velocity guess through a long silence (app backgrounded, poor connectivity).
- **Known, deliberate gap**: `/index_anchor`'s Qdrant payload (`backend-ai-training/app/main.py`) has no `floor` field, so a visual match can't disambiguate two visually-similar anchors stacked on different floors of the same building. Not fixed here — would mean changing `backend-ai-training`'s indexing payload, separate scope.
- **Known, deliberate gap**: `raw_image_url` in the response is always `null` — this service never uploads/stores the submitted frame (no Storage access, by design, see above). A future pass could add that if `navigation_logs.raw_image_url` turns out to matter in practice.
- **The call to `backend-ai-training` is the first service-to-service HTTP call anywhere in this repo.** Every other pair of services only talks to Supabase/Qdrant directly. Resilience matters more here than usual: a short per-attempt timeout plus a couple of retries with backoff (`app/main.py`'s `_search_similar`), degrading to a GPS-only correction (no visual update applied) rather than failing the whole request, since `backend-ai-training`'s model load does a real ~20MB network download on its *first* call after any restart (fixed in this change via its `Dockerfile` — see that service's own notes) and a bare single timeout wouldn't reliably survive that.

## How it connects to the rest of the system

- **Caller**: `NavigationScreen` (`application/lib/user/navigation_screen.dart`) is now the real caller - it runs a self-rescheduling 1s-floor loop (not `Timer.periodic`, to avoid overlapping calls once a round-trip exceeds 1s) that captures a live frame and posts it here alongside raw GPS, then forwards the response's `corrected_*` fields straight into `backend-navigation-management`'s `POST /logs` alongside the raw `gps_*` ones. Falls back to a raw-GPS-only log tick on any camera/permission/network failure - this service being unreachable or slow never blocks navigation.
- **Downstream shape**: the response is deliberately shaped to match `navigation_logs`' columns (`corrected_lat`/`corrected_long`/`correction_error`/`anchor_match_id`/`confidence_score`/`raw_image_url`), which `NavigationScreen` now passes straight through to `backend-navigation-management`'s `POST /logs` with no reshaping.
- **Calls `backend-ai-training`'s `POST /search_similar`** directly over the Docker Compose network (`AI_TRAINING_URL`, default `http://ai-training:80`) — not through the API gateway, since this is an internal service-to-service call, not a client-facing one.
