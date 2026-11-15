import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/services/app_preferences.dart';

void main() {
  test('nothing chosen: high contrast, bold, large text, Spanish (D10)', () {
    for (final prefs in [null, <String, dynamic>{}]) {
      applyPreferences(prefs);
      expect(highContrastNotifier.value, isTrue);
      expect(boldTextNotifier.value, isTrue);
      expect(textScaleNotifier.value, 1.3);
      expect(localeNotifier.value, const Locale('es'));
    }
  });

  test('a saved choice wins over the defaults', () {
    applyPreferences({
      'high_contrast': false,
      'bold_text': false,
      'font_scale': 1.0,
      'language': 'en',
    });
    expect(highContrastNotifier.value, isFalse);
    expect(boldTextNotifier.value, isFalse);
    expect(textScaleNotifier.value, 1.0);
    expect(localeNotifier.value, const Locale('en'));

    applyPreferences({'font_scale': 1.15});
    expect(textScaleNotifier.value, 1.15);
  });

  test('language: Spanish unless chosen; "auto" follows the phone', () {
    expect(localeFor('es'), const Locale('es'));
    expect(localeFor('en'), const Locale('en'));
    expect(localeFor(null), const Locale('es'));
    // An unknown value: the default, as when nothing was saved.
    expect(localeFor('fr'), const Locale('es'));
    // "Automatic" in Settings: the phone's language (null).
    expect(localeFor(kLanguageAuto), isNull);
  });

  test('the defaults hold before anyone signs in', () {
    // The notifiers' starting values, which the sign-in screen uses.
    expect(kDefaultHighContrast, isTrue);
    expect(kDefaultBoldText, isTrue);
    expect(kDefaultTextScale, 1.3);
    expect(kDefaultLocale, const Locale('es'));
  });

  test('voice_guidance defaults to on', () {
    applyPreferences(null);
    expect(voiceGuidanceNotifier.value, true);
    applyPreferences({'voice_guidance': false});
    expect(voiceGuidanceNotifier.value, false);
  });
}
