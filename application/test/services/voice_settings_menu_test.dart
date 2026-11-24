import 'package:eyes4u/services/app_preferences.dart';
import 'package:eyes4u/services/voice_settings_menu.dart';
import 'package:flutter_test/flutter_test.dart';

VoiceSettingsMenu _menu() => VoiceSettingsMenu({
  VoiceSetting.speed: kDefaultSpeechRate,
  VoiceSetting.manualSearch: false,
  VoiceSetting.map: true,
  VoiceSetting.boldText: true,
  VoiceSetting.voiceGuidance: true,
});

void main() {
  test('"ajustes" and its synonyms open the menu (#226)', () {
    expect(asksForSettings('ajustes'), isTrue);
    expect(asksForSettings('abre la configuración'), isTrue);
    expect(asksForSettings('settings'), isTrue);
    expect(asksForSettings('la biblioteca'), isFalse);
  });

  test('the speed takes slow, normal or fast; one at a time', () {
    final menu = _menu();
    expect(menu.current, VoiceSetting.speed);
    final r = menu.answer('más rápida') as MenuSet;
    expect((r.setting, r.value), (VoiceSetting.speed, kSpeechRates['fast']));
    expect(menu.answer('lenta, no, rápida'), isNull);
    expect(menu.answer('bueno'), isNull);
  });

  test('a yes/no option toggles on "sí", moves on with "no"', () {
    final menu = _menu()..advance();
    expect(menu.current, VoiceSetting.manualSearch);
    final on = menu.answer('sí') as MenuSet;
    expect(on.value, isTrue);
    menu.set(on);
    expect((menu.answer('sí') as MenuSet).value, isFalse);
    expect(menu.answer('no'), isA<MenuNext>());
  });

  test('"siguiente" moves on, "salir" leaves, and the menu ends', () {
    final menu = _menu();
    expect(menu.answer('siguiente'), isA<MenuNext>());
    expect(menu.answer('listo, salir'), isA<MenuExit>());
    var steps = 0;
    while (menu.advance()) {
      steps++;
    }
    expect(steps, VoiceSetting.values.length - 1);
  });
}
