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

Single Flutter codebase serving two roles from the root README's design: `user` (sends live photo+GPS+IMU, receives a corrected position for navigation) and `admin` (captures anchor point photos with exact coordinates). `lib/main.dart` now loads `.env` (`flutter_dotenv`), initializes Supabase Auth, and shows `AuthGate` — real login/signup and role branching, on top of the original single-screen prototype (`LocationInfo`/`SimpleCameraWidget`/`SimpleMapWidget`, now under `lib/user/user_home_screen.dart`). The admin side now has a real capture flow (`lib/admin/capture_screen.dart`, reachable from `lib/admin/admin_home_screen.dart`'s anchor-point list). No route list/navigation-session UI yet on the `user` side, and no display of a corrected position anywhere in `lib/` (that pipeline doesn't exist in any backend service — see `backend-ai-training/CLAUDE.md`).

## How it connects to the rest of the system

`lib/services/api_service.dart` gives the app real HTTP clients for every backend service, each reading its base URL from `.env`: `UserManagementApi`, `MapManagementApi`, `RouteManagementApi`, `NavigationManagementApi` (plus the pre-existing hardcoded call to `backend-data-collection`, see below). This is a change from before — previously the app had zero configured network clients beyond the one hardcoded upload call.

- **Auth**: `lib/auth/signup_screen.dart` calls Supabase Auth's `signUp`, then `UserManagementApi().post('/profiles', ...)` with the new auth user's id and `role_id: 1` (`user`) — the real trigger for `backend-user-management`'s `POST /profiles` that every service's `CLAUDE.md` previously described as "nothing calls this." `login_screen.dart` calls `signInWithPassword`. Both rely on `AuthGate`'s `Supabase.instance.client.auth.onAuthStateChange` listener to react to the resulting session change, rather than navigating manually.
- **Role routing**: `AuthGate` fetches `GET /profiles/{id}` (`backend-user-management`) for the signed-in user and shows `AdminHomeScreen` if `role_id == 2`, else `UserHomeScreen` — matching `db_schema/roles.sql`'s seeded `user`/`admin` ids (hardcoded as `kUserRoleId`/`kAdminRoleId` rather than fetched, since `roles` has no reason to change at runtime).
- **Photo upload**: unchanged mechanism (`SimpleCameraWidget._sendPhotoToServer`, still a hardcoded URL rather than reading `BACKEND_URL` — see Known gaps), but the multipart field name now matches `backend-data-collection`'s parameter (`image`) since that service's `POST /upload` signature was fixed.
- **Anchor-point capture**: `lib/admin/capture_screen.dart` is the real client for `backend-map-management`'s new `POST /anchor-points/upload-image` (via `MapManagementApi.postMultipart`, added alongside this screen) and `POST /anchor-points`, using the signed-in admin's id as `captured_by` — the field `backend-map-management/CLAUDE.md` previously flagged as missing from the model, and the image-upload step that same file noted nothing provided. `admin_home_screen.dart` lists existing anchor points via `GET /anchor-points`.
- **Not yet wired**: `RouteManagementApi`/`NavigationManagementApi` exist as clients but nothing calls them yet — the user route/navigation screens are follow-up work that will use them.

## Complete workflow

1. **App start** — `main()` loads `.env` (falling back to `dotenv.testLoad(fileInput: '')` if missing, e.g. in a test run, so the app doesn't crash without a real `.env`), initializes `Supabase.initialize(...)` with `SUPABASE_URL`/`SUPABASE_PUBLISHABLE_KEY` (falling back to harmless placeholder values if unset — Supabase's client doesn't validate reachability at init time), then `LocationService().initialize()`, then shows `AuthGate`.
2. **`AuthGate`** — if `Supabase.instance.client.auth.currentSession` is null, shows `LoginScreen` (with a link to `SignupScreen`). If signed in, fetches the user's profile and routes to `AdminHomeScreen` or `UserHomeScreen` based on `role_id`; if the profile fetch throws for any reason, falls back to `UserHomeScreen` rather than showing an error state (see Known gaps).
3. **Sign up** — email/password → Supabase Auth `signUp` → on success, `POST /profiles` with the new user's id. If the profile call fails, the auth account still exists (shown as an error in the UI, not rolled back) — there's no compensating transaction.
4. **`UserHomeScreen`** — the original prototype: `LocationInfo`/`SimpleCameraWidget`/`SimpleMapWidget`, all independently subscribed to `LocationService`'s broadcast stream (unchanged from before — see the widget-level docs below), plus a logout button.
5. **Capture** — tapping `SimpleCameraWidget`'s button takes a photo, reads `LocationService().lastPosition`, and POSTs multipart (file field `image` + `latitude`/`longitude`/`accuracy`) to the still-hardcoded URL in `camera.dart`.
6. **`AdminHomeScreen`** — `GET /anchor-points` (`backend-map-management`), listed by description/status; a floating action button opens `CaptureScreen` and refreshes the list on return.
7. **`CaptureScreen`** — camera preview + capture (same `CameraController` pattern as `SimpleCameraWidget`), a building dropdown (`GET /buildings`), a hardcoded `location_type` dropdown (matching `db_schema/location_type.sql`'s seeded values — no CRUD endpoint exists for that table, same reasoning as the hardcoded role ids), and an optional description field. On submit: uploads the photo via `POST /anchor-points/upload-image`, then `POST /anchor-points` with the returned `image_url`, the form fields, the device's current position (`LocationService().lastPosition`), and `captured_by` set to `Supabase.instance.client.auth.currentUser!.id`.

### Widget/service internals (unchanged from before)

- `lib/services/location_service.dart` — singleton wrapping `Geolocator`; exposes a broadcast `Stream<Position>` (`positionStream`) and a cached `lastPosition`. Widgets subscribe to the stream independently rather than receiving position via a shared parent widget — follow this pattern (thread through `LocationService`, not widget constructors) for any new widget that needs live position.
- `lib/camera.dart`'s `_sendPhotoToServer` still POSTs directly to a hardcoded URL rather than using `BACKEND_URL` from `.env` (see Known gaps).

## Known gaps

- `lib/camera.dart`'s upload call is still hardcoded to `http://10.10.79.249:3000/upload` instead of reading `BACKEND_URL` — the app now loads `.env` for everything else, but this one call hasn't been switched over.
- User route list/navigation-session screens and any corrected-position display are still unbuilt — `RouteManagementApi`/`NavigationManagementApi` are ready clients waiting for screens to use them.
- `AuthGate` has no explicit "profile fetch failed" UI state — it silently treats that the same as a `user` role.
- `CaptureScreen` doesn't validate that a building was actually seeded before offering it in the dropdown (an empty `_buildings` list just shows an empty dropdown), and there's no way to add a building from the app — `places`/`buildings` still have to be seeded by hand (see `backend-map-management/CLAUDE.md`).
- `test/widget_test.dart` is currently just a sanity smoke test so CI has something to run — add real widget/unit tests alongside new widgets/services. A full auth-flow test isn't practical without a mocked Supabase client, so none exists yet.
