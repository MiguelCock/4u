import 'package:eyes4u/services/destination_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const window = Duration(seconds: 20);

  test('silence with time left listens again', () {
    expect(shouldListenAgain('', const Duration(seconds: 5), window), isTrue);
    expect(
      shouldListenAgain('  ', const Duration(seconds: 17), window),
      isTrue,
    );
  });

  test('an answer, or the window running out, ends it', () {
    expect(
      shouldListenAgain('sí', const Duration(seconds: 5), window),
      isFalse,
    );
    expect(shouldListenAgain('', const Duration(seconds: 19), window), isFalse);
    expect(shouldListenAgain('', const Duration(seconds: 25), window), isFalse);
  });
}
