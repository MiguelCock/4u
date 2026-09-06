# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

GPS positioning correction system for assisted navigation of visually impaired users on university campuses. It corrects raw GPS (5-20m error) down to <5m by matching a live phone photo against a database of pre-captured "anchor point" photos (visual embeddings), then fusing that visual correction with GPS and IMU data via a Kalman filter. See `README.md` for the full project rationale, data flow, and development schedule.

This is a Python/Dart monorepo, not a single deployable app — each top-level directory is an independently versioned component with its own `pyproject.toml`/`pubspec.yaml`.

## Repository layout

- `application/` — Flutter mobile app (Dart). Single codebase for both `user` (sends photo+GPS+IMU, receives corrected position) and `admin` (captures anchor points) roles.
- `backend-data-collection/` — FastAPI service that receives images + GPS metadata from the app and persists them via Supabase (Postgres + Storage).
- `backend-ai-training/` — PyTorch/torchvision service for training/running the visual feature extractor (embedding model) offline.
- `backend-map-management/` — FastAPI service for the admin view: creating/listing anchor points and reading building/map info (`anchor_points`, `buildings` tables).
- `backend-route-management/` — FastAPI service for creating and managing user-facing navigation routes (`routes` table).
- `backend-user-management/` — FastAPI service for managing user information and configuration: profile data and preferences (`profiles` table) plus the static `roles` reference table.
- `backend-navigation-management/` — FastAPI service tracking navigation sessions, per-tick GPS/correction logs, and user feedback (`navigation_sessions`, `navigation_logs`, `user_feedback` tables).
- `packages/` — Shared Python library (`uv` workspace package, importable as `packages`) wrapping Supabase and Qdrant clients. Consumed by the backend services via `[tool.uv.sources]` path dependencies (see `backend-data-collection/pyproject.toml`), not published. Its purpose is to hold logic shared across backend services (DB/vector-store clients, auth helpers, etc.) so each new service depends on it instead of re-implementing that logic — put cross-service logic here, not in an individual service.
- `db_schema/` — Hand-maintained Postgres/Supabase table definitions (not a migration tool — apply manually). Core entities: `places` → `buildings` → `anchor_points`, plus `profiles`/`roles`, `navigation_sessions` → `navigation_logs`, `routes`, `user_feedback`, `location_type`. `navigation_sessions`, `navigation_logs`, and `user_feedback` are owned by `backend-navigation-management`. Note: `db_schema/routes.sql` currently contains a copy-paste of `anchor_points.sql` rather than an actual `routes` table definition — fix this before relying on it for `backend-route-management`.

Each Python component (`backend-data-collection`, `backend-ai-training`, `backend-map-management`, `backend-route-management`, `backend-user-management`, `backend-navigation-management`, `packages`) is a separate `uv` project with its own lockfile — run `uv` commands from inside that directory, not the repo root.

The backend is split into independent microservices by responsibility (per `README.md`) rather than one monolith. New services should follow the same pattern used by `backend-map-management`/`backend-route-management`: scaffolded with `uv init --app --no-package`, an `app/` package (`main.py`, `models.py`), a `tests/` suite, an editable path dependency on `../packages` (`[tool.uv.sources]`), and registration in the CI workflow's `filters` and `components` (see CI below).

## Commands

### Python backends (uv)

Run from within the specific component directory (`backend-data-collection/`, `backend-ai-training/`, `backend-map-management/`, `backend-route-management/`, `backend-user-management/`, `backend-navigation-management/`, or `packages/`):

```bash
uv sync                    # install dependencies (creates .venv)
uv run pytest              # run tests
uv run fastapi dev         # run backend-data-collection locally with reload
```

`backend-data-collection` depends on the local `packages` project via an editable path source, so changes in `packages/` are picked up immediately without reinstalling.

Docker (backend-data-collection):
```bash
docker build -t fastapi-app .
docker run -p 8000:80 fastapi-app
```

### Flutter app (`application/`)

```bash
flutter pub get
flutter run
flutter test
flutter pub outdated
flutter pub upgrade --major-versions
```

Connecting a physical device over ADB (wireless):
```bash
adb pair IP_ADDRESS:PAIRING_PORT PAIR_CODE
adb connect IP_ADDRESS:ADB_PORT
adb devices
```

## Testing expectations

Every component is expected to carry its own test suite: the Flutter app is tested with `flutter test`, and every Python component (`packages` and each backend service) is tested with `pytest` via `uv run pytest`. When adding a new backend service or extending `packages`, add tests alongside it rather than leaving it uncovered — CI (below) is wired to discover and run these per-component.

## CI

