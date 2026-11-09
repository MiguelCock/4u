import 'package:eyes4u/services/app_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the map is off unless the user turned it on (D2)', () {
    applyPreferences({}, defaultHighContrast: false);
    expect(showMapNotifier.value, isFalse);
    applyPreferences({'show_map': true}, defaultHighContrast: false);
    expect(showMapNotifier.value, isTrue);
    applyPreferences(null, defaultHighContrast: false);
    expect(showMapNotifier.value, isFalse);
  });

  test('start and destination are hidden unless turned on', () {
    applyPreferences({}, defaultHighContrast: false);
    expect(showChoicesNotifier.value, isFalse);
    applyPreferences({'show_choices': true}, defaultHighContrast: false);
    expect(showChoicesNotifier.value, isTrue);
  });

  test(
    'the choices appear when asked for, with no recognizer, or voice off',
    () {
      bool shows({
        bool setting = false,
        bool revealed = false,
        bool voiceOn = true,
      }) => homeShowsChoices(
        setting: setting,
        revealed: revealed,
        voiceOn: voiceOn,
      );
      expect(shows(), isFalse);
      expect(shows(setting: true), isTrue);
      expect(shows(revealed: true), isTrue);
      expect(shows(voiceOn: false), isTrue, reason: 'it can not ask by voice');
    },
  );

  test('bold text follows the phone until the user chooses', () {
    applyPreferences({}, defaultHighContrast: false);
    expect(boldTextNotifier.value, isNull);
    applyPreferences({'bold_text': true}, defaultHighContrast: false);
    expect(boldTextNotifier.value, isTrue);
  });
}
