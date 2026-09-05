# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

See the repo root `CLAUDE.md` for overall project context. This is the Flutter mobile app — single codebase serving both the `user` role (sends photo+GPS+IMU, receives corrected position) and the `admin` role (captures anchor points).

## Commands

```bash
flutter pub get
flutter run
flutter test
flutter analyze              # uses analysis_options.yaml (package:flutter_lints/flutter.yaml)
```

See `README.md` for ADB device-pairing steps (wired and wireless).

## Structure

- `lib/main.dart` — composes three independent widgets, all driven by the singleton `LocationService`: `LocationInfo` (`lib/location.dart`), `SimpleCameraWidget` (`lib/camera.dart`), `SimpleMapWidget` (`lib/map.dart`).
- `lib/services/location_service.dart` — singleton wrapping `Geolocator`; exposes a broadcast `Stream<Position>` (`positionStream`) and a cached `lastPosition`. Widgets subscribe to the stream independently rather than receiving position via a shared parent widget — follow this pattern rather than threading position through widget constructors.
- No role-based navigation/routing exists yet — `admin` vs `user` screens described in the root README are not yet implemented; `main.dart` currently just stacks all three widgets on one screen.

## Known gaps

- `lib/camera.dart`'s `_sendPhotoToServer` POSTs directly to a hardcoded URL (`http://10.10.79.249:3000/upload`) instead of using the `BACKEND_URL` env var declared in `.env.example`. Check whether this still needs wiring up before treating networking code as done.
- No `flutter_test` widget/unit tests exist yet under `test/` — add them alongside new widgets/services rather than leaving them uncovered (see root CLAUDE.md's testing expectations).
