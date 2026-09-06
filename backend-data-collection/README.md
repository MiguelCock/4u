# backend-data-collection

FastAPI service that receives photos + GPS metadata from the mobile app (both the `user` role sending navigation photos and the `admin` role capturing anchor points) and stores them in Supabase — the photo file goes to the `"Photo"` Storage bucket, and its metadata goes to the `Photo` table.

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
docker build -t fastapi-app .
docker run -p 8000:80 --env-file .env fastapi-app
```

## API / manual usage

Once running, the interactive Swagger UI at `http://localhost:8000/docs` is the easiest way to try requests by hand.

| Method | Path         | Body                                             | Purpose                        |
|--------|--------------|---------------------------------------------------|---------------------------------|
| GET    | `/`          | —                                                   | Health check                    |
| POST   | `/upload`    | multipart file field `image` + form fields `latitude`, `longitude`, `accuracy` | Upload a photo + its metadata  |
| GET    | `/upload`    | —                                                   | List uploaded photos            |
| GET    | `/upload/{id}` | —                                                 | Get one photo by id             |
| DELETE | `/upload/{id}` | —                                                 | Delete one photo by id          |

Example:

```bash
curl http://localhost:8000/

curl -X POST http://localhost:8000/upload \
  -F "latitude=6.2442" \
  -F "longitude=-75.5812" \
  -F "accuracy=8.5" \
  -F "image=@/path/to/photo.jpg;type=image/jpeg"

curl http://localhost:8000/upload
curl http://localhost:8000/upload/5
curl -X DELETE http://localhost:8000/upload/5
```

## Testing

```bash
uv run pytest
```

`tests/conftest.py` sets dummy Supabase env vars so the test suite doesn't need real credentials or network access. `tests/test_main.py` mocks the `db` calls (`unittest.mock.patch`) to exercise the route logic (path-param binding, form/file parsing, response passthrough) without hitting Supabase for real.

## Known limitations

- The `"Photo"` Postgres table isn't defined in the repo's `db_schema/` — `packages.supabase.SupaBase.post_photos` assumes it has `name`/`latitude`/`longitude`/`accuracy` columns (matching the pydantic field names), since there's no schema file to confirm the real deployed shape against. Adjust `post_photos` if the actual table differs.
- `GET /upload` and `GET /upload/{id}` return whatever Supabase returns with no response-model validation (same reason — the table's real shape is unconfirmed), so malformed rows would pass through as-is rather than erroring.
