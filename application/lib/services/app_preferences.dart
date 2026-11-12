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
final ValueNotifier<bool> highContrastNotifier = ValueNotifier<bool>(
  kDefaultHighContrast,
);

/// `null` means "follow the device locale" (Flutter's default resolution
/// when `MaterialApp.locale` is left unset); a non-null value forces that
/// language regardless of device locale. Spanish until a profile says
/// otherwise (D10).
final ValueNotifier<Locale?> localeNotifier = ValueNotifier<Locale?>(
  kDefaultLocale,
);

/// Multiplies every `TextStyle`'s font size app-wide (`MainApp`'s
/// `MaterialApp.builder` applies it via a `MediaQuery.textScaler`
/// override) - 1.0 is normal size.
final ValueNotifier<double> textScaleNotifier = ValueNotifier<double>(
  kDefaultTextScale,
);

/// Whether `NavigationScreen` should speak announcements (route start,
/// waypoint proximity, arrival, end-of-session) via `flutter_tts` - the
/// voice toggle #85 deferred until there was TTS to back it. Defaults to
/// on, unlike the others above which default from an OS-level signal -
/// there's no equivalent OS signal for "wants spoken navigation", so a
/// sensible fixed default for this app's audience is on until turned off.
final ValueNotifier<bool> voiceGuidanceNotifier = ValueNotifier<bool>(true);

/// Whether users see the map during a trip (D2), for low vision. Off by
/// default: most users are blind, and didn't know what "the map" was.
final ValueNotifier<bool> showMapNotifier = ValueNotifier<bool>(false);

/// Whether the home screen shows the Start and destination rows (D1/D2).
/// Off by default, so the screen is one big Speak button: the simplest it
/// can be.
final ValueNotifier<bool> showChoicesNotifier = ValueNotifier<bool>(false);

/// Whether the home screen shows the Start and destination rows: when the
/// user turned them on, or when this phone has no speech recognizer at all
/// ([revealed]). Not after failed tries, and not for TalkBack: voice first
/// is for everyone (D1). The home screen speaks whatever "Guía de voz" says.
bool homeShowsChoices({required bool setting, required bool revealed}) =>
    setting || revealed;

/// Bold text everywhere (Settings, next to high contrast and font size).
/// Null would mean the phone's own bold-text setting; on by default (D10).
final ValueNotifier<bool?> boldTextNotifier = ValueNotifier<bool?>(
  kDefaultBoldText,
);

/// The look of anything never chosen (D10): high contrast, bold, the
/// largest text Settings offers, and Spanish. Most users need them, and
/// had to find each setting; anyone can switch back in Settings.
const bool kDefaultHighContrast = true;
const bool kDefaultBoldText = true;
const double kDefaultTextScale = 1.3;
const Locale kDefaultLocale = Locale('es');

/// The saved `language` meaning "follow the phone". Saved explicitly now
/// that nothing saved means Spanish; older apps read it as the phone's too.
const String kLanguageAuto = 'auto';

/// The locale for a saved `language`: Spanish when none was saved.
Locale? localeFor(String? language) => switch (language) {
  'en' => const Locale('en'),
  'es' => const Locale('es'),
  kLanguageAuto => null,
  _ => kDefaultLocale,
};

/// Reads `high_contrast`/`language`/`font_scale`/`voice_guidance` out of a
/// `profiles.preferences` map (as returned by `GET /profiles/{id}`) and
/// applies them to the notifiers above. What was never chosen takes the
/// defaults above.
void applyPreferences(Map<String, dynamic>? preferences) {
  final prefs = preferences ?? const {};
  highContrastNotifier.value =
      prefs['high_contrast'] as bool? ?? kDefaultHighContrast;
  localeNotifier.value = localeFor(prefs['language'] as String?);
  textScaleNotifier.value =
      (prefs['font_scale'] as num?)?.toDouble() ?? kDefaultTextScale;
  voiceGuidanceNotifier.value = prefs['voice_guidance'] as bool? ?? true;
  showMapNotifier.value = prefs['show_map'] as bool? ?? false;
  showChoicesNotifier.value = prefs['show_choices'] as bool? ?? false;
  boldTextNotifier.value = prefs['bold_text'] as bool? ?? kDefaultBoldText;
}
