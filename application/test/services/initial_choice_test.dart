import 'package:eyes4u/services/initial_choice.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final rows = [
    {'id': 'a'},
    {'id': 'b'},
  ];

  test('the preferred row while it exists', () {
    expect(initialChoice(rows, 'b'), 'b');
  });

  test('else the first, else none', () {
    expect(initialChoice(rows, 'gone'), 'a');
    expect(initialChoice(rows, null), 'a');
    expect(initialChoice(const [], 'b'), isNull);
  });
}
