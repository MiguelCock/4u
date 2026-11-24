import 'app_preferences.dart';
import 'destination_matcher.dart'
    show SpokenAnswer, normalizeForMatch, spokenAnswer;

/// What the spoken settings menu can change (#226), in the order it reads
/// them. Each is a `profiles.preferences` key.
enum VoiceSetting {
  speed('speech_rate'),
  manualSearch('show_choices'),
  map('show_map'),
  boldText('bold_text'),
  voiceGuidance('voice_guidance');

  const VoiceSetting(this.key);
  final String key;
}

/// An answer to one option.
sealed class MenuReply {
  const MenuReply();
}

/// Change [setting] to [value] (a [kSpeechRates] value, or a bool).
class MenuSet extends MenuReply {
  const MenuSet(this.setting, this.value);
  final VoiceSetting setting;
  final Object value;
}

class MenuNext extends MenuReply {
  const MenuNext();
}

class MenuExit extends MenuReply {
  const MenuExit();
}

const _next = {
  'siguiente',
  'proxima',
  'proximo',
  'otra',
  'otro',
  'pasa',
  'next',
  'skip',
};
const _exit = {
  'salir',
  'sal',
  'listo',
  'terminar',
  'termina',
  'cerrar',
  'ya',
  'exit',
  'done',
  'close',
};
const _slow = {'lenta', 'lento', 'despacio', 'slow', 'slower'};
const _normal = {'normal'};
const _fast = {'rapida', 'rapido', 'fast', 'faster'};

/// "ajustes" during a destination listen opens the menu (#226).
bool asksForSettings(String heard) {
  final words = normalizeForMatch(heard).split(' ').toSet();
  return words.any(
    const {
      'ajustes',
      'ajuste',
      'configuracion',
      'configurar',
      'opciones',
      'settings',
      'options',
    }.contains,
  );
}

/// The spoken settings menu (#226): one option at a time, with its current
/// value. A yes/no option toggles on "sí" and moves on with "no"; the speed
/// takes "lenta", "normal" or "rápida". "Siguiente" moves on and "salir"
/// leaves. Pure: the conversation says and listens.
class VoiceSettingsMenu {
  VoiceSettingsMenu(this.values);

  /// The menu over what's in effect now.
  factory VoiceSettingsMenu.current() => VoiceSettingsMenu({
    VoiceSetting.speed: speechRateNotifier.value,
    VoiceSetting.manualSearch: showChoicesNotifier.value,
    VoiceSetting.map: showMapNotifier.value,
    VoiceSetting.boldText: boldTextNotifier.value ?? kDefaultBoldText,
    VoiceSetting.voiceGuidance: voiceGuidanceNotifier.value,
  });

  final Map<VoiceSetting, Object> values;
  int _index = 0;

  VoiceSetting get current => VoiceSetting.values[_index];

  /// The next option; false when there's none (the menu is over).
  bool advance() {
    if (_index + 1 >= VoiceSetting.values.length) return false;
    _index++;
    return true;
  }

  /// What [heard] asks of the current option, or null when it's not
  /// understood.
  MenuReply? answer(String heard) {
    final words = normalizeForMatch(heard).split(' ').toSet();
    if (words.any(_exit.contains)) return const MenuExit();
    if (words.any(_next.contains)) return const MenuNext();
    if (current == VoiceSetting.speed) {
      final picked = [
        if (words.any(_slow.contains)) 'slow',
        if (words.any(_normal.contains)) 'normal',
        if (words.any(_fast.contains)) 'fast',
      ];
      if (picked.length != 1) return null;
      return MenuSet(current, kSpeechRates[picked.single]!);
    }
    switch (spokenAnswer(heard)) {
      case SpokenAnswer.start:
        return MenuSet(current, !(values[current] as bool));
      case SpokenAnswer.change:
        return const MenuNext();
      case null:
        return null;
    }
  }

  /// Records a change made.
  void set(MenuSet change) => values[change.setting] = change.value;
}
