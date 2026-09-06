# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

See the repo root `CLAUDE.md` for overall project context.

## Commands

```bash
uv sync
uv run fastapi dev
uv run pytest
docker build -t backend-route-management .
docker run -p 8000:80 backend-route-management
```

## What this service does

Creates and manages the navigation routes that guide `user`-role app users between anchor points inside a building (`routes` table, though see **Known issue** — the schema file for it isn't actually a routes table yet). Same CRUD-stub shape as the other services: `app/main.py` exposes `GET /`, `POST/GET /routes`, `GET /routes/{id}`, `DELETE /routes/{id}`, all via `db.client.table("routes")` directly.

## How it connects to the rest of the system

No service-to-service HTTP calls — only shared-table relationships:

- `RouteCreate.building_id`, `start_anchor_id`, `end_anchor_id`, and `waypoint_anchor_ids` are all meant to point at `backend-map-management`'s tables (`buildings`, `anchor_points`). There's no code dependency between the two services — both just hit the same Supabase DB directly — but there's an implied *data* ordering: a building and its anchor points have to exist before a route referencing them can be created, and this service does nothing to enforce or check that.
- `routes.id` is the FK target of `navigation_sessions.route_id`, owned by `backend-navigation-management` — a navigation session optionally records which route it was following. Again, no code dependency, just a shared table relationship, and again nothing here validates that a `route_id` passed to `backend-navigation-management` actually exists.
- This service sits downstream of the (currently nonexistent) admin anchor-point workflow and upstream of the app's `RouteListScreen`/`NavigationScreen` (`GET /routes`, then a `backend-navigation-management` session) — the "guidance line on the map" / corrected-position display described in the root README's Week 7-8 milestones still has no code (no correction pipeline exists to drive it), but the plain route-selection and session-tracking flow around it now does; see `application/CLAUDE.md`.

## Complete workflow

1. **`POST /routes`** — caller sends `RouteCreate` (`building_id`, `name`, `start_anchor_id`, `end_anchor_id`, `waypoint_anchor_ids`, defaulting to `[]`) → inserted as-is. No check that the referenced building/anchor point ids exist before insert (Postgres FK constraints would reject a bad id at the DB level once the real schema is in place — see Known issue).
2. **`GET /routes`** / **`GET /routes/{id}`** — plain `select("*")` (optionally `.eq("id", id)`).
3. **`DELETE /routes/{id}`** — deletes the row; nothing here checks whether a `navigation_sessions` row references this route first, so deleting a route out from under an in-progress session is possible (and would just leave a dangling `route_id` once real data exists, or fail on the DB's FK constraint, depending on how `ON DELETE` is eventually defined for that column — `db_schema/navigation_sessions.sql` doesn't specify one).

## Known issue

`db_schema/routes.sql` currently contains a copy-paste of `anchor_points.sql`, not an actual `routes` table definition. Fix that schema file (and reconcile it with `app/models.py` here) before wiring this service to a real database.
