# 4u

GPS positioning correction for assisted navigation of visually impaired people on university campuses — no extra hardware, just a phone.

## About

Raw GPS is usually accurate to 5-20 meters, which isn't tight enough to safely guide someone who can't see the path in front of them. Dedicated indoor-positioning hardware (BLE beacons, LIDAR) can close that gap, but it's expensive to install and maintain across an entire campus.

4u takes a different approach: an admin walks the campus once, photographing landmark "anchor points" (entrances, intersections, elevators, etc.) with their exact coordinates. From then on, when a user is navigating, their phone's live photo is matched against that anchor-point database using a visual embedding model, and the match is fused with the phone's raw GPS via a Kalman filter to produce a corrected position — typically under 5 meters of error, using hardware everyone already carries.

## Features

- **Visual GPS correction** — matches a live photo against indexed anchor-point photos (EfficientNet-B0 embeddings + Qdrant similarity search) and fuses the match with raw GPS via an Unscented Kalman filter.
- **Trip planning & navigation** — pick a destination, get an auto-computed route over admin-built walkability connections, and follow a live guidance line on the map while navigating.
- **Admin anchor-point tooling** — capture photos + coordinates, review and verify submissions, build the walkability graph between points, and manage the places/buildings hierarchy — all from the app.
- **Session review** — browse every user's past navigation sessions grouped by user, re-watch a session's logged trail against its planned route, and read the feedback comments they left.
- **Admin "test as user"** — run the full trip-planning → navigation → feedback flow on your own admin account, no second test account needed.
- **Accessibility settings** — high contrast, adjustable text size, and a fully localized UI (English/Spanish).

## Architecture

A Python/Dart monorepo: a single Flutter app (serving both a `user` and an `admin` role) talks to seven independent FastAPI microservices through one API gateway, backed by Supabase (Postgres + Storage) and Qdrant (vector search).

| Path | What it is |
|---|---|
| [`application/`](application/README.md) | The Flutter mobile app — both roles, one codebase. |
| [`backend-data-collection/`](backend-data-collection/CLAUDE.md) | Receives raw walk photos + GPS from the app. |
| [`backend-map-management/`](backend-map-management/CLAUDE.md) | Admin CRUD: places, buildings, anchor points, connections. |
| [`backend-route-management/`](backend-route-management/CLAUDE.md) | Computes and stores navigation routes. |
| [`backend-user-management/`](backend-user-management/CLAUDE.md) | Profiles, roles, preferences. |
| [`backend-navigation-management/`](backend-navigation-management/CLAUDE.md) | Navigation sessions, GPS/correction logs, feedback. |
| [`backend-ai-training/`](backend-ai-training/CLAUDE.md) | Embedding extraction + Qdrant indexing/search. |
| [`backend-positioning/`](backend-positioning/CLAUDE.md) | Fuses GPS + a visual match into a corrected position. |
| [`packages/`](packages/) | Shared Python library (DB/vector-store clients, auth). |
| [`db_schema/`](db_schema/) | Hand-maintained Postgres table definitions. |
| [`gateway/`](gateway/) | The nginx reverse proxy every client talks to. |
| [`deployment/phase1-ec2/`](deployment/phase1-ec2/README.md) | Scripts for the live EC2 deployment. |

## Tech stack

| Layer | Technology |
|---|---|
| Mobile app | Flutter (Dart) |
| Backend | Python, FastAPI, `uv` |
| Visual embeddings | PyTorch (EfficientNet-B0) |
| Vector search | Qdrant |
| Position fusion | Unscented Kalman filter (`filterpy`) |
| Database & storage | Supabase (Postgres + S3-compatible storage) |
| CI/CD | GitHub Actions |

## Quick start

```bash
git clone https://github.com/MiguelCock/4u.git
cd 4u

# one-time: create a Supabase project, apply db_schema/*.sql, create two
# Storage buckets, and a Qdrant Cloud (or self-hosted) instance

# fill in each backend service's .env from its .env.example, then:
docker compose up --build

cd application
cp .env.example .env   # fill in Supabase + the gateway URL
flutter pub get
flutter run
```

For the full walkthrough — exact schema order, Storage bucket setup, running every service, and a manual end-to-end test script — see **[`docs/SETUP.md`](docs/SETUP.md)**.

## Usage

- Using the app as a developer: [`application/README.md`](application/README.md).
- Using the admin flow (capturing anchor points, verifying them, building routes): [`docs/admin-guide/`](docs/admin-guide/README.md) (English/Spanish).

## Documentation

Each component has its own `CLAUDE.md` with the real architecture detail — how it's built, what it depends on, and its known gaps. Start with the root [`CLAUDE.md`](CLAUDE.md) for the full repository map and conventions.

## Project status

Actively developed. See the repo's [Issues](https://github.com/MiguelCock/4u/issues) for what's in progress and known gaps.

## Contributing

Branch off `develop`, open a PR against it — CI runs the matching component's tests automatically. `main` tracks tagged releases only.
