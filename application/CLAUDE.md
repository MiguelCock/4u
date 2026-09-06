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

See `README.md` for ADB device-pairing steps (wired and wireless).

## What this app does

Single Flutter codebase meant to serve two roles from the root README's design: `user` (sends live photo+GPS+IMU, receives a corrected position for navigation) and `admin` (captures anchor point photos with exact coordinates). In practice, only a thin slice of the `user` side exists today: `lib/main.dart`'s `MainApp` stacks three widgets on one screen with no role branching, no login, and no navigation/routing between screens — `LocationInfo` (`lib/location.dart`, shows live lat/lng/accuracy), `SimpleCameraWidget` (`lib/camera.dart`, camera preview + capture button), and `SimpleMapWidget` (`lib/map.dart`, OpenStreetMap tile layer centered on the device). There is no `admin` UI, no signup/login screen, no route display, and no display of a corrected position anywhere in `lib/`.

## How it connects to the rest of the system

This is the only component in the repo with a real intended network call to another component — every backend service otherwise only talks to Supabase directly (see each service's own `CLAUDE.md`). That one call is `SimpleCameraWidget._sendPhotoToServer`, a multipart POST to `backend-data-collection`'s `POST /upload` (file field `image`, form fields `latitude`/`longitude`/`accuracy` — both sides now agree on this shape). One break remains: the URL is still hardcoded to `http://10.10.79.249:3000/upload` in `camera.dart` instead of reading `BACKEND_URL` from `.env` — there's no `.env`-loading mechanism in the app at all yet (no `flutter_dotenv` or equivalent), so changing `.env` currently has no effect on where photos go regardless of what it contains.

Every other piece of the intended system is currently just aspirational relative to this app's code: the admin-role anchor-point capture screen would be the client for `backend-map-management`'s `POST /anchor-points`; a login/signup screen would be what triggers `backend-user-management`'s `POST /profiles` after Supabase Auth creates a user; a route list/navigation screen would read from `backend-route-management`; and a "corrected position" display would come from the real-time inference pipeline described in the root README (OpenCV → PyTorch → Qdrant → Kalman filter), which doesn't exist in any backend service yet. None of these have any code in `lib/` today.

## Complete workflow

1. **App start** — `main()` calls `WidgetsFlutterBinding.ensureInitialized()` then `LocationService().initialize()` *before* `runApp`, so the singleton's location-permission flow and first GPS fix happen before any widget builds.
2. **`LocationService.initialize()`** — checks/requests location permission via `Geolocator`, fetches one `getCurrentPosition()` fix, then subscribes to `Geolocator.getPositionStream(...)` (best-for-navigation accuracy, 1m distance filter, 1s interval) and pushes every update into a broadcast `StreamController<Position>`, also caching it as `lastPosition`.
3. **Widget subscriptions** — `LocationInfo`, `SimpleCameraWidget`, and `SimpleMapWidget` each independently call `LocationService().positionStream.listen(...)` in `initState` and `setState` on every tick; there's no shared parent-widget state — this is the pattern to follow for any new widget that needs live position (thread it through `LocationService`, not widget constructors).
4. **Capture** — tapping `SimpleCameraWidget`'s button calls `_takePhoto()`, which takes a picture via `CameraController`, reads `LocationService().lastPosition` (bails with a snackbar if null), and calls `_sendPhotoToServer(image, position)`.
5. **Upload attempt** — builds a multipart POST (file field `image` + `latitude`/`longitude`/`accuracy` form fields) to the hardcoded URL and shows a success/failure snackbar based on the HTTP status. Against a `backend-data-collection` instance actually running at that hardcoded address, this now works end-to-end; against anything else, it silently goes nowhere until the URL is made configurable.

## Known gaps

- The hardcoded upload URL (see above) — no env-var loading exists in the app yet.
- No role-based (`user` vs `admin`) navigation, login/signup, or route/corrected-position display exists yet.
- `test/widget_test.dart` is currently just a sanity smoke test so CI has something to run — add real widget/unit tests alongside new widgets/services.
