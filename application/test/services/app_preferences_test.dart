import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/services/app_preferences.dart';

void main() {
  test('falls back to the OS-level default when high_contrast is unset', () {
    applyPreferences(null, defaultHighContrast: true);
    expect(highContrastNotifier.value, true);

    applyPreferences({}, defaultHighContrast: false);
    expect(highContrastNotifier.value, false);
  });

  test('an explicit high_contrast preference overrides the OS default', () {
    applyPreferences({'high_contrast': true}, defaultHighContrast: false);
    expect(highContrastNotifier.value, true);

    applyPreferences({'high_contrast': false}, defaultHighContrast: true);
    expect(highContrastNotifier.value, false);
  });

  test('language maps to the matching Locale, unknown/missing stays null', () {
    applyPreferences({'language': 'es'}, defaultHighContrast: false);
    expect(localeNotifier.value, const Locale('es'));

    applyPreferences({'language': 'en'}, defaultHighContrast: false);
    expect(localeNotifier.value, const Locale('en'));

    applyPreferences({'language': 'fr'}, defaultHighContrast: false);
    expect(localeNotifier.value, null);

    applyPreferences({}, defaultHighContrast: false);
    expect(localeNotifier.value, null);
  });

  test('falls back to the OS-level default when font_scale is unset', () {
    applyPreferences(null, defaultHighContrast: false, defaultTextScale: 1.3);
    expect(textScaleNotifier.value, 1.3);

    applyPreferences({}, defaultHighContrast: false, defaultTextScale: 1.0);
    expect(textScaleNotifier.value, 1.0);
  });

  test('an explicit font_scale preference overrides the OS default', () {
    applyPreferences(
      {'font_scale': 1.15},
      defaultHighContrast: false,
      defaultTextScale: 1.0,
    );
    expect(textScaleNotifier.value, 1.15);
  });

  test('voice_guidance defaults to on, no OS signal to fall back to', () {
    applyPreferences(null, defaultHighContrast: false);
    expect(voiceGuidanceNotifier.value, true);

    applyPreferences({}, defaultHighContrast: false);
    expect(voiceGuidanceNotifier.value, true);
  });

  test('an explicit voice_guidance preference overrides the default', () {
    applyPreferences({'voice_guidance': false}, defaultHighContrast: false);
    expect(voiceGuidanceNotifier.value, false);

    applyPreferences({'voice_guidance': true}, defaultHighContrast: false);
    expect(voiceGuidanceNotifier.value, true);
  });
}
