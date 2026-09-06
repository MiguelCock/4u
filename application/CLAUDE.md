# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

See the repo root `CLAUDE.md` for overall project context.

## Commands

```bash
flutter pub get
flutter run
flutter test
flutter analyze              # uses analysis_options.yaml (package:flutter_lints/flutter.yaml)
```

See `README.md` for ADB device-pairing steps (wired and wireless) and the full `.env` variable list.

## What this app does

Single Flutter codebase serving two roles from the root README's design: `user` (sends live photo+GPS+IMU, receives a corrected position for navigation) and `admin` (captures anchor point photos with exact coordinates). `lib/main.dart` now loads `.env` (`flutter_dotenv`), initializes Supabase Auth, and shows `AuthGate` — real login/signup and role branching, on top of the original single-screen prototype (`LocationInfo`/`SimpleCameraWidget`/`SimpleMapWidget`, now under `lib/user/user_home_screen.dart`). The `user` side now also has a route list and navigation-session flow (`lib/user/route_list_screen.dart`, `navigation_screen.dart`). The admin side is still a placeholder screen (`lib/admin/admin_home_screen.dart`) — no anchor-point capture UI yet (separate follow-up). No display of a corrected position anywhere in `lib/` (that pipeline doesn't exist in any backend service — see `backend-ai-training/CLAUDE.md`); navigation logs raw GPS only.

## How it connects to the rest of the system

`lib/services/api_service.dart` gives the app real HTTP clients for every backend service, each reading its base URL from `.env`: `UserManagementApi`, `MapManagementApi`, `RouteManagementApi`, `NavigationManagementApi` (plus the pre-existing hardcoded call to `backend-data-collection`, see below). This is a change from before — previously the app had zero configured network clients beyond the one hardcoded upload call.

- **Auth**: `lib/auth/signup_screen.dart` calls Supabase Auth's `signUp`, then `UserManagementApi().post('/profiles', ...)` with the new auth user's id and `role_id: 1` (`user`) — the real trigger for `backend-user-management`'s `POST /profiles` that every service's `CLAUDE.md` previously described as "nothing calls this." `login_screen.dart` calls `signInWithPassword`. Both rely on `AuthGate`'s `Supabase.instance.client.auth.onAuthStateChange` listener to react to the resulting session change, rather than navigating manually.
- **Role routing**: `AuthGate` fetches `GET /profiles/{id}` (`backend-user-management`) for the signed-in user and shows `AdminHomeScreen` if `role_id == 2`, else `UserHomeScreen` — matching `db_schema/roles.sql`'s seeded `user`/`admin` ids (hardcoded as `kUserRoleId`/`kAdminRoleId` rather than fetched, since `roles` has no reason to change at runtime).
- **Photo upload**: unchanged mechanism (`SimpleCameraWidget._sendPhotoToServer`, still a hardcoded URL rather than reading `BACKEND_URL` — see Known gaps), but the multipart field name now matches `backend-data-collection`'s parameter (`image`) since that service's `POST /upload` signature was fixed.
- **Route list / navigation**: `lib/user/route_list_screen.dart` is the real client for `backend-route-management`'s `GET /routes`. `navigation_screen.dart` is the real client for `backend-navigation-management`: `POST /sessions` on start, a `Timer.periodic` `POST /logs` every 5s with raw GPS (no `corrected_*` fields — no correction pipeline exists, see `backend-navigation-management/CLAUDE.md`), `PATCH /sessions/{id}` on end, and an optional `POST /feedback` from a post-session dialog. This is the first real caller of every one of those endpoints.
- **Not yet wired**: `MapManagementApi` exists as a client but the admin capture screen that would use it is a separate follow-up.

## Complete workflow

