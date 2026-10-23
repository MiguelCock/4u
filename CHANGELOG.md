# Changelog

What changed in each release of the Eyes4U app and its backend, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

Each release's section becomes its GitHub release description (`.github/workflows/release.yml` extracts it), so write it for the people who install the app, not for developers. Add an entry under **Unreleased** in each PR. The release PR renames that heading to the new version and date.

## [Unreleased]

### Added
- **New anchor points start from the last one's values**: university, building, type, floor, indoor, lighting and surface. Only the description and position start empty.
- **Filters on anchor points** (admin): by category and type, floor, indoor or outdoor, lighting, and whether they have photos or connections. Works on the list and the map.
- **Session review map** (admin): the raw GPS path and the corrected path drawn separately, photo matches with a line to the point they matched, and details on tap.
- **"✗ Wrong instruction" button** in the admin test flow, to mark wrong guidance. Marks appear on the session map.

## [0.5.0] - 2026-10-22

### Added
- **Anchor points map** (admin): switch the Anchor points list to a map, tap a point to see it and edit, move, verify, connect or add photos. Moving shows exactly where the point will land.
- **Verify / unverify from the list** with one button on each anchor point row.
- **15 new place types**: stationery shop, copy center, store, ATM / bank, library, laboratory, computer room, study area, infirmary, gym / sports area, chapel, exit / gate, bike parking, waiting area and drinking fountain.
- The place type picker is grouped into categories, with a search box. Hallway and outdoor path, the most used, come first.
- A **Floor** field when creating or editing an anchor point (every point used to be saved on the ground floor).

### Changed
- Errors explain what actually happened, for example "this is still used by other data", instead of always saying the server had a problem.
- An anchor point can only be verified once it has at least one photo. Deleting a verified point's last photo puts it back to pending.
- Deactivated universities and buildings are hidden from users.

### Fixed
- **Universities, buildings and anchor points used in a trip could not be deleted**, and a failed delete left the points listed but no longer recognised by the camera. Saved routes through them are now removed with them, and trip history is kept.
- Deactivating a university or building didn't stick: the next edit reactivated it, and the "(inactive)" label never showed.
- Accounts whose profile was missing still couldn't sign in properly. The automatic repair failed.
- Moving an anchor point didn't update the distances used to plan routes.
- Route planning could wrongly say there was no walkable path once there were many connections, and trip trails could be cut short.
- Small form fixes: a distance typed as "12,5", a building's floor count, the map picker following the selected university, and the Connect map recentring when the university changes.

## [0.4.0] - 2026-10-22

### Added
- **Turn-by-turn voice guidance**: the app says which way to face and how far to turn ("Turn right about 90 degrees"), confirms when you're facing the right way ("Start walking forward, 15 meters"), and corrects you if you drift off course.
- **Automatic arrival**: reaching the destination announces it and finishes the trip without pressing End.
- **Voice destination search**: tap "Say where you want to go" and say the place, e.g. "quiero ir a la cafetería". If several places match, the app asks which one.
- **Delete connections on the map**: tap a connection line on the Connect map to delete it. Saved routes that used it are recalculated.
- **Re-index verified points** (admin menu): re-sends verified points to photo search, for points verified while indexing was failing.
- **Pull down to refresh** on every list.
- **Back button** steps back through admin sections and filters, then asks "press back again to exit".
- **Unfinished trips**: if the app was closed during a trip, it asks next time whether to continue it or finish it.
- **Check the starting point on demand**: tap the Start row. The check now takes several photos (about 6–10 seconds, turning slowly), which makes it much more accurate, and it says how many photos matched a known place.
- **The signup confirmation email opens the app** and signs you in, instead of a broken localhost page.

### Changed
- **Destinations vs in-between points**: classrooms, entrances, restrooms and other destination types need a description. Hallways, intersections and similar points can be saved without one and never appear as destinations. New points start as "hallway".
- Spoken directions are short and direction-only. Hallway points are never named.
- Navigation speaks in the app's language with a native voice, even when the phone is set to another language.
- Selecting points on the Connect map is instant and forgiving: a tap near a dot counts, with a vibration. Quick chains of taps are no longer lost.
- Admin tips (order of work, row tap to connect) moved from the app into the admin guide.