`.github/workflows/ci.yml` uses `dorny/paths-filter` to detect which of `application/`, `packages/`, `backend-data-collection/`, `backend-map-management/`, `backend-route-management/`, `backend-user-management/`, `backend-navigation-management/`, `backend-ai-training/` changed, then runs only the matching test job (`flutter test` or `uv run pytest`) for each. New Python components must be added to both the `filters` and `components` arrays in that workflow to get CI coverage. Note the path filter only triggers a service's tests when that service's own files change — editing `packages/` does not currently re-run the consuming services' test jobs.

## Environment configuration

Each service loads secrets from its own `.env` (see each component's `.env.example`, all gitignored). `backend-data-collection` needs `SUPABASE_URL`/`SUPABASE_KEY` and `QDRANT_URL`/`QDRANT_KEY`; `backend-map-management`, `backend-route-management`, `backend-user-management`, and `backend-navigation-management` need `SUPABASE_URL`/`SUPABASE_PUBLISHABLE_KEY`; the Flutter app needs `SUPABASE_URL`/`SUPABASE_PUBLISHABLE_KEY` (Auth) plus one base-URL var per backend service it calls (`BACKEND_URL`, `MAP_MANAGEMENT_URL`, `ROUTE_MANAGEMENT_URL`, `USER_MANAGEMENT_URL`, `NAVIGATION_MANAGEMENT_URL`). Env vars are loaded via `python-dotenv` (`load_dotenv()`) in Python services and `flutter_dotenv` (`dotenv.load(fileName: ".env")`) in the Flutter app — the app's `pubspec.yaml` declares `.env` as an asset, so CI copies `.env.example` to `.env` before `flutter pub get`/`flutter test` (see `.github/workflows/ci.yml`).

## Architecture notes

- **`packages` client wrappers**: `SupaBase` (`packages/src/packages/supabase.py`) wraps Supabase Storage (photo bucket `"Photo"`), auth (`sing_up`/`log_in`/`is_logged_in` stubs), and photo-table CRUD, but exposes the underlying `supabase-py` client as `db.client` — services that need a table `SupaBase` doesn't wrap yet (e.g. `anchor_points`, `buildings`, `routes` in `backend-map-management`/`backend-route-management`) call `db.client.table(...)` directly rather than duplicating a wrapper method per table. If the same table access pattern starts repeating across services, promote it into `SupaBase` instead of leaving it duplicated in each service's `app/main.py`. `qdrant.py` similarly wraps `QdrantClient` for vector storage of anchor point embeddings.
- **New backend services (`backend-map-management`, `backend-route-management`)**: currently CRUD-stub level, mirroring `backend-data-collection`'s style — a `GET /` health check plus per-resource create/list/get endpoints that talk straight to Supabase tables, no business logic (route computation, anchor verification workflow, etc.) implemented yet. Tests use `fastapi.testclient.TestClient` against the FastAPI `app` object; `tests/conftest.py` sets dummy `SUPABASE_URL`/`SUPABASE_PUBLISHABLE_KEY` env vars before import so `pytest` doesn't need real credentials or network access — only the `/` route is safe to assert against without hitting Supabase for real, since the client is created eagerly at module import time.
- **Flutter app structure**: `main.dart` loads `.env`, initializes Supabase Auth, and shows `AuthGate` (`lib/auth/auth_gate.dart`), which routes to `LoginScreen`/`SignupScreen` when signed out, or `UserHomeScreen`/`AdminHomeScreen` (by `profiles.role_id`) when signed in. `UserHomeScreen` (`lib/user/`) is the original three-widget prototype — `LocationInfo` (location.dart), `SimpleCameraWidget` (camera.dart), `SimpleMapWidget` (map.dart) — all driven by the singleton `LocationService` (`lib/services/location_service.dart`), which exposes a broadcast `Stream<Position>` and a cached `lastPosition` that the widgets subscribe to independently rather than sharing state via a parent widget; it now also has a "Navigate" entry point into `route_list_screen.dart`/`navigation_screen.dart` (route selection → session start → periodic raw-GPS logging → session end/feedback, all against `backend-route-management`/`backend-navigation-management`). `AdminHomeScreen` (`lib/admin/`) is still a placeholder. `lib/services/api_service.dart` provides one HTTP client class per backend service (reading its base URL from `.env`) for screens to use instead of inlining `http` calls.
- **Data flow today**: the camera widget POSTs a multipart request (image + lat/lng/accuracy fields) directly to a hardcoded backend URL in `camera.dart` rather than reading `BACKEND_URL` — the app now loads `.env` for everything else (Auth, the other services' API clients), but this one call hasn't been switched over yet.
- The AI training/inference pipeline (embedding extraction, Kalman filter, Qdrant similarity search endpoints) described in the root `README.md` is largely aspirational relative to current code — `backend-ai-training` is currently just a torch/OpenCV version-check stub (`opencv-python-headless` is a declared dependency for the planned image preprocessing step, not yet wired into a real pipeline), and no inference/correction endpoints exist yet in `backend-data-collection`. Don't assume README-described endpoints exist; check the actual source.
