import 'package:flutter/material.dart';

/// App-wide, in-memory holders for the two preferences that need to change
/// the running app immediately (not just persist server-side): high
/// contrast and language. `AuthGate` sets both once from the signed-in
/// user's already-fetched profile; `SettingsScreen` updates them again on
/// save. `MainApp` (`lib/main.dart`) listens to both via
/// `ValueListenableBuilder` to pick `ThemeData`/`MaterialApp.locale`.
///
/// Deliberately not persisted locally (e.g. SharedPreferences) - the
/// source of truth is `profiles.preferences` server-side; these notifiers
/// are just the in-memory mirror of it for the current app session.
final ValueNotifier<bool> highContrastNotifier = ValueNotifier<bool>(false);

/// `null` means "follow the device locale" (Flutter's default resolution
/// when `MaterialApp.locale` is left unset); a non-null value forces that
/// language regardless of device locale.
final ValueNotifier<Locale?> localeNotifier = ValueNotifier<Locale?>(null);

/// Reads `high_contrast`/`language` out of a `profiles.preferences` map
/// (as returned by `GET /profiles/{id}`) and applies them to the notifiers
/// above. `defaultHighContrast` is the OS-level signal
/// (`MediaQuery.of(context).highContrast`), used only when the preference
/// has never been explicitly set.
void applyPreferences(
  Map<String, dynamic>? preferences, {
  required bool defaultHighContrast,
}) {
  final prefs = preferences ?? const {};
  highContrastNotifier.value =
      prefs['high_contrast'] as bool? ?? defaultHighContrast;
  final language = prefs['language'] as String?;
  localeNotifier.value = switch (language) {
    'en' => const Locale('en'),
    'es' => const Locale('es'),
    _ => null,
  };
}