### Fixed
- Pull-to-refresh did nothing on the admin screen, and the refresh button reloaded with no visible spinner.
- Signing up with email confirmation failed with a "missing bearer token" error.
- **"Session expired" when indexing a verified point**, even after signing in again. The server was reporting its own configuration problem as an expired session. It now gives an honest error, and the configuration is fixed.
- **Coordinates lost precision when saved**: longitudes were rounded to about 0.85 m, so points lined up in parallel. Coordinates are now stored at full precision. Existing points keep their rounded position until moved.
- Map pins were drawn about 17 pixels south of their real position.
- The "+" button covered the last row's delete button in admin lists.
- The destination list showed each place's description twice.

### Removed
- The old data-collection camera screen and its button in the user view.

## [0.3.1] - 2026-10-21

### Added
- The route's starting point is shown on the home screen. It's confirmed with one camera photo (visual correction) when you tap Find route, instead of raw GPS alone.
- Tap the map during navigation to hear the last instruction again.
- Tapping an anchor point in the admin list opens the connection map, zoomed in with that point selected.
- A confirmation appears when an anchor point is created.
- Admins can find and repair accounts that signed up but have no profile, so they can be promoted.

### Changed
- Error messages are in plain language ("couldn't reach the server", "your session expired") instead of raw server text.
- The destination picker no longer offers the starting point.
- The navigation map zooms to the route when the trip starts.

### Fixed
- "Missing bearer token" / "invalid or expired token" errors after the phone was locked or the app was in the background. The app now refreshes the session and retries.
- Spinners that never stopped when the connection dropped.

## [0.3.0] - 2026-10-14

### Added
- Spoken announcements (text-to-speech) and haptic feedback during navigation, with a voice-guidance setting.
- Camera use is announced at the start of navigation, and a covered camera is detected and announced.
- Visual search only compares nearby anchor points (geo-scoped), which makes it faster and more accurate.

### Changed
- Admin building and anchor point screens are easier to use.
- Screen-reader (TalkBack) support is extended across the user screens.

## [0.2.1] - 2026-10-07

### Fixed
- Accounts whose profile wasn't created at signup are repaired automatically at the next sign-in, instead of being stuck unable to load settings or be promoted.

## [0.2.0] - 2026-10-07

### Added
- **GPS correction during navigation**: the camera is matched against anchor-point photos and fused with GPS (Kalman filter) to correct your position.
- **Trip planning**: pick only the destination. The nearest anchor point is chosen as the start and a walking route is computed from the connections.
- Live tracking of navigation sessions for admins, with the route drawn on the map.
- Settings: language (English/Spanish), high contrast, text size and verbosity.
- Admin user management (promote/demote) and a "test as user" mode.
- Feedback after each trip, visible to admins.
- Clear screens for location-permission problems instead of an endless spinner.

### Changed
- Every backend service now checks who is calling. Only admins can change map data.

### Fixed
- When the server was unreachable, it looked like a login problem. The app now shows an error with a Retry button.
- Backend services restart automatically after a crash.

## [0.1.0] - 2026-10-02

First release.

### Added
- Sign up and log in, with separate user and admin views.
- Admins can create universities, buildings and anchor points (with photos facing several directions), review and verify them, and connect them into a walkable network.
- Admin map picker showing existing places, buildings and anchor points.
- Anchor-point photos are indexed for visual search (EfficientNet-B0 embeddings in Qdrant).
- One HTTPS gateway in front of all backend services, and a signed Android release built by CI.
- Bilingual (English/Spanish) admin guide.

[Unreleased]: https://github.com/MiguelCock/4u/compare/v0.5.0...develop
[0.5.0]: https://github.com/MiguelCock/4u/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/MiguelCock/4u/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/MiguelCock/4u/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/MiguelCock/4u/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/MiguelCock/4u/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/MiguelCock/4u/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/MiguelCock/4u/releases/tag/v0.1.0
