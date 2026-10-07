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

/// Multiplies every `TextStyle`'s font size app-wide (`MainApp`'s
/// `MaterialApp.builder` applies it via a `MediaQuery.textScaler`
/// override) - 1.0 is normal size.
final ValueNotifier<double> textScaleNotifier = ValueNotifier<double>(1.0);

/// Whether `NavigationScreen` should speak announcements (route start,
/// waypoint proximity, arrival, end-of-session) via `flutter_tts` - the
/// voice toggle #85 deferred until there was TTS to back it. Defaults to
/// on, unlike the others above which default from an OS-level signal -
/// there's no equivalent OS signal for "wants spoken navigation", so a
/// sensible fixed default for this app's audience is on until turned off.
final ValueNotifier<bool> voiceGuidanceNotifier = ValueNotifier<bool>(true);

/// Reads `high_contrast`/`language`/`font_scale`/`voice_guidance` out of a
/// `profiles.preferences` map (as returned by `GET /profiles/{id}`) and
/// applies them to the notifiers above. `defaultHighContrast` and
/// `defaultTextScale` are OS-level signals
/// (`MediaQuery.of(context).highContrast`/`textScaler.scale(1.0)`), used
/// only when the corresponding preference has never been explicitly set.
void applyPreferences(
  Map<String, dynamic>? preferences, {
  required bool defaultHighContrast,
  double defaultTextScale = 1.0,
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
  textScaleNotifier.value =
      (prefs['font_scale'] as num?)?.toDouble() ?? defaultTextScale;
  voiceGuidanceNotifier.value = prefs['voice_guidance'] as bool? ?? true;
}
