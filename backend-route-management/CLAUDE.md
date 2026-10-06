# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

See the repo root `CLAUDE.md` for overall project context.

## Commands

```bash
uv sync
uv run fastapi dev
uv run pytest
# Docker build context must be the repo root (Dockerfile also copies sibling packages/):
(cd .. && docker build -f backend-route-management/Dockerfile -t backend-route-management .)
docker run -p 8000:80 --env-file .env backend-route-management
```

## What this service does

Creates and manages the navigation routes (`routes` table) that guide `user`-role app users between two anchor points, plus the pathfinding (`app/pathfinding.py`) that computes one automatically. `app/main.py` exposes `GET /`, `POST/GET /routes`, `GET /routes/{id}`, `DELETE /routes/{id}` (CRUD-stub shape, same as the other services, all via `db.client.table("routes")` directly), plus `POST /routes/find_or_create` — the real entry point for the app's trip-planning flow.

## Routes are no longer single-building scoped

Originally `routes.building_id` was `NOT NULL`, framing a route as "inside one building." As of the trip-planning work it's nullable (`db_schema/routes.sql`) — a route can span any two anchor points anywhere on campus, since `anchor_point_connections` (`backend-map-management`'s graph) was always allowed to cross buildings. `building_id` now just records "the building the trip starts in," set from the start anchor when a route is auto-created; it's informational, not an enforced scope. `routes` also gained a nullable `created_by` (audit field, forced server-side to the verified caller — any authenticated user can create a route now, not just admins, since trip planning creates one as a side effect of picking a start/end point).

## Pathfinding (`app/pathfinding.py`)

`shortest_path(connections, start_id, end_id) -> list[str] | None` is plain Dijkstra (stdlib `heapq`, no new dependency) over an adjacency list built from `anchor_point_connections` rows, weighted by `distance_meters` (a missing weight defaults to a large constant rather than crashing — don't read that as "distance doesn't matter," it's a defensive fallback for a row that somehow has no distance recorded). Deliberately pure — no FastAPI/DB imports, same separation `backend-positioning/app/kalman.py` and `backend-ai-training/app/embedding.py` use for their own math/ML logic, testable standalone (`tests/test_pathfinding.py`). Returns the full path including both endpoints, or `None` if the graph doesn't connect them — a very real possibility given the connections graph is hand-built by admins and may simply not cover every pair of anchor points yet.

**First time this repo reads a table outside the reading service's own domain**: `find_or_create_route` queries `anchor_point_connections` and `anchor_points` directly, both owned by `backend-map-management` elsewhere in this repo's documentation. This is deliberate, not an oversight — every service already shares one Supabase Postgres project directly with no per-service DB isolation (see root `CLAUDE.md`'s architecture notes), and routing this through a new service-to-service HTTP call just to fetch rows this service's own `SupaBase` client can already reach would be pure overhead. "Owns a table" in this repo has always meant "is the primary place that table's CRUD endpoints live," not "is the only service allowed to query it."

## How it connects to the rest of the system

No service-to-service HTTP calls — only shared-table relationships:

- `RouteCreate.building_id`, `start_anchor_id`, `end_anchor_id`, and `waypoint_anchor_ids` all point at `backend-map-management`'s tables. `POST /routes/find_or_create` is the first code anywhere that actually reads `anchor_point_connections` (see above) — every other reference to these tables across the repo is still just an FK relationship, not a real query.
- `routes.id` is the FK target of `navigation_sessions.route_id`, owned by `backend-navigation-management` — a navigation session optionally records which route it was following.
- This service sits upstream of the app's trip-planning flow (`application/lib/user/plan_trip_screen.dart` → `POST /routes/find_or_create` → `NavigationScreen`, see `application/CLAUDE.md`) and of `backend-navigation-management`'s sessions.

## Complete workflow

1. **`POST /routes`** — caller sends `RouteCreate` (`building_id` now optional, `name`, `start_anchor_id`, `end_anchor_id`, `waypoint_anchor_ids` defaulting to `[]`) → `created_by` forced to the verified caller, inserted. No check that the referenced building/anchor point ids exist before insert (Postgres FK constraints reject a bad id at the DB level instead). Any authenticated user, not admin-only.
2. **`GET /routes`** / **`GET /routes/{id}`** — plain `select("*")` (list) / `.eq("id", id)` (single row via `result.data[0]`, 404 if not found).
3. **`DELETE /routes/{id}`** — admin-only (unchanged); deletes the row with no check that a `navigation_sessions` row references it first.
4. **`POST /routes/find_or_create`** (any authenticated user) — the real trip-planning entry point: given `start_anchor_id`/`end_anchor_id`, 400s if they're equal, returns an existing route with that exact pair if one exists (not reversed - a return trip gets its own row), else computes a path via `shortest_path` over the full `anchor_point_connections` graph, 404s if the two points aren't connected by any chain of connections, and otherwise inserts a new route (`waypoint_anchor_ids` = the computed path's intermediate anchors, `name` auto-generated from both anchors' `location_description`, `building_id` from the start anchor) and returns it.

## Known issues

- No reverse-direction route matching (`B -> A` creates a separate row from an existing `A -> B` even though it's the same physical path reversed) - accepted tradeoff for simplicity; `waypoint_anchor_ids` would need reversing too, not just the start/end swap.
- No validation that a found path's intermediate anchors are safely walkable (floor changes, elevator-only connections, etc.) beyond whatever `anchor_point_connections.notes` an admin recorded by hand.
