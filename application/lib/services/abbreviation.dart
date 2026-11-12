import 'destination_matcher.dart' show normalizeForMatch;

/// Words skipped when abbreviating: "Universidad Pontificia de Bolívar"
/// gives "UPB", not "UPDB".
const Set<String> _skipped = {
  'de', 'del', 'la', 'las', 'los', 'el', 'y', 'e', 'en', //
  'the', 'of', 'and', 'for', 'at',
};

/// A university's suggested abbreviation: the initials of its name's words,
/// uppercase, without accents or the small words (C10).
/// "Universidad Pontificia Bolivariana" → "UPB".
String abbreviationFor(String name) => normalizeForMatch(name)
    .split(' ')
    .where((word) => word.isNotEmpty && !_skipped.contains(word))
    .map((word) => word[0])
    .join()
    .toUpperCase();
