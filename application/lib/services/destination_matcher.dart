/// Matching a spoken phrase ("quiero ir a la cafetería", "take me to room
/// 301") to the destination list - no network, no fuzzy-search package:
/// accent/case-insensitive token overlap is enough for a few dozen named
/// places, and is easy to reason about when it picks the wrong one.
library;

/// Filler words that say nothing about *which* place ("take me to the...",
/// "quiero ir a la..."), dropped before matching.
const Set<String> _stopWords = {
  // English
  'a', 'an', 'the', 'to', 'of', 'in', 'at', 'go', 'i', 'want', 'wanna',
  'take', 'me', 'please', 'where', 'is', 'find', 'get', 'route',
  // Spanish
  'al', 'el', 'la', 'los', 'las', 'de', 'del', 'en', 'un', 'una', 'ir',
  'quiero', 'llevame', 'lleva', 'por', 'favor', 'donde', 'esta',
  'buscar', 'ruta', 'hacia', 'hasta', 'voy',
};

const Map<String, String> _accents = {
  'á': 'a',
  'à': 'a',
  'ä': 'a',
  'â': 'a',
  'é': 'e',
  'è': 'e',
  'ë': 'e',
  'ê': 'e',
  'í': 'i',
  'ì': 'i',
  'ï': 'i',
  'î': 'i',
  'ó': 'o',
  'ò': 'o',
  'ö': 'o',
  'ô': 'o',
  'ú': 'u',
  'ù': 'u',
  'ü': 'u',
  'û': 'u',
  'ñ': 'n',
  'ç': 'c',
};

