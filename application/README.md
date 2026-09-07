# application

Flutter mobile app for the GPS positioning correction system — a single codebase serving both the `user` role (sends photo + GPS + IMU while navigating, receives a corrected position) and the `admin` role (captures anchor point photos with exact coordinates at strategic campus locations).

## Setup

```bash
cp .env.example .env   # fill in BACKEND_URL
flutter pub get
```

Camera and location permissions are declared in `android/app/src/main/AndroidManifest.xml`.

## Run

```bash
flutter run
```

Currently `lib/main.dart` shows all functionality on a single screen — live location info, a camera preview with a capture button, and a map centered on the device's current position — rather than separate `user`/`admin` screens/navigation.

### Manual usage

1. Launch the app on a device or emulator with location services enabled.
2. Grant location and camera permissions when prompted.
3. The top panel shows the live GPS fix (lat/lng/accuracy), updating as `LocationService` streams new positions.
4. The map panel re-centers on each position update.
5. Tap the camera button to take a photo; it's uploaded (multipart: file field `image`, plus `latitude`/`longitude`/`accuracy` form fields) to the backend URL hardcoded in `lib/camera.dart` — see the **Known gaps** note below before expecting this to reach your local backend.

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

`test/widget_test.dart` is currently just a sanity smoke test so CI has something to run — add real widget/unit tests alongside new widgets/services.

## Known gaps

- `lib/camera.dart`'s upload call is hardcoded to `http://10.10.79.249:3000/upload` instead of reading `BACKEND_URL` from `.env` — update it to point at whichever backend service you're running (`backend-data-collection` by default) before testing photo upload end-to-end.
- No role-based (`user` vs `admin`) navigation exists yet.

## Keeping dependencies up to date

```bash
flutter pub outdated
flutter pub upgrade --major-versions
```
