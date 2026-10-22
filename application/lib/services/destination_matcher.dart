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

List<String> _tokens(String text) => normalizeForMatch(
  text,
).split(' ').where((t) => t.isNotEmpty && !_stopWords.contains(t)).toList();

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
  final query = _tokens(spoken);
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
        namedThePlace = true;
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
