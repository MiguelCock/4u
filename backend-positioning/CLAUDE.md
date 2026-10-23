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

`heading` is the phone's **compass** heading (magnetic, like the anchor photos' stored headings). It doesn't enter the filter math, but it gates matches: a match photographed facing more than `POSITIONING_HEADING_GATE_DEG` away is refused. `gps_time` is the GPS fix's own timestamp, so the same fix sent again while standing still isn't fused twice.

## Architecture notes

- **`app/kalman.py`** is the pure math, deliberately separate from `app/main.py` and `app/session_store.py` so it's testable without FastAPI or any session bookkeeping (same separation `backend-ai-training/app/embedding.py` uses for its ML logic). State is `[x, y, vx, vy, bx, by]` in a local tangent-plane (meters, equirectangular approximation, origin at the session's first GPS fix) — valid at campus scale. Both the process model (`fx`, constant-velocity) and measurement model (`hx`, direct `[x,y]` extraction, shared by both the GPS and visual updates) are linear, so a plain `KalmanFilter` would be mathematically equivalent to the UKF used here today — UKF is used anyway for forward-compatibility with a future nonlinear IMU update (bearing/angular-rate), not because today's math needs it. Don't read that as a mistake if you're reviewing the math.
- **Visual-match gating (`app/matching.py`)**: after a field test showed matches pulling the position onto whatever the camera saw (jumps, an early arrival), a match is no longer "the user is exactly at that anchor".
  - **Candidates:** `/search_similar` is asked for `POSITIONING_SEARCH_LIMIT` (5) candidates within `POSITIONING_SEARCH_RADIUS_M` (60 m) and reduced to one per anchor (`best_per_anchor`).
  - **Gates, in score order** (`SessionStore.correct`), until one candidate passes all of them:
    1. score ≥ `POSITIONING_MIN_MATCH_SCORE`;
    2. distance from the fix ≤ max(`POSITIONING_MAX_MATCH_DISTANCE_M`, `POSITIONING_MATCH_ACCURACY_FACTOR` × accuracy);
    3. photo heading within `POSITIONING_HEADING_GATE_DEG` of the compass;
    4. Mahalanobis² ≤ `POSITIONING_MAHALANOBIS_GATE`, judged with the base sigma.
  - **How hard a match pulls:** sigma is `base + per_m × distance` (`visual_sigma`), so a far match pulls gently.
  - **Process noise:** Q scales with dt, and the zero-dt sigma-point resync adds none.
  - **Repeated fix = standing still:** a call whose `gps_time` matches the last one isn't fused as a position again. It gets `kalman.stationary_update` (velocity ≈ 0, σ 0.3 m/s) *before* the predict. The app's GPS stream has a 1 m distance filter, so no new fix means no movement. Simply skipping such fixes let 12 s of orienting grow the position uncertainty to ~12 m through the velocity term, and the next match moved the position 8.6 m.
  - **GPS offset in the state:** `(bx, by)` is the GPS fix's own slowly-changing offset, a Gauss-Markov process (`POSITIONING_GPS_BIAS_SIGMA_M` 4 m, `POSITIONING_GPS_BIAS_TAU_S` 120 s; 0 turns it off). A GPS fix measures position + offset (`_hx_gps`); a photo match measures the position alone. Walking a known path showed GPS 3–5 m to one side for a whole straight. Treated as independent noise, every fix pulled the estimate back to that side right after a match had fixed it. Replaying that walk (`scripts/replay.py`) gave a distance from the route of 3.64 m without the offset, 2.28 m with it. Sigma points use `kappa=0` (all weights positive), and a 1e-9 variance floor keeps P positive-definite when the offset is off.
  - **Seeding:** a new filter starts as uncertain as its first fix.
  - **Tuning:** every value is an environment variable (see `.env.example` and `docs/TUNING.md`).
  - **Diagnostics:** the response's `debug` lists every candidate with `score`, `distance_m`, `heading_diff`, `sigma_m`, `innovation_m`, `mahalanobis2` and a `verdict`, plus `dt_s`, `reinit`, `gps_fused` and velocity. The app stores it in `navigation_logs.debug.correction`.
  - **`/correct_position_once`:** runs the same gates through a throwaway `SessionStore`.
