# Local setup & end-to-end testing

Each component's own README/`CLAUDE.md` documents testing it in isolation (`uv run pytest` per backend service, `flutter test` for the app). This doc is for testing them *together* — standing up every component against one Supabase project and exercising the real signup → admin capture → route → navigation flow.

## 1. Create a Supabase project

Create one at [supabase.com](https://supabase.com) (or use an existing project). From **Project Settings → API**, note down the **Project URL**, the **anon / publishable** API key, and the **service_role secret** — every `SUPABASE_URL` value below is the same URL; the app's own `.env` (step 5) uses the publishable key, while all 7 backend services (step 4) use the service_role key. **The service_role key bypasses Row Level Security and has full database access — never put it in the app's `.env` or anywhere client-facing, only in the backend services' gitignored `.env` files.**

## 2. Apply the schema

In the Supabase SQL editor, run the files in `db_schema/` **in this order** (later tables reference earlier ones by foreign key):

```
places.sql
roles.sql            -- self-seeds 'user'/'admin'
location_type.sql    -- self-seeds 9 location types
profiles.sql
buildings.sql
anchor_points.sql    -- run `CREATE EXTENSION IF NOT EXISTS btree_gist;` first -
                      -- its GiST index needs it
anchor_point_photos.sql  -- one row per photo (~4-8 per anchor point);
                          -- must come after anchor_points.sql
anchor_point_connections.sql  -- walkability graph edges between anchor points
routes.sql
navigation_sessions.sql
navigation_logs.sql
user_feedback.sql
```

`places` and `buildings` have no seed data. Once the app and `backend-map-management` are running (steps 4-5 below), an admin can create both from the app itself (sign in as `admin` → the **Places**/**Buildings** tab's floating action button) — no SQL needed. To seed them by hand instead (e.g. before the app is running):

```sql
INSERT INTO places (id, code, name, latitude, longitude)
VALUES ('11111111-1111-1111-1111-111111111111', 'CAMPUS', 'Main Campus', 6.2442, -75.5812);

INSERT INTO buildings (id, place_id, code, name, latitude, longitude)
VALUES ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', 'B1', 'Building 1', 6.2442, -75.5812);
```

## 3. Create Storage buckets

In Supabase Storage, create two **public** buckets — neither service creates its bucket automatically:
- `Photo` (used by `backend-data-collection`)
- `anchor-points` (used by `backend-map-management`)

Also create a Qdrant instance ([Qdrant Cloud](https://qdrant.tech) or self-hosted) and note its URL/API key — used by `backend-ai-training`.

## 4. Run the backend services

The app talks to all 7 services through a single **API gateway** (`gateway/nginx.conf`, path-prefix reverse proxy) rather than 7 separate ports:

```bash
# fill in each service's .env first
for d in backend-data-collection backend-map-management backend-route-management backend-user-management backend-navigation-management backend-ai-training backend-positioning; do
  (cd "$d" && cp .env.example .env)   # fill in credentials from step 1
done

docker compose up --build
```

This starts all 7 services (no longer individually host-exposed) plus the `gateway` service on port **8000**, which is what the app actually talks to:

| Gateway path prefix | Routes to |
|---|---|
| `/data-collection/*` | `backend-data-collection` |
| `/map/*` | `backend-map-management` |
| `/route/*` | `backend-route-management` |
| `/user/*` | `backend-user-management` |
| `/navigation/*` | `backend-navigation-management` |
| `/ai-training/*` | `backend-ai-training` |
| `/positioning/*` | `backend-positioning` |

e.g. `POST http://localhost:8000/route/routes` reaches `backend-route-management`'s `POST /routes`. The gateway's port is published on `0.0.0.0`, so it's reachable from another device on the same WiFi network at `http://<your-LAN-IP>:8000`, not just from `localhost` — this matters because the app is normally tested on a physical phone (see step 5), which can't reach the dev machine's `localhost`.

`backend-positioning` needs no Qdrant credentials of its own (it calls `backend-ai-training` over the Docker Compose network instead) — just `SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY` (to verify caller tokens) and the plain `AI_TRAINING_URL`. `backend-data-collection`'s `.env.example` also declares `QDRANT_URL`/`QDRANT_KEY` — nothing in the service currently reads them, so any placeholder value there is fine.

**To iterate on a single service in isolation** (its own Swagger UI, curl, pytest) rather than through the app, you can still run it standalone with `uv run fastapi dev --port <port>` from within that service's directory — that bypasses the gateway entirely and talks to the service directly, which is fine for isolated debugging but won't be reachable by the app (which only ever calls the gateway's one URL).

## 5. Configure and run the app

```bash
cd application
cp .env.example .env
flutter pub get
flutter run
```

Fill in `application/.env` with the same Supabase URL/key plus the gateway's URL:

```
SUPABASE_URL=https://<project>.supabase.co
SUPABASE_PUBLISHABLE_KEY=<anon key>
API_GATEWAY_URL=http://localhost:8000
```

**If running on a physical phone rather than an emulator — the usual way this app is tested — you must use your machine's LAN IP instead of `localhost`** for `API_GATEWAY_URL`, since the phone can't resolve the dev machine's `localhost`:

```bash
# find your LAN IP
ip addr show | grep 'inet ' | grep -v 127.0.0.1   # Linux
ipconfig getifaddr en0                              # macOS (Wi-Fi)
```

e.g. `API_GATEWAY_URL=http://192.168.1.23:8000`. Also confirm the phone and dev machine are on the same WiFi network, and that the dev machine's firewall allows inbound connections on port 8000 (e.g. on Linux with `ufw` active: `sudo ufw allow 8000/tcp`). See `application/README.md` for ADB pairing steps.

## 6. Run every automated test suite

```bash
for d in packages backend-data-collection backend-ai-training backend-map-management backend-route-management backend-user-management backend-navigation-management backend-positioning; do
  (cd "$d" && uv sync && uv run pytest)
done

cd application && flutter test && flutter analyze
```

## 7. Manual end-to-end walkthrough

1. **Sign up** in the app (creates a Supabase Auth user, then a `profiles` row via `backend-user-management`'s `POST /profiles` with `role_id: 1`).
2. **Promote to admin**: for the very first admin on a fresh project, in Supabase: `UPDATE profiles SET role_id = 2 WHERE id = '<the new user's auth id>';` (there's no in-app flow that can bootstrap the first admin, since there's no admin yet to grant it). Log out and back in. Any *subsequent* admin can instead be promoted from the app itself: sign in as this admin, open the drawer's **Users** tab, and tap the promote icon on their row.
3. **Capture two anchor points** from the admin screen — if you didn't already create a place/building via SQL in step 2, use the floating action button's **Add university** then **Add building** first. Take a photo, pick the building, submit; do this twice in the same building. Open each from **Anchor points** and set its status to **Verified** (this both indexes it into Qdrant and is required for the picker in step 6 — unverified points aren't offered as trip start/end choices).
4. **Connect the two anchor points**: from the drawer, open **Connections** → **Connect on map**, tap one anchor point then the other. This writes an `anchor_point_connections` row — without it, step 6's trip has no walkable path between the two points and `find_or_create` 404s.
5. **Try the user flow as your admin account** via the drawer's **Test as user** entry — or sign up a second, regular user and log in as them, if you'd rather test with a real second account.
6. On the user home screen, tap **Where to?** and pick the second anchor point as the destination (University → Building → anchor point drill-down) — the start point is auto-selected as the verified anchor point nearest your current GPS fix, so make sure you're actually near the first anchor point when you do this. Tap **Find route** — this calls `POST /routes/find_or_create`, which computes a path over the connection from step 4 and creates the route on the fly, then shows it as a guidance line on the map while you navigate.
7. Confirm `navigation_logs` rows accumulate in Supabase roughly every second while the navigation screen stays open (a self-rescheduling loop, not a fixed timer). With a working camera and the verified, indexed anchor points nearby, `corrected_lat`/`corrected_long`/`anchor_match_id`/`confidence_score` populate too; otherwise (no camera on an emulator, no nearby match, `backend-positioning` unreachable) those columns stay `NULL` and only raw GPS is logged for that tick — this is the designed degradation, not a bug.
8. Tap **End navigation** and leave a feedback comment — confirm the session's `status` becomes `completed` and a `user_feedback` row appears.
9. **As the admin**, open the drawer's **Sessions**, pick the user from step 5/6, and open that session — confirm the planned route and the logged trail both draw on the map, and a comment badge appears if feedback was left. Open the drawer's **Feedback** screen and confirm the same comment shows there too.
