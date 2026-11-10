import 'package:eyes4u/services/speech_queue.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// A voice that takes [seconds] per sentence, or never starts.
class FakeVoice {
  FakeVoice(this.async, {this.seconds = 4, this.starts = true});
  final FakeAsync async;
  final int seconds;
  final bool starts;
  late SpeechQueue queue;
  final said = <String>[];

  Future<void> speak(String text) async {
    if (!starts) return;
    said.add(text);
    queue.onStarted();
    Future.delayed(Duration(seconds: seconds), queue.onEnded);
  }
}

void main() {
  test('say returns only when the voice has finished, however long', () {
    fakeAsync((async) {
      final voice = FakeVoice(async, seconds: 9); // longer than any guess
      voice.queue = SpeechQueue(speak: voice.speak, stop: () async {});
      var done = false;
      voice.queue.say('una frase larga').then((_) => done = true);
      async.elapse(const Duration(seconds: 8));
      expect(done, isFalse);
      async.elapse(const Duration(seconds: 2));
      expect(done, isTrue);
    });
  });

  test('a second sentence waits for the first instead of cutting it', () {
    fakeAsync((async) {
      final voice = FakeVoice(async);
      voice.queue = SpeechQueue(speak: voice.speak, stop: () async {});
      var second = false;
      voice.queue.say('uno');
      voice.queue.say('dos').then((_) => second = true);
      async.elapse(const Duration(seconds: 1));
      expect(voice.said, ['uno']);
      async.elapse(const Duration(seconds: 4));
      expect(voice.said, ['uno', 'dos']);
      async.elapse(const Duration(seconds: 4));
      expect(second, isTrue);
    });
  });

  test('a voice that never starts gives up after the start limit', () {
    fakeAsync((async) {
      final voice = FakeVoice(async, starts: false);
      voice.queue = SpeechQueue(speak: voice.speak, stop: () async {});
      var done = false;
      voice.queue.say('nada').then((_) => done = true);
      async.elapse(const Duration(seconds: 2));
      expect(done, isFalse);
      async.elapse(const Duration(seconds: 2));
      expect(done, isTrue);
    });
  });

  test('interrupting drops what was waiting', () {
    fakeAsync((async) {
      final voice = FakeVoice(async);
      var stopped = 0;
      voice.queue = SpeechQueue(
        speak: voice.speak,
        stop: () async => stopped++,
      );
      voice.queue.say('uno');
      voice.queue.say('dos');
      async.elapse(const Duration(seconds: 1));
      voice.queue.say('tres', interrupt: true);
      async.elapse(const Duration(seconds: 10));
      expect(voice.said, ['uno', 'tres']);
      expect(stopped, 1);
    });
  });
}
