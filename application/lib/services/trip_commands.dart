import 'destination_matcher.dart' show normalizeForMatch;

/// What a user can say during a trip (#228).
enum TripCommand { pause, resume, repeat }

const _words = {
  TripCommand.pause: {
    'pausa',
    'pausar',
    'pausala',
    'para',
    'detente',
    'espera',
    'pause',
    'stop',
    'wait',
  },
  TripCommand.resume: {
    'seguir',
    'sigue',
    'sigamos',
    'continua',
    'continuar',
    'reanudar',
    'resume',
    'continue',
  },
  TripCommand.repeat: {
    'repite',
    'repetir',
    'repiteme',
    'otra',
    'repeat',
    'again',
  },
};

/// The command in [heard], or null: the first word that names one. "Para"
/// alone pauses; a phrase naming two commands is ambiguous and gives null.
TripCommand? tripCommand(String heard) {
  final tokens = normalizeForMatch(heard).split(' ').where((t) => t.isNotEmpty);
  final found = <TripCommand>{
    for (final t in tokens)
      for (final e in _words.entries)
        if (e.value.contains(t)) e.key,
  };
  return found.length == 1 ? found.first : null;
}
