# backend-navigation-management

FastAPI service for tracking user navigation: sessions (a user walking a route in a building), per-tick logs (raw GPS + whatever visual correction was computed), and post-session feedback comments.

Built following the [uv + FastAPI guide](https://docs.astral.sh/uv/guides/integration/fastapi/#migrating-an-existing-fastapi-project).

## Setup

```bash
cp .env.example .env   # fill in SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY
uv sync
```

## Run locally

```bash
uv run fastapi dev             # http://localhost:8000, auto-reload
```

Or with Docker:

```bash
docker build -t backend-navigation-management .
docker run -p 8000:80 --env-file .env backend-navigation-management
```

## API / manual usage

Once running, the interactive Swagger UI at `http://localhost:8000/docs` is the easiest way to try requests by hand.

| Method | Path            | Body                     | Purpose                              |
|--------|-----------------|--------------------------|-----------------------------------------|
| GET    | `/`             | —                        | Health check                            |
| POST   | `/sessions`     | `NavigationSessionCreate`| Start a navigation session              |
| GET    | `/sessions`     | —                        | List all sessions                       |
| GET    | `/sessions/{id}`| —                        | Get one session by id                   |
| PATCH  | `/sessions/{id}`| `NavigationSessionUpdate`| End/update a session (status, end_time, end_position) |
| POST   | `/logs`         | `NavigationLogCreate`    | Record one GPS/correction tick          |
| GET    | `/logs`         | —                        | List all logs                           |
| GET    | `/logs/{id}`    | —                        | Get one log by id                       |
| POST   | `/feedback`     | `UserFeedbackCreate`     | Record a user comment                   |
| GET    | `/feedback`     | —                        | List all feedback                       |
| GET    | `/feedback/{id}`| —                        | Get one feedback entry by id            |

Example:

```bash
curl -X POST http://localhost:8000/sessions \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "11111111-1111-1111-1111-111111111111",
    "building_id": "00000000-0000-0000-0000-000000000000",
    "route_id": "22222222-2222-2222-2222-222222222222"
  }'

curl -X POST http://localhost:8000/logs \
  -H "Content-Type: application/json" \
  -d '{
    "session_id": "33333333-3333-3333-3333-333333333333",
    "gps_lat": 6.2442,
    "gps_long": -75.5812,
    "gps_accuracy": 12.5
  }'

curl -X PATCH http://localhost:8000/sessions/33333333-3333-3333-3333-333333333333 \
  -H "Content-Type: application/json" \
  -d '{"status": "completed"}'

curl -X POST http://localhost:8000/feedback \
  -H "Content-Type: application/json" \
  -d '{"user_id": "11111111-1111-1111-1111-111111111111", "comment": "Lost signal near the elevator"}'
```

## Testing

```bash
uv run pytest
```

`tests/conftest.py` sets dummy Supabase env vars so the test suite doesn't need real credentials or network access. Only `GET /` is currently exercised for real — the other endpoints hit Supabase at request time.

## Known limitations

- This is CRUD-stub level: no auth check, no validation that `user_id`/`building_id`/`route_id`/`anchor_match_id` actually reference existing rows (Postgres FK constraints will reject bad ids, but this service doesn't check first or return a friendly error).
- Nothing populates `NavigationLogCreate.corrected_lat`/`corrected_long`/`correction_error`/`anchor_match_id`/`confidence_score` today — those fields exist because `db_schema/navigation_logs.sql` has columns for the real-time visual-correction pipeline (OpenCV → PyTorch embedding → Qdrant search → Kalman filter) described in the root `README.md`, but that pipeline isn't implemented anywhere in the repo yet. This service only gives that future pipeline somewhere to write its output — it doesn't compute anything itself.
- See `CLAUDE.md` in this directory for how this service's tables connect to every other service.
