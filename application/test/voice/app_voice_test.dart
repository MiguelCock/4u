import 'package:eyes4u/voice/app_voice.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// An engine that takes 2 s per sentence.
class FakeEngine {
  late AppVoice voice;
  final said = <String>[];

  Future<void> speak(String text) async {
    said.add(text);
    voice.onStarted();
    Future.delayed(const Duration(seconds: 2), voice.onEnded);
  }
}

AppVoice _voice(FakeEngine engine) => engine.voice = AppVoice(
  speak: engine.speak,
  stop: () async {},
  configure: (_) async => true,
);

void main() {
  test('a screen that claims the voice drops what the last one queued', () {
    fakeAsync((async) {
      final engine = FakeEngine();
      final voice = _voice(engine);
      final home = voice.claim();
      home.say('Inicio: Biblioteca.');
      home.say('Te escucho.');
      async.elapse(const Duration(milliseconds: 500));
      // The trip starts while the home screen is still talking.
      final trip = voice.claim();
      trip.say('Iniciando ruta.');
      async.elapse(const Duration(seconds: 6));
      expect(engine.said, ['Inicio: Biblioteca.', 'Iniciando ruta.']);
      expect(home.isCurrent, isFalse);
    });
  });

  test('a covered screen is not heard', () {
    fakeAsync((async) {
      final engine = FakeEngine();
      final voice = _voice(engine);
      final home = voice.claim();
      voice.claim();
      home.say('¿A dónde quieres ir?');
      async.elapse(const Duration(seconds: 3));
      expect(engine.said, isEmpty);
    });
  });

  test('a released owner says nothing more', () {
    fakeAsync((async) {
      final engine = FakeEngine();
      final voice = _voice(engine);
      final trip = voice.claim()..release();
      trip.say('Navegación finalizada');
      async.elapse(const Duration(seconds: 3));
      expect(engine.said, isEmpty);
    });
  });

  test('nothing is said while the microphone is open', () {
    fakeAsync((async) {
      final engine = FakeEngine();
      final voice = _voice(engine);
      final home = voice.claim();
      voice.listening.value = true;
      var done = false;
      home.say('Un momento').then((_) => done = true);
      async.elapse(const Duration(seconds: 5));
      expect(engine.said, isEmpty);
      voice.listening.value = false;
      async.elapse(const Duration(seconds: 3));
      expect(engine.said, ['Un momento']);
      expect(done, isTrue);
    });
  });
}
