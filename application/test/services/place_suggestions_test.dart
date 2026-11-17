import 'package:eyes4u/services/place_suggestions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('asksWhatPlaces', () {
    for (final heard in [
      '¿Qué lugares hay?',
      'qué hay por aquí',
      '¿Qué me recomiendas?',
      'recomiéndame un lugar',
      'no sé a dónde ir',
      '¿A dónde puedo ir?',
      'dame opciones',
      'qué lugares hay cerca',
      "What's there?",
      'what places are there',
      'can you recommend somewhere',
      "I don't know",
      'where can I go',
    ]) {
      test('"$heard"', () => expect(asksWhatPlaces(heard), isTrue));
    }

    for (final heard in [
      'la biblioteca',
      'qué baños hay',
      'necesito el baño más cercano',
      'dónde queda la enfermería',
      '',
    ]) {
      test('not "$heard"', () => expect(asksWhatPlaces(heard), isFalse));
    }
  });

  test('asksForMore', () {
    expect(asksForMore('más'), isTrue);
    expect(asksForMore('otros, por favor'), isTrue);
    expect(asksForMore('more'), isTrue);
    expect(asksForMore('el dos'), isFalse);
    expect(asksForMore('la biblioteca'), isFalse);
  });

  test('suggested places: nearest first, each name once', () {
    final places = [
      {'id': 'e1', 'name': 'Entrada'},
      {'id': 'lib', 'name': 'Biblioteca'},
      {'id': 'e2', 'name': 'Entrada'},
      {'id': 'caf', 'name': 'Cafetería'},
    ];
    const meters = {'e1': 50.0, 'lib': 30.0, 'e2': 10.0, 'caf': 90.0};
    final ids = [
      for (final p in suggestedPlaces(
        places,
        name: (p) => p['name']! as String,
        distance: (p) => meters[p['id']]!,
      ))
        p['id'],
    ];
    expect(ids, ['e2', 'lib', 'caf']);
  });

  test('pages of three', () {
    final all = List.generate(7, (i) => i);
    expect(optionsPage(all, 0), [0, 1, 2]);
    expect(optionsPage(all, 1), [3, 4, 5]);
    expect(optionsPage(all, 2), [6]);
    expect(optionsPage(all, 3), isEmpty);
  });
}
