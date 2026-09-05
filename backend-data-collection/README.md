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
| POST   | `/upload`    | multipart file field `image` + JSON matching `ImageMetaData` (`latitude`, `longitude`, `accuracy`) | Upload a photo + its metadata  |
| GET    | `/upload`    | —                                                   | List uploaded photos            |
| GET    | `/upload:id` | —                                                   | Get one photo by id             |
| DELETE | `/upload:id` | —                                                   | Delete one photo by id          |

Example health check:

```bash
curl http://localhost:8000/
```

## Testing

```bash
uv run pytest
```

`tests/conftest.py` sets dummy Supabase env vars so the test suite doesn't need real credentials or network access. Only `GET /` is currently exercised for real — the other endpoints hit Supabase at request time.

## Known issues

- `POST /upload` mixes a plain JSON body (`ImageMetaData`) with a multipart file (`File(...)`) in the same request, which FastAPI does not support directly (a multipart request isn't JSON) — this endpoint likely needs the metadata fields declared with `Form(...)` instead. It also expects the file field to be named `image`, while the Flutter app (`application/lib/camera.dart`) currently uploads it as `photo` with the metadata as separate form fields.
- `GET /upload` and `GET /upload:id` both call the Supabase query (`db.get_photos()` / `db.get_photo(id)`) but discard the result and return an empty placeholder instead — they will always appear to return no data.
- `/upload:id` uses a literal colon rather than FastAPI's `{id}` path-parameter syntax, so `id` is not actually bound from the URL path.
