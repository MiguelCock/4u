import 'package:eyes4u/services/trip_commands.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the three commands, in Spanish and English (#228)', () {
    expect(tripCommand('pausa'), TripCommand.pause);
    expect(tripCommand('Espera, por favor'), TripCommand.pause);
    expect(tripCommand('seguir'), TripCommand.resume);
    expect(tripCommand('Continúa'), TripCommand.resume);
    expect(tripCommand('repíteme eso'), TripCommand.repeat);
    expect(tripCommand('pause'), TripCommand.pause);
    expect(tripCommand('resume'), TripCommand.resume);
    expect(tripCommand('repeat that'), TripCommand.repeat);
  });

  test('nothing, or two commands at once, is no command', () {
    expect(tripCommand(''), isNull);
    expect(tripCommand('la cafetería'), isNull);
    expect(tripCommand('para y luego sigue'), isNull);
  });
}
