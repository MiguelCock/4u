# application

Flutter mobile app for the GPS positioning correction system — a single codebase serving both the `user` role (sends photo + GPS + IMU while navigating, receives a corrected position) and the `admin` role (captures anchor point photos with exact coordinates at strategic campus locations).

## Setup

```bash
cp .env.example .env   # fill in every value below
flutter pub get
```

`.env` needs:

| Variable | Purpose |
|---|---|
| `SUPABASE_URL` / `SUPABASE_PUBLISHABLE_KEY` | Supabase Auth (login/signup) — same project the backend services use |
| `BACKEND_URL` | `backend-data-collection` (photo upload) |
| `MAP_MANAGEMENT_URL` | `backend-map-management` (buildings/anchor points) |
| `ROUTE_MANAGEMENT_URL` | `backend-route-management` (routes) |
| `USER_MANAGEMENT_URL` | `backend-user-management` (profiles/roles) |
| `NAVIGATION_MANAGEMENT_URL` | `backend-navigation-management` (sessions/logs/feedback) |

Camera and location permissions are declared in `android/app/src/main/AndroidManifest.xml`.

## Run

```bash
flutter run
```

On start, the app loads `.env`, initializes the Supabase Auth client, then shows `AuthGate`: a login/signup screen if signed out, or the role-appropriate home screen (`UserHomeScreen`/`AdminHomeScreen`, from `backend-user-management`'s `profiles.role_id`) if signed in.

### Manual usage

1. Launch the app. If not signed in, use **Sign up** (creates a Supabase Auth account, then a matching `profiles` row via `backend-user-management`'s `POST /profiles` — defaults to the `user` role) or **Log in**.
2. Once signed in as `user`, you land on the original single-screen prototype: live location info, a camera preview with a capture button, and a map centered on the device's current position.
3. The top panel shows the live GPS fix (lat/lng/accuracy), updating as `LocationService` streams new positions.
4. The map panel re-centers on each position update.
5. Tap the camera button to take a photo; it's uploaded (multipart: file field `image`, plus `latitude`/`longitude`/`accuracy` form fields) to `BACKEND_URL` — see the **Known gaps** note below, this URL is still hardcoded in `lib/camera.dart` rather than actually reading `.env` yet.
6. Signing in as `admin` (a profile with `role_id: 2`, set by hand in Supabase for now — there's no admin-invite flow) shows a placeholder admin screen; the real anchor-point capture flow is a separate follow-up.

### Running on a physical device (ADB)

Enable **Developer Options** on your phone:
- Go to Settings and scroll to the bottom.
- Under **About phone**, find **Build Number** and tap it repeatedly to enable developer settings.

**To connect through cable:**
- Go to **Developer Options** → **USB debugging** and turn it on.

**To connect wirelessly:**
- Make sure your phone and PC are on the same Wi-Fi network.
- Go to **Developer Options** → **Wireless debugging** and turn it on.
- Open Wireless debugging → **Pair device with pairing code**.
- On your PC, run:
```bash
adb pair IP_ADDRESS:PAIRING_PORT PAIR_CODE
```
- Then connect:
```bash
adb connect IP_ADDRESS:ADB_PORT
```

Verify:
```bash
adb devices
```

## Testing

```bash
flutter test
flutter analyze
```

`test/widget_test.dart` is currently just a sanity smoke test so CI has something to run — add real widget/unit tests alongside new widgets/services. CI copies `.env.example` to `.env` before running tests, since `pubspec.yaml` declares `.env` as an asset (`flutter_dotenv`) and Flutter's asset bundling needs the file to exist even with placeholder values.

## Known gaps

- `lib/camera.dart`'s upload call is still hardcoded to `http://10.10.79.249:3000/upload` instead of reading `BACKEND_URL` from `.env` — the app now loads `.env` at startup (for Supabase Auth and the other services' base URLs), but this one call hasn't been switched over yet.
- The admin home screen is a placeholder — the real anchor-point capture flow (camera + building/location-type pickers + image upload) isn't built yet.
- No route list / navigation-session flow yet on the `user` side beyond the original photo/location/map prototype.
- `AuthGate` falls back to the `user` home screen if the `profiles` fetch fails for any reason (backend down, profile row missing) rather than showing an explicit error state.

## Keeping dependencies up to date

```bash
flutter pub outdated
flutter pub upgrade --major-versions
```
