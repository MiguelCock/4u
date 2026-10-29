# application

Flutter app for the GPS positioning correction system — a single codebase serving both the `user` role (sends a photo + GPS while navigating, gets a corrected position and spoken guidance; the gyroscope and walking direction give the heading) and the `admin` role (captures anchor point photos with exact coordinates at strategic campus locations). The same code also builds the admin-only web app (`flutter build web --base-href /admin/`, see [`docs/SETUP.md`](../docs/SETUP.md) §5b).

## Setup

For the full multi-service setup (Supabase project, schema, Storage buckets, running all 7 backend services), see [`docs/SETUP.md`](../docs/SETUP.md). This section covers just the app's own `.env`.

```bash
cp .env.example .env   # fill in every value below
flutter pub get
```

`.env` needs:

| Variable | Purpose |
|---|---|
| `SUPABASE_URL` / `SUPABASE_PUBLISHABLE_KEY` | Supabase Auth (login/signup) — same project the backend services use |
| `API_GATEWAY_URL` | Base URL of the API gateway in front of all 7 backend services (see root README) — each service is reached at its own path prefix (`/data-collection`, `/map`, `/route`, `/user`, `/navigation`, `/ai-training`, `/positioning`) |

Camera and location permissions are declared in `android/app/src/main/AndroidManifest.xml`.

## Run

```bash
flutter run
```

On start, the app loads `.env`, initializes the Supabase Auth client, then shows `AuthGate`: a login/signup screen if signed out, or the role-appropriate home screen (`UserHomeScreen`/`AdminHomeScreen`, from `backend-user-management`'s `profiles.role_id`) if signed in.

### Manual usage

> For a full admin walkthrough (adding places, buildings, anchor points, photos, verification, and connections), see [`docs/admin-guide/`](../docs/admin-guide/README.md) — the steps below are a quick developer smoke test, not the full admin flow.

1. Launch the app. If not signed in, use **Sign up** (creates a Supabase Auth account, then a matching `profiles` row via `backend-user-management`'s `POST /profiles` — defaults to the `user` role) or **Log in**. On first launch a user hears the spoken tutorial (the **?** button replays it).
2. Signed in as `user`: say a destination with **Say where you want to go**, or pick it under **Where to?**. Confirm with **Start route** in the "Go to X?" dialog. The start point is the verified anchor point nearest your GPS fix, and the route comes from `backend-route-management`'s `POST /routes/find_or_create`.
3. Navigation: guidance is spoken (in steps, without degrees), the camera sends a photo to `backend-positioning` about every 1–2 s, and each tick is logged to `backend-navigation-management`. Users see a large **Repeat instruction** button and **End navigation**. Ending offers optional feedback.
4. Signed in as `admin` (a profile with `role_id: 2`, set by hand in Supabase for the very first one, then promoted from the Users tab): the admin home with universities, buildings, anchor points, connections and users. **Test as user** in the menu runs the user flow with the map, coordinates, checkpoints and the wrong-instruction button (see the admin guide §6b).

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

Unit tests for the pure logic live in `test/services/` (guidance, heading, geometry, version policy, location recovery...); `test/widget_test.dart` is a smoke test — add tests alongside new widgets/services. CI copies `.env.example` to `.env` before running tests, since `pubspec.yaml` declares `.env` as an asset (`flutter_dotenv`) and Flutter's asset bundling needs the file to exist even with placeholder values.

## Known gaps

- The building dropdown in the admin capture screen is empty until at least one `buildings` row exists — add a university and a building first (their own sections' **+** button).
- `AuthGate` self-heals a missing `profiles` row (creates one on the spot) but still shows a generic error+retry screen for any other backend failure, rather than a more specific message per failure mode.
- A route needs `building_id`/`start_anchor_id`/`end_anchor_id` already pointing at real rows for navigation to make sense — nothing in the app validates this before starting a session.

## Keeping dependencies up to date

```bash
flutter pub outdated
flutter pub upgrade --major-versions
```
