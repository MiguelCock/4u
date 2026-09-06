# backend-user-management

FastAPI service for managing user information and configuration: profile data (name, avatar, phone, home place, role) and per-user preferences (verbosity, feedback type) used across the app, plus the small `roles` reference table (`user`/`admin`).

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
docker build -t backend-user-management .
docker run -p 8000:80 --env-file .env backend-user-management
```

## API / manual usage

Once running, the interactive Swagger UI at `http://localhost:8000/docs` is the easiest way to try requests by hand.

| Method | Path            | Body            | Purpose                              |
|--------|-----------------|-----------------|-----------------------------------------|
| GET    | `/`             | —               | Health check                            |
| POST   | `/profiles`     | `ProfileCreate` | Create a profile for an existing auth user |
| GET    | `/profiles`     | —               | List all profiles                       |
| GET    | `/profiles/{id}`| —               | Get one profile by id                   |
| PATCH  | `/profiles/{id}`| `ProfileUpdate` | Update profile fields/preferences (partial) |
| DELETE | `/profiles/{id}`| —               | Delete a profile                        |
| GET    | `/roles`        | —               | List all roles                          |
| GET    | `/roles/{id}`   | —               | Get one role by id                      |

`ProfileCreate` fields (see `app/models.py`): `id` (must be an existing Supabase Auth user id — see **Known limitations**), `place_id` (optional), `role_id` (optional), `full_name` (optional), `avatar_url` (optional), `phone` (optional), `preferences` (defaults to `{"verbosity": "medium", "feedback_type": "voice"}`), `is_active` (default `true`). `ProfileUpdate` is the same shape minus `id`, with every field optional — only the fields you send are changed.

Example:

```bash
curl -X POST http://localhost:8000/profiles \
  -H "Content-Type: application/json" \
  -d '{
    "id": "11111111-1111-1111-1111-111111111111",
    "role_id": 1,
    "full_name": "Jane Doe",
    "preferences": {"verbosity": "high", "feedback_type": "voice"}
  }'

curl http://localhost:8000/profiles
curl http://localhost:8000/profiles/11111111-1111-1111-1111-111111111111

curl -X PATCH http://localhost:8000/profiles/11111111-1111-1111-1111-111111111111 \
  -H "Content-Type: application/json" \
  -d '{"preferences": {"verbosity": "low", "feedback_type": "voice"}}'

curl -X DELETE http://localhost:8000/profiles/11111111-1111-1111-1111-111111111111

curl http://localhost:8000/roles
```

## Testing

```bash
uv run pytest
```

`tests/conftest.py` sets dummy Supabase env vars so the test suite doesn't need real credentials or network access. Only `GET /` is currently exercised for real — the other endpoints hit Supabase at request time.

## Known limitations

- This is CRUD-stub level: no admin-role auth check, and `db_schema/profiles.sql`/`roles.sql` are accessed via `db.client.table(...)` directly (no wrapper in `packages` for these tables yet).
- `db_schema/profiles.sql` defines `id UUID PRIMARY KEY DEFAULT auth.uid()` — that default only resolves inside a real authenticated Supabase Auth request (a user calling the DB with their own session), which this service doesn't have since it talks to Supabase with the publishable key. `ProfileCreate` therefore requires the caller to pass `id` explicitly (the Supabase Auth user id the profile belongs to) instead of relying on the DB default. Revisit this once real auth is wired into the service.