- **The match score never sets the noise**: Qdrant's cosine-similarity `score` (`Distance.COSINE`) is uncalibrated and can be negative, so it only gates (`POSITIONING_MIN_MATCH_SCORE`). The noise comes from the match's distance, never from its score. `kalman.MIN_MATCH_SCORE`/`VISUAL_SIGMA_METERS` remain only as `visual_update`'s defaults. `kalman.clamp_confidence` clamps the returned score to `[0,1]`, because `navigation_logs.confidence_score` has `CHECK (BETWEEN 0 AND 1)` and the app forwards this response straight into `POST /logs`.
- **Dev scripts** (`scripts/`, not used by the service): `export_session.py` dumps one session with its logs, route and anchors as JSON (read-only; run in this container on the server). `replay.py` runs that through the real `SessionStore` with any `MatchConfig` overrides or a grid. It scores against the route, and against checkpoint ground truth when the admin tapped checkpoints. See `docs/TUNING.md`.
- **`app/session_store.py`** holds one UKF instance per `session_id`, in-memory only — lost on restart, doesn't work across multiple replicas. Accepted: Phase 1 is a single container per service, no horizontal scaling. Each session has its own `asyncio.Lock` held for the full predict→update sequence (concurrent requests for the same session, e.g. a client retry, would otherwise corrupt the filter's covariance — `UnscentedKalmanFilter` isn't safe for concurrent callers). Idle sessions (`SESSION_TTL_SECONDS`, default 15 min) are swept opportunistically on every call — nothing here subscribes to `navigation_sessions.status`, so without this every session ever started would stay in memory forever. A gap longer than `MAX_DT_SECONDS` (default 30s) since a session's last call re-initializes the filter from the new GPS fix rather than extrapolating a stale constant-velocity guess through a long silence (app backgrounded, poor connectivity).
- **Known, deliberate gap**: `/index_anchor`'s Qdrant payload (`backend-ai-training/app/main.py`) has no `floor` field, so a visual match can't disambiguate two visually-similar anchors stacked on different floors of the same building. Not fixed here — would mean changing `backend-ai-training`'s indexing payload, separate scope.
- **Admin test walks keep their frames**: with `store_frame=true` (sent only by the app's "Test as user" mode, refused with 403 for non-admins), the frame goes to the public `navigation-frames` bucket. The bucket is created on first use with the service-role key, and the upload runs as a `BackgroundTasks` job after the response. `raw_image_url` returns the URL, which is known before the upload, and the app stores it in `navigation_logs`. This is this service's only Storage use; otherwise `raw_image_url` is `null`. `backend-navigation-management`'s session delete removes the files. The frames are there to compare photo models on real queries (`backend-ai-training/scripts/benchmark_models.py`).
- **The call to `backend-ai-training` is the first service-to-service HTTP call anywhere in this repo.** Every other pair of services only talks to Supabase/Qdrant directly. Resilience matters more here than usual: a short per-attempt timeout plus a couple of retries with backoff (`app/main.py`'s `_search_similar`), degrading to a GPS-only correction (no visual update applied) rather than failing the whole request, since `backend-ai-training`'s model load does a real ~20MB network download on its *first* call after any restart (fixed in this change via its `Dockerfile` — see that service's own notes) and a bare single timeout wouldn't reliably survive that.
- **`_search_similar` forwards the caller's raw lat/lng, plus `limit` and `radius_meters` from `MatchConfig`**, so the search is geo-scoped and returns several candidates. On failure it returns `[]`, which means a GPS-only correction.

- **`POST /correct_position_once` is the stateless sibling of `/correct_position`.** It takes the same form fields minus `session_id`, uses the same auth guard, and returns the same `CorrectPositionResponse`. It exists so the app can pick a route's *starting* anchor from a corrected position: that happens before any navigation session exists, so there's no `session_id`/filter state to use. Internally it runs the same `SessionStore.correct` (same gates) on a throwaway `SessionStore()`, so nothing is kept. It is no longer called by the app. `UserHomeScreen`'s start-point check now sends about 6 photos through the *session* `/correct_position` under a throwaway `start-check-<random>` key, so they fuse in one filter; a single photo was too little to improve the start. Kept as a working endpoint.

## How it connects to the rest of the system

- **Caller**: `NavigationScreen` (`application/lib/user/navigation_screen.dart`) is now the real caller - it runs a self-rescheduling 1s-floor loop (not `Timer.periodic`, to avoid overlapping calls once a round-trip exceeds 1s) that captures a live frame and posts it here alongside raw GPS, then forwards the response's `corrected_*` fields straight into `backend-navigation-management`'s `POST /logs` alongside the raw `gps_*` ones. Falls back to a raw-GPS-only log tick on any camera/permission/network failure - this service being unreachable or slow never blocks navigation.
- **Downstream shape**: the response is deliberately shaped to match `navigation_logs`' columns (`corrected_lat`/`corrected_long`/`correction_error`/`anchor_match_id`/`confidence_score`/`raw_image_url`), which `NavigationScreen` now passes straight through to `backend-navigation-management`'s `POST /logs` with no reshaping.
- **Calls `backend-ai-training`'s `POST /search_similar`** directly over the Docker Compose network (`AI_TRAINING_URL`, default `http://ai-training:80`) — not through the API gateway, since this is an internal service-to-service call, not a client-facing one.
