/// Shared tile source for every `flutter_map` usage in the app (map.dart,
/// admin/location_picker_screen.dart) - kept in one place so it's never
/// hand-copied out of sync again. Uses the official OpenStreetMap.org tile
/// server rather than the OpenStreetMap France "hot" mirror - that mirror
/// enforces its own usage policy and started rejecting requests from an
/// actively-used, live-tracking map app with a "does not respect ... base
/// map usage policy" placeholder tile instead of real map tiles.
const String kMapTileUrlTemplate =
    'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const String kMapUserAgentPackageName = 'com.example.application';
