import 'package:eyes4u/services/app_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the map is off unless the user turned it on (D2)', () {
    applyPreferences({});
    expect(showMapNotifier.value, isFalse);
    applyPreferences({'show_map': true});
    expect(showMapNotifier.value, isTrue);
    applyPreferences(null);
    expect(showMapNotifier.value, isFalse);
  });

  test('start and destination are hidden unless turned on', () {
    applyPreferences({});
    expect(showChoicesNotifier.value, isFalse);
    applyPreferences({'show_choices': true});
    expect(showChoicesNotifier.value, isTrue);
  });

  test('the choices appear only when asked for, or with no recognizer', () {
    expect(homeShowsChoices(setting: false, revealed: false), isFalse);
    expect(homeShowsChoices(setting: true, revealed: false), isTrue);
    expect(homeShowsChoices(setting: false, revealed: true), isTrue);
  });

  test('bold text is on until the user chooses (D10)', () {
    applyPreferences({});
    expect(boldTextNotifier.value, isTrue);
    applyPreferences({'bold_text': false});
    expect(boldTextNotifier.value, isFalse);
  });
}
