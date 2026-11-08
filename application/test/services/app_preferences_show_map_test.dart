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

  test('the choices appear whenever voice can not be used', () {
    bool shows({
      bool setting = false,
      bool revealed = false,
      bool reader = false,
    }) => homeShowsChoices(
      setting: setting,
      revealed: revealed,
      screenReader: reader,
    );
    expect(shows(), isFalse);
    expect(shows(setting: true), isTrue);
    expect(shows(revealed: true), isTrue, reason: 'no voice, or gave up');
    expect(shows(reader: true), isTrue, reason: 'TalkBack: no auto-listen');
  });
}
