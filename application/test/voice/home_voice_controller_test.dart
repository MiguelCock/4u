import 'package:eyes4u/voice/home_voice_controller.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/voice_fakes.dart';

/// The home screen's voice on its own (#268): speak, then listen, in that
/// order; one answer per listen; never stuck; quiet while covered.

class _Setup {
  final speech = FakeSpeech();
  final voice = FakeVoice();
  final events = <String>[];
  late final HomeVoiceController ctl = HomeVoiceController(
    speech: speech,
    voice: voice.voice,
    marks: () async => events.add('marks'),
  );

  /// Starts a listen whose answers go to [heard].
  Future<ListenStart> listen(
    List<String> heard, {
    String? prompt,
    Duration listenFor = const Duration(seconds: 30),
  }) => ctl.listen(
    (words) async => heard.add(words),
    language: 'es',
    prompt: prompt,
    listenFor: listenFor,
  );
}

void main() {
  test('says the prompt, then the marks, then opens the microphone', () {
    fakeAsync((async) {
      final s = _Setup();
      ListenStart? started;
      s.listen([], prompt: 'Te escucho.').then((r) => started = r);
      async.elapse(const Duration(milliseconds: 300));
      // Still speaking: the microphone waits for the sentence's end.
      expect(s.voice.said, ['Te escucho.']);
      expect(s.speech.listens, 0);
      expect(s.events, isEmpty);

      async.elapse(const Duration(seconds: 1));
      expect(s.events, ['marks']);
      expect(s.speech.listens, 1);
      expect(started, ListenStart.started);
      expect(s.ctl.isListening, isTrue);
    });
  });

  test('a final result is the answer, once', () {
    fakeAsync((async) {
      final s = _Setup();
      final heard = <String>[];
      s.listen(heard);
      async.elapse(const Duration(seconds: 1));

      s.speech.hear('biblioteca');
      async.elapse(const Duration(seconds: 1));
      expect(heard, ['biblioteca']);
      expect(s.ctl.isListening, isFalse);

      // The timeout that would have ended it has gone too.
      async.elapse(const Duration(minutes: 1));
      expect(heard, ['biblioteca']);
    });
  });

  test('a late "done" from the last listen does not end the next one', () {
    fakeAsync((async) {
      final s = _Setup();
      final heard = <String>[];
      s.listen(heard);
      async.elapse(const Duration(seconds: 1));
      s.speech.hear('biblioteca');
      async.elapse(const Duration(seconds: 1));

      // The next listen is open, but its recognizer hasn't reported
      // "listening" yet when the old "done" arrives.
      s.speech.reportsListening = false;
      final second = <String>[];
      s.ctl.listen((w) async => second.add(w), language: 'es');
      async.elapse(const Duration(seconds: 1));
      expect(s.speech.listens, 2);
      s.speech.lateDone();
      async.elapse(const Duration(seconds: 1));
      expect(second, isEmpty);
      expect(s.ctl.isListening, isTrue);
      s.speech.reportStart();

      s.speech.hear('sí');
      async.elapse(const Duration(seconds: 1));
      expect(second, ['sí']);
    });
  });

  test('a recognizer that never answers still ends the listen', () {
    fakeAsync((async) {
      final s = _Setup();
      final heard = <String>[];
      s.listen(heard, listenFor: const Duration(seconds: 20));
      async.elapse(const Duration(seconds: 1));
      async.elapse(const Duration(seconds: 23));
      expect(heard, isEmpty);
      async.elapse(const Duration(seconds: 1));
      expect(heard, ['']);
      expect(s.ctl.isListening, isFalse);
    });
  });

  test('speaking closes the microphone first, and its answer is dropped', () {
    fakeAsync((async) {
      final s = _Setup();
      final heard = <String>[];
      s.listen(heard);
      async.elapse(const Duration(seconds: 1));
      expect(s.ctl.isListening, isTrue);

      s.ctl.say('Un momento');
      expect(s.ctl.isListening, isFalse);
      async.elapse(const Duration(seconds: 1));
      expect(s.voice.said, ['Un momento']);
      expect(heard, isEmpty);
    });
  });

  test('stopped by hand: no answer, and it says so', () {
    fakeAsync((async) {
      final s = _Setup();
      final heard = <String>[];
      s.listen(heard);
      async.elapse(const Duration(seconds: 1));

      s.ctl.stopListeningByHand('Dejé de escuchar.');
      async.elapse(const Duration(seconds: 1));
      expect(s.ctl.isListening, isFalse);
      expect(s.voice.said, ['Dejé de escuchar.']);
      async.elapse(const Duration(minutes: 1));
      expect(heard, isEmpty);
    });
  });

  test('covered: says nothing and does not listen, until uncovered', () {
    fakeAsync((async) {
      final s = _Setup();
      s.listen([]);
      async.elapse(const Duration(seconds: 1));

      s.ctl.cover();
      expect(s.ctl.isListening, isFalse);
      s.ctl.say('¿A dónde quieres ir?');
      ListenStart? started;
      s.listen([]).then((r) => started = r);
      async.elapse(const Duration(seconds: 2));
      expect(s.voice.said, isEmpty);
      expect(started, ListenStart.gone);
      expect(s.speech.listens, 1);

      s.ctl.uncover();
      s.ctl.say('Hola de nuevo');
      async.elapse(const Duration(seconds: 1));
      expect(s.voice.said, ['Hola de nuevo']);
    });
  });

  test('no recognizer: unavailable, and the prompt is not said', () {
    fakeAsync((async) {
      final s = _Setup()..speech.available = false;
      ListenStart? started;
      s.listen([], prompt: 'Te escucho.').then((r) => started = r);
      async.elapse(const Duration(seconds: 1));
      expect(started, ListenStart.unavailable);
      expect(s.voice.said, isEmpty);
      expect(s.events, isEmpty);
    });
  });

  test('misses: four retries for a place, then give up, then the count '
      'starts over (#226)', () {
    final ctl = _Setup().ctl;
    const tries = HomeVoiceController.placeRetries + 1;
    expect(
      [for (var i = 0; i < tries; i++) ctl.missed()],
      [for (var i = 0; i < tries; i++) i < tries - 1],
    );
    expect(ctl.missed(), isTrue);
    ctl.resetMisses();
    for (var i = 0; i < tries - 1; i++) {
      ctl.missed();
    }
    expect(ctl.missed(), isFalse);
  });

  test('dispose leaves the shared recognizer no callbacks', () {
    fakeAsync((async) {
      final s = _Setup();
      s.listen([]);
      async.elapse(const Duration(seconds: 1));
      s.ctl.dispose();
      expect(s.speech.statusListener, isNull);
      expect(s.speech.errorListener, isNull);
      expect(s.speech.isListening, isFalse);
    });
  });

  group('askUntil', () {
    Future<void> ask(_Setup s, List<int> answers, {bool Function()? open}) =>
        s.ctl.askUntil<int>(
          (heard) => int.tryParse(heard),
          onAnswer: answers.add,
          language: 'es',
          notUnderstood: 'Di el número.',
          giveUp: 'Toca uno.',
          stillOpen: open ?? () => true,
        );

    test('an answer it understands goes to onAnswer', () {
      fakeAsync((async) {
        final s = _Setup();
        final answers = <int>[];
        ask(s, answers);
        async.elapse(const Duration(seconds: 1));
        s.speech.hear('2');
        async.elapse(const Duration(seconds: 1));
        expect(answers, [2]);
        expect(s.voice.said, isEmpty);
      });
    });

    test('not understood: asked again twice, then it gives up', () {
      fakeAsync((async) {
        final s = _Setup();
        final answers = <int>[];
        ask(s, answers);
        for (var i = 0; i < 3; i++) {
          async.elapse(const Duration(seconds: 2));
          s.speech.hear('mmm');
        }
        async.elapse(const Duration(seconds: 2));
        expect(s.voice.said, ['Di el número.', 'Di el número.', 'Toca uno.']);
        expect(s.speech.listens, 3);
        expect(answers, isEmpty);
      });
    });

    test('once the dialog has closed, an answer does nothing', () {
      fakeAsync((async) {
        final s = _Setup();
        final answers = <int>[];
        var open = true;
        ask(s, answers, open: () => open);
        async.elapse(const Duration(seconds: 1));
        open = false;
        s.speech.hear('mmm');
        async.elapse(const Duration(seconds: 2));
        expect(s.voice.said, isEmpty);
        expect(s.speech.listens, 1);
      });
    });
  });
}