1. **App start** — `main()` loads `.env` (falling back to `dotenv.testLoad(fileInput: '')` if missing, e.g. in a test run, so the app doesn't crash without a real `.env`), initializes `Supabase.initialize(...)` with `SUPABASE_URL`/`SUPABASE_PUBLISHABLE_KEY` (falling back to harmless placeholder values if unset — Supabase's client doesn't validate reachability at init time), then `LocationService().initialize()`, then shows `AuthGate`.
2. **`AuthGate`** — if `Supabase.instance.client.auth.currentSession` is null, shows `LoginScreen` (with a link to `SignupScreen`). If signed in, fetches the user's profile and routes to `AdminHomeScreen` or `UserHomeScreen` based on `role_id`; if the profile fetch throws for any reason, falls back to `UserHomeScreen` rather than showing an error state (see Known gaps).
3. **Sign up** — email/password → Supabase Auth `signUp` → on success, `POST /profiles` with the new user's id. If the profile call fails, the auth account still exists (shown as an error in the UI, not rolled back) — there's no compensating transaction.
4. **`UserHomeScreen`** — the original prototype: `LocationInfo`/`SimpleCameraWidget`/`SimpleMapWidget`, all independently subscribed to `LocationService`'s broadcast stream (unchanged from before — see the widget-level docs below), plus a logout button and a "Navigate" FAB into `RouteListScreen`.
5. **Capture** — tapping `SimpleCameraWidget`'s button takes a photo, reads `LocationService().lastPosition`, and POSTs multipart (file field `image` + `latitude`/`longitude`/`accuracy`) to the still-hardcoded URL in `camera.dart`.
6. **`RouteListScreen`** — `GET /routes`, listed with a "Start" button per route that pushes `NavigationScreen(route: ...)`.
7. **`NavigationScreen`** — on entry, `POST /sessions` with the signed-in user's id, the route's `building_id`, and its own id as `route_id`; keeps the returned session id in state and starts a 5-second `Timer.periodic` posting `POST /logs` with the current `LocationService().lastPosition` (raw `gps_lat`/`gps_long`/`gps_accuracy`/`heading` only — `corrected_*`/`anchor_match_id`/`confidence_score` are omitted, since nothing computes them). Shows `LocationInfo`/`SimpleMapWidget` while active. On "End navigation": cancels the timer, `PATCH /sessions/{id}` with `status: "completed"`/`end_time`/`end_position`, then a dialog offers to `POST /feedback` before popping back. Session-end and log-tick failures are swallowed (best-effort) rather than blocking the user from leaving the screen.
8. **`AdminHomeScreen`** — placeholder; just proves an admin-role profile reaches a different screen than a user-role one.

### Widget/service internals (unchanged from before)

- `lib/services/location_service.dart` — singleton wrapping `Geolocator`; exposes a broadcast `Stream<Position>` (`positionStream`) and a cached `lastPosition`. Widgets subscribe to the stream independently rather than receiving position via a shared parent widget — follow this pattern (thread through `LocationService`, not widget constructors) for any new widget that needs live position.
- `lib/camera.dart`'s `_sendPhotoToServer` still POSTs directly to a hardcoded URL rather than using `BACKEND_URL` from `.env` (see Known gaps).

## Known gaps

- `lib/camera.dart`'s upload call is still hardcoded to `http://10.10.79.249:3000/upload` instead of reading `BACKEND_URL` — the app now loads `.env` for everything else, but this one call hasn't been switched over.
- Admin anchor-point capture is still unbuilt — `MapManagementApi` is a ready client waiting for a screen to use it.
- `AuthGate` has no explicit "profile fetch failed" UI state — it silently treats that the same as a `user` role.
- `NavigationScreen` doesn't validate the route has valid `building_id`/anchor references before starting a session, and doesn't handle losing GPS mid-session beyond simply not logging that tick.
- `test/widget_test.dart` is currently just a sanity smoke test so CI has something to run — add real widget/unit tests alongside new widgets/services. A full auth-flow test isn't practical without a mocked Supabase client, so none exists yet.
