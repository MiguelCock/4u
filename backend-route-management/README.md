# backend-route-management

FastAPI service for creating and managing the navigation routes that guide `user`-role app users between anchor points inside a building.

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
docker build -t backend-route-management .
docker run -p 8000:80 --env-file .env backend-route-management
```

## API / manual usage

Once running, the interactive Swagger UI at `http://localhost:8000/docs` is the easiest way to try requests by hand.

| Method | Path            | Body           | Purpose                    |
|--------|-----------------|-----------------|------------------------------|
| GET    | `/`             | —               | Health check                 |
| POST   | `/routes`       | `RouteCreate`   | Create a new route            |
| GET    | `/routes`       | —               | List all routes               |
| GET    | `/routes/{id}`  | —               | Get one route by id           |
| DELETE | `/routes/{id}`  | —               | Delete one route by id        |

`RouteCreate` fields (see `app/models.py`): `building_id`, `name`, `start_anchor_id`, `end_anchor_id`, `waypoint_anchor_ids` (optional list, defaults to empty).

Example:

```bash
curl -X POST http://localhost:8000/routes \
  -H "Content-Type: application/json" \
  -d '{
    "building_id": "00000000-0000-0000-0000-000000000000",
    "name": "Main entrance to elevator",
    "start_anchor_id": "11111111-1111-1111-1111-111111111111",
    "end_anchor_id": "22222222-2222-2222-2222-222222222222",
    "waypoint_anchor_ids": []
  }'

curl http://localhost:8000/routes
curl -X DELETE http://localhost:8000/routes/<id>
```

## Testing

```bash
uv run pytest
```

`tests/conftest.py` sets dummy Supabase env vars so the test suite doesn't need real credentials or network access. Only `GET /` is currently exercised for real — the other endpoints hit Supabase at request time.

