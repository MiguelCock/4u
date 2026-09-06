# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

See the repo root `CLAUDE.md` for overall project context.

## Commands

```bash
uv sync
uv run fastapi dev
uv run pytest
docker build -t backend-navigation-management .
docker run -p 8000:80 backend-navigation-management
```

## What this service does

This service owns the three `db_schema/` tables nothing else does: `navigation_sessions` (one row per "user walks a route" attempt — start/end time, status, start/end position, which route/building it happened in), `navigation_logs` (one row per GPS tick during a session — raw GPS, and, once it exists, the visually-corrected position and which anchor point matched), and `user_feedback` (a free-text comment tied to a user and optionally a session). Like every other backend service here, it's CRUD-stub level: `app/main.py` inserts/selects/updates rows via `db.client.table(...)` directly, with no business logic (no session-timeout handling, no validation that a session is `active` before you can log against it, no aggregation/analytics over logs).

## How it connects to the rest of the system

There is no service-to-service HTTP call anywhere in this codebase — every backend service, including this one, talks straight to the same Supabase Postgres database via `packages.supabase.SupaBase`. "Connects to" here means *shares tables via foreign key*, not "calls an API":

- `navigation_sessions.user_id` → `profiles(id)`, owned by `backend-user-management`. `navigation_sessions.building_id` and `navigation_sessions.route_id` → `buildings(id)` / `routes(id)`, owned by `backend-map-management` / `backend-route-management` respectively. In practice this means a session can only be created for a user/building/route that those other services (or a manual DB insert) already created — this service has no way to create any of those itself.
- `navigation_logs.session_id` → this service's own `navigation_sessions(id)`. `navigation_logs.anchor_match_id` → `anchor_points(id)`, owned by `backend-map-management` — it's meant to record *which* anchor point a live photo was matched against.
- `user_feedback.user_id` → `profiles(id)` (`backend-user-management`); `user_feedback.session_id` → this service's own `navigation_sessions(id)`.
- This makes `backend-user-management`'s `profiles` table the single most depended-upon table in the schema: `anchor_points.captured_by` (`backend-map-management`) and both FK columns here (`navigation_sessions.user_id`, `user_feedback.user_id`) all point at it.
- **Where this sits in the root README's data flow**: the README describes a real-time loop — app sends photo+GPS+IMU → FastAPI → OpenCV preprocessing → PyTorch embedding → Qdrant similarity search → Kalman filter fusion → corrected position returned to the app — and this service's `navigation_logs` table is exactly where each tick of that loop's *result* would be recorded (`corrected_lat`/`corrected_long`/`correction_error`/`anchor_match_id`/`confidence_score`). None of that pipeline exists yet: `backend-ai-training` is a version-check stub, no service calls Qdrant, and there is no `/correct_position`-style endpoint anywhere. This service is downstream plumbing for a pipeline that hasn't been built — it can store a correction, but nothing produces one.
- No dependency on `packages.qdrant` — that would belong to whatever service eventually runs the similarity search (most likely `backend-ai-training` or a new inference service), not this one.

## Complete workflow

1. **Start a session** — `POST /sessions` with `user_id`, `building_id`, and optionally `route_id`/`start_position`/`device_info`. Inserts a row into `navigation_sessions` with `status` defaulting to `active` (the DB default from `db_schema/navigation_sessions.sql`; this service doesn't set it explicitly). Nothing in the app currently calls this — there's no navigation UI in `application/` yet (see `application/CLAUDE.md`).
2. **Log a tick** — `POST /logs` with `session_id` and raw `gps_lat`/`gps_long`/`gps_accuracy`/`heading`. The `corrected_*`/`anchor_match_id`/`confidence_score`/`raw_image_url` fields exist on the model so a future inference pipeline can fill them in on the same call, but today every caller has to either omit them or pass raw GPS as both the raw and "corrected" value — there's no other component that computes a correction to pass in.
3. **End a session** — `PATCH /sessions/{id}` with `status` (`completed`/`abandoned`/`failed`) and optionally `end_time`/`end_position`.
4. **Leave feedback** — `POST /feedback` with `user_id` and a `comment`, optionally tied to a `session_id`.
5. **Read back** — `GET /sessions`, `/logs`, `/feedback` do a plain `select("*")`; the `/{id}` variants add `.eq("id", id)` and return `result.data[0]` (404 if empty — Supabase's client always returns a list from `.execute().data`, even filtered to one row). No filtering by user/session otherwise — there's no "give me this user's sessions" or "give me this session's logs" endpoint; a caller has to fetch everything and filter client-side.

## Known issues

- No FK-existence checks before insert — if `user_id`/`building_id`/`route_id`/`session_id`/`anchor_match_id` don't exist, Supabase will reject the insert with a raw Postgres FK-violation error rather than a friendly 4xx.
- `NavigationSessionUpdate`/`NavigationLogCreate`/`UserFeedbackCreate` type timestamps and JSON position fields loosely (`str`/`dict`) to match the rest of the codebase's minimal-typing style — no validation that `start_position`/`end_position` actually contain lat/lng keys.
