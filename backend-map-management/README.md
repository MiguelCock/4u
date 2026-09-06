# backend-map-management

FastAPI service backing the mobile app's **admin view**: capturing anchor points (photos with exact coordinates at strategic campus locations) and reading building/map info used to place them.

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
docker build -t backend-map-management .
docker run -p 8000:80 --env-file .env backend-map-management
```

## API / manual usage

Once running, the interactive Swagger UI at `http://localhost:8000/docs` is the easiest way to try requests by hand.

| Method | Path                   | Body                | Purpose                              |
|--------|------------------------|----------------------|----------------------------------------|
| GET    | `/`                    | —                    | Health check                           |
| POST   | `/anchor-points`       | `AnchorPointCreate`  | Register a new anchor point            |
| GET    | `/anchor-points`       | —                    | List all anchor points                 |
| GET    | `/anchor-points/{id}`  | —                    | Get one anchor point by id             |
| GET    | `/buildings`           | —                    | List all buildings                     |
| GET    | `/buildings/{id}`      | —                    | Get one building by id                 |

`AnchorPointCreate` fields (see `app/models.py`): `building_id`, `location_type_id` (optional), `floor` (default `0`), `heading` (optional), `image_url`, `latitude`, `longitude`, `altitude` (optional), `location_description` (optional), `captured_by` (the Supabase Auth user id of the admin who captured the point — required, matches `anchor_points.captured_by NOT NULL REFERENCES profiles(id)`).

Example:

```bash
curl -X POST http://localhost:8000/anchor-points \
  -H "Content-Type: application/json" \
  -d '{
    "building_id": "00000000-0000-0000-0000-000000000000",
    "location_type_id": 1,
    "floor": 0,
    "image_url": "https://example.com/anchor.jpg",
    "latitude": 6.2442,
    "longitude": -75.5812,
    "location_description": "Main entrance",
    "captured_by": "11111111-1111-1111-1111-111111111111"
  }'

curl http://localhost:8000/anchor-points
curl http://localhost:8000/buildings
```

## Testing

```bash
uv run pytest
```

`tests/conftest.py` sets dummy Supabase env vars so the test suite doesn't need real credentials or network access. Only `GET /` is currently exercised for real — the other endpoints hit Supabase at request time.

## Current limitations

This is CRUD-stub level: it inserts/reads rows via `db.client.table(...)` directly (no admin-role auth check, no anchor point verification workflow, no image upload — `image_url` must already point at a hosted image). See the root `CLAUDE.md` and this directory's `CLAUDE.md` for more context.
