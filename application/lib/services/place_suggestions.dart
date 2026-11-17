import 'destination_matcher.dart' show normalizeForMatch;

/// "¿Qué lugares hay?" (D9, #248): a user who doesn't know the campus can ask
/// what's there instead of guessing a name.

/// Phrases that ask what places there are, normalized ([normalizeForMatch]).
/// Matched as whole words inside what was heard.
const List<String> _questions = [
  // Spanish
  'que lugares', 'que sitios', 'que hay', 'que me recomiendas',
  'que me recomienda', 'recomiendame', 'recomiendeme', 'recomendacion',
  'recomendaciones', 'sugerencia', 'sugerencias', 'sugiereme', 'opciones',
  'a donde puedo ir', 'donde puedo ir', 'adonde puedo ir', 'no se a donde',
  'no se donde', 'no se que', 'lugares hay', 'lugares cerca',
  'lista de lugares', 'cuales lugares', 'que destinos', 'destinos',
  // English
  'what places', 'what s there', 'whats there', 'what is there',
  'what is around', 'what s around', 'what is near', 'recommend',
  'suggest', 'suggestions', 'options', 'where can i go', 'i don t know',
  'i dont know', 'list places', 'which places',
];

/// Whether [heard] asks what places there are.
bool asksWhatPlaces(String heard) {
  final said = ' ${normalizeForMatch(heard)} ';
  return _questions.any((q) => said.contains(' $q '));
}

/// Words asking for the next few options, while a list is being read.
const Set<String> _moreWords = {
  'mas',
  'otros',
  'otras',
  'siguientes',
  'siguiente',
  'more',
  'next',
  'others',
  'other',
};

/// Whether [heard] asks for more options ("más", "otros", "more").
bool asksForMore(String heard) =>
    normalizeForMatch(heard).split(' ').any(_moreWords.contains);

/// How many options are read out at a time (D12 rule R10).
const int kOptionsPerPage = 3;

/// Places to suggest, nearest first, each name once: many points share a
/// name ("Entrada"), and hearing it three times says nothing. [name] gives
/// what's said for a place; [distance] its metres from the user.
List<Map<String, dynamic>> suggestedPlaces(
  List<Map<String, dynamic>> candidates, {
  required String Function(Map<String, dynamic>) name,
  required double Function(Map<String, dynamic>) distance,
}) {
  final sorted = List.of(candidates)
    ..sort((a, b) => distance(a).compareTo(distance(b)));
  final seen = <String>{};
  return [
    for (final place in sorted)
      if (seen.add(normalizeForMatch(name(place)))) place,
  ];
}

/// The [page]th group of [kOptionsPerPage] of [all] (empty past the end).
List<T> optionsPage<T>(List<T> all, int page) =>
    all.skip(page * kOptionsPerPage).take(kOptionsPerPage).toList();