/// Lowercase, accents stripped, punctuation turned into spaces.
String normalizeForMatch(String text) {
  final buffer = StringBuffer();
  for (final char in text.toLowerCase().split('')) {
    final plain = _accents[char] ?? char;
    buffer.write(RegExp(r'[a-z0-9]').hasMatch(plain) ? plain : ' ');
  }
  return buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Words for "building" that say nothing about which one: "Edificio C" isn't
/// about "Máquina de pago Edificio N", where they found only this word
/// (Icesi, 2026-11-04).
const Set<String> _genericWords = {'edificio', 'bloque', 'building', 'block'};

/// How a recognizer may write a letter said after one of [_genericWords].
const Map<String, String> _letterNames = {
  'be': 'b',
  've': 'v',
  'uve': 'v',
  'ce': 'c',
  'se': 'c',
  'de': 'd',
  'efe': 'f',
  'ge': 'g',
  'je': 'g',
  'hache': 'h',
  'jota': 'j',
  'ka': 'k',
  'ca': 'k',
  'ele': 'l',
  'eme': 'm',
  'ene': 'n',
  'pe': 'p',
  'cu': 'q',
  'ere': 'r',
  'erre': 'r',
  'ese': 's',
  'te': 't',
  'equis': 'x',
  'ye': 'y',
  'zeta': 'z',
};

/// B and V sound the same in Spanish, so they're one letter here.
String _letter(String letter) => letter == 'v' ? 'b' : letter;

bool _isGeneric(String word) => _genericWords.contains(word);

/// A place's or a building's words. The letter of "Edificio A" stays, though
/// on its own "a" is a stop word.
List<String> _tokens(String text) {
  final words = normalizeForMatch(text).split(' ');
  return [
    for (var i = 0; i < words.length; i++)
      if (i > 0 && _isGeneric(words[i - 1]) && words[i].length == 1)
        _letter(words[i])
      else if (words[i].isNotEmpty && !_stopWords.contains(words[i]))
        words[i],
  ];
}

/// The words of a spoken phrase. The last one, right after [_genericWords], is
/// read as a letter: "edificio se" is C and "edificio de" is D, but "edificio
/// de ingenierías" is not.
List<String> _spokenTokens(String spoken) {
  final words = normalizeForMatch(spoken).split(' ');
  while (words.isNotEmpty &&
      const {'por', 'favor', 'please'}.contains(words.last)) {
    words.removeLast();
  }
  return [
    for (var i = 0; i < words.length; i++)
      if (i > 0 &&
          i == words.length - 1 &&
          _isGeneric(words[i - 1]) &&
          (words[i].length == 1 || _letterNames.containsKey(words[i])))
        _letter(_letterNames[words[i]] ?? words[i])
      else if (words[i].isNotEmpty && !_stopWords.contains(words[i]))
        words[i],
  ];
}

/// Whether a spoken token counts as naming a place token: equal, or one a
/// prefix of the other for words of 4+ letters ("cafe" ~ "cafeteria",
/// "laboratorios" ~ "laboratorio"). Numbers must match exactly, so "301"
/// never matches "302".
bool _tokenMatches(String spoken, String place) {
  if (spoken == place) return true;
  final numeric = RegExp(r'^\d+$');
  if (numeric.hasMatch(spoken) || numeric.hasMatch(place)) return false;
  if (spoken.length < 4 || place.length < 4) return false;
  return place.startsWith(spoken) || spoken.startsWith(place);
}

class DestinationMatch {
  final Map<String, dynamic> anchor;

  /// 0-1: the share of the spoken words that named this place.
  final double score;

  const DestinationMatch(this.anchor, this.score);
}

/// Ranks [destinations] (anchor rows with `location_description`) by how
/// well [spoken] names them, best first, dropping weak matches. Words in
/// the place's building name ([buildingNames], by building id) count too,
/// so "cafetería bloque 13" can pick the right one of two cafeterias.
List<DestinationMatch> matchDestinations(
  String spoken,
  List<Map<String, dynamic>> destinations, {
  Map<String, String> buildingNames = const {},
  double minScore = 0.5,
}) {
  final query = _spokenTokens(spoken);
  if (query.isEmpty) return const [];
  final matches = <DestinationMatch>[];
  for (final anchor in destinations) {
    final place = _tokens(anchor['location_description'] as String? ?? '');
    if (place.isEmpty) continue;
    final building = _tokens(buildingNames[anchor['building_id']] ?? '');
    var hits = 0.0;
    var namedThePlace = false;
    for (final word in query) {
      if (place.any((p) => _tokenMatches(word, p))) {
        hits += 1;
        namedThePlace = namedThePlace || !_isGeneric(word);
      } else if (building.any((b) => _tokenMatches(word, b))) {
        hits += 1;
      }
    }
    // Saying only the building ("bloque 13") isn't choosing a place in it.
    if (!namedThePlace) continue;
    final score = hits / query.length;
    if (score >= minScore) matches.add(DestinationMatch(anchor, score));
  }
  matches.sort((a, b) => b.score.compareTo(a.score));
  return matches;
}

/// The single match to pick without asking, or null when it's ambiguous:
/// the best one must be clearly ahead of the runner-up.
DestinationMatch? clearWinner(List<DestinationMatch> matches) {
  if (matches.isEmpty) return null;
  if (matches.length == 1) return matches.first;
  return matches[0].score - matches[1].score >= 0.25 ? matches.first : null;
}

/// Places whose whole name, alone or together with their building's, is what
/// was said: "Baño" or "Baño bloque 13", whatever a building is called.
List<Map<String, dynamic>> exactPlaces(
  String spoken,
  List<Map<String, dynamic>> destinations, {
  Map<String, String> buildingNames = const {},
}) {
  final query = _spokenTokens(spoken).toSet();
  if (query.isEmpty) return const [];
  bool same(Set<String> words) =>
      words.length == query.length && words.containsAll(query);
  return destinations.where((anchor) {
    final place = _tokens(anchor['location_description'] as String? ?? '');
    if (place.isEmpty) return false;
    final building = _tokens(buildingNames[anchor['building_id']] ?? '');
    return same(place.toSet()) || same({...place, ...building});
  }).toList();
}

/// A building's `code` counting less than its `name`, so that a name wins when
/// a code on another building says the same.
const double _codeOnlyScore = 0.7;

/// The [buildings] (rows with `name` and `code`) that [spoken] names, and only
/// names: "Edificio C" is one, "Baño Edificio N" is a place in one. Every
/// spoken word has to be in the building's name, and not only "edificio".
/// [DestinationMatch.anchor] is the building's row.
List<DestinationMatch> matchBuildings(
  String spoken,
  List<Map<String, dynamic>> buildings,
) {
  final query = _spokenTokens(spoken);
  if (query.every(_isGeneric)) return const [];
  bool names(String? text) {
    final words = _tokens(text ?? '');
    return query.every((q) => words.any((w) => _tokenMatches(q, w)));
  }

  final matches = <DestinationMatch>[
    for (final building in buildings)
      if (names(building['name'] as String?))
        DestinationMatch(building, 1)
      else if (names(building['code'] as String?))
        DestinationMatch(building, _codeOnlyScore),
  ];
  matches.sort((a, b) => b.score.compareTo(a.score));
  return matches;
}

/// [matches] with the nearest first among equal scores: the choice sheet shows
/// only a few, and many places share a name now that names don't repeat their
/// building.
List<DestinationMatch> nearestFirst(
  List<DestinationMatch> matches,
  double Function(Map<String, dynamic> anchor) distanceOf,
) {
  return List.of(matches)..sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore != 0
        ? byScore
        : distanceOf(a.anchor).compareTo(distanceOf(b.anchor));
  });
}

/// The answer to "Go to X?" said aloud (D1). Participants expected saying
/// "yes" to start the route, and couldn't find the button.
enum SpokenAnswer { start, change }

const Set<String> _startWords = {
  'si',
  'claro',
  'empezar',
  'empieza',
  'empecemos',
  'comenzar',
  'comienza',
  'iniciar',
  'inicia',
  'vamos',
  'dale',
  'listo',
  'ok',
  'okay',
  'vale',
  'yes',
  'yeah',
  'start',
  'go',
  'sure',
};
const Set<String> _changeWords = {
  'no',
  'cambiar',
  'cambia',
  'cambio',
  'otro',
  'otra',
  'change',
  'other',
  'nope',
};

/// [SpokenAnswer.start] or [SpokenAnswer.change] for what was heard, or null
/// when it's neither, or both ("no, sí"): then nothing happens and the
/// buttons are still there.
SpokenAnswer? spokenAnswer(String heard) {
  final words = normalizeForMatch(heard).split(' ').toSet();
  final start = words.any(_startWords.contains);
  final change = words.any(_changeWords.contains);
  if (start == change) return null;
  return start ? SpokenAnswer.start : SpokenAnswer.change;
}
