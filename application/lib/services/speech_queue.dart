import 'dart:async';

/// Speaks one sentence at a time, and says when each has really ended (D1).
/// Waiting for a guessed duration cut sentences off: the microphone opened
/// mid-sentence. Here the voice's own events end each one, through
/// [onStarted] and [onEnded] (completion, cancel or error).
///
/// [speak] starts a sentence and needn't wait for it; [stop] silences the
/// voice.
class SpeechQueue {
  SpeechQueue({
    required this.speak,
    required this.stop,
    this.startLimit = const Duration(seconds: 3),
    this.backstop = const Duration(seconds: 30),
  });

  final Future<void> Function(String text) speak;
  final Future<void> Function() stop;

  /// A voice that hasn't started by then never will (a broken or missing
  /// engine): give up instead of waiting forever.
  final Duration startLimit;

  /// The longest any sentence may take once started.
  final Duration backstop;

  Completer<void>? _current;
  bool _started = false;
  Future<void> _tail = Future.value();

  /// Sentences queued before the last interruption are skipped.
  int _generation = 0;

  void onStarted() => _started = true;

  void onEnded() {
    final current = _current;
    _current = null;
    if (current != null && !current.isCompleted) current.complete();
  }

  /// Returns once [text] has been said in full, after any sentence before
  /// it. With [interrupt], whatever is being said or waiting is dropped.
  Future<void> say(String text, {bool interrupt = false}) {
    if (interrupt) {
      _generation++;
      stop();
      onEnded();
    }
    final generation = _generation;
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    () async {
      await previous;
      if (generation == _generation) await _sayOne(text);
      done.complete();
    }();
    return done.future;
  }

  Future<void> _sayOne(String text) async {
    final ended = Completer<void>();
    _current = ended;
    _started = false;
    final startCheck = Timer(startLimit, () {
      if (!_started) onEnded();
    });
    final backstopTimer = Timer(backstop, onEnded);
    unawaited(
      speak(text).catchError((Object _) {
        onEnded();
      }),
    );
    await ended.future;
    startCheck.cancel();
    backstopTimer.cancel();
  }
}
