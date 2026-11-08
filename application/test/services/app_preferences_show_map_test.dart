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
}
