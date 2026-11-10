// Loads the app without registering a service worker: an offline cache kept
// serving an old admin app after a deploy (see docs/SETUP.md, "No offline
// cache"). The gateway answers the old worker's address with one that
// removes it.
{{flutter_js}}
{{flutter_build_config}}
_flutter.loader.load();
