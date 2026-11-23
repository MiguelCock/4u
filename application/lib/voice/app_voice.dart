import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../services/speech_queue.dart';
import '../services/speech_voice.dart';

/// Tells a screen when a page covers it or uncovers it (`RouteAware`), so a
/// covered screen gives the voice up. Pages only: a dialog over a screen is
/// still that screen talking. Registered in `MaterialApp.navigatorObservers`.
final voiceRouteObserver = RouteObserver<PageRoute<dynamic>>();

/// The app's one voice (#257, #258): one engine, one queue, and one screen
/// allowed to speak at a time.
///
/// Each user screen used to have its own FlutterTts. Pushing the trip screen
/// left the home screen's last sentence and timers running under the trip's
/// own start, so in a test both were heard at once, and twice. Now a screen
/// speaks through the [VoiceOwner] it [claim]s, and claiming silences the
/// previous owner and drops what it had queued.
class AppVoice {
  AppVoice({
    required Future<void> Function(String text) speak,
    required Future<void> Function() stop,
    required this.configure,
  }) {
    _queue = SpeechQueue(speak: speak, stop: stop);
  }

  /// The real voice: one FlutterTts for the whole app. Its events (start,
  /// end) go to the last FlutterTts created, which is why there must be one.
  factory AppVoice._flutterTts() {
    final tts = FlutterTts();
    late final AppVoice voice;
    voice = AppVoice(
      speak: (text) async => tts.speak(text),
      stop: () async => tts.stop(),
      configure: (language) async {
        final ready = await configureTts(tts, language);
        try {
          // A sentence's end comes from the events below, not speak().
          await tts.awaitSpeakCompletion(false);
        } catch (_) {}
        return ready;
      },
    );
    tts
      ..setStartHandler(voice.onStarted)
      ..setCompletionHandler(voice.onEnded)
      ..setCancelHandler(voice.onEnded)
      ..setErrorHandler((_) => voice.onEnded());
    return voice;
  }

  static AppVoice? _instance;
  static AppVoice get instance => _instance ??= AppVoice._flutterTts();

  @visibleForTesting
  static set instance(AppVoice voice) => _instance = voice;

  /// Sets the engine up for a language (see [setLanguage]).
  final Future<bool> Function(String languageCode) configure;
  late final SpeechQueue _queue;
  Future<bool>? _ready;
  String? _language;
  VoiceOwner? _owner;

  /// Whether a screen has the microphone open ([VoiceOwner.beginListening]).
  /// Nothing another screen says is heard meanwhile: the recognizer would
  /// take it as the answer.
  final ValueNotifier<bool> listening = ValueNotifier(false);
  VoiceOwner? _listener;

  void _setListener(VoiceOwner? owner) {
    _listener = owner;
    listening.value = owner != null;
  }

  /// The engine's own events: a sentence started, and ended (finished,
  /// cancelled or failed).
  void onStarted() => _queue.onStarted();
  void onEnded() => _queue.onEnded();

  /// Points the voice at [languageCode], once per language. Completes with
  /// false when no voice for it is installed.
  Future<bool> setLanguage(String languageCode) {
    if (languageCode != _language || _ready == null) {
      _language = languageCode;
      _ready = configure(languageCode);
    }
    return _ready!;
  }

  /// Makes the calling screen the one that speaks, silencing whoever spoke
  /// before and dropping what they had queued.
  VoiceOwner claim() {
    final owner = VoiceOwner._(this);
    _owner = owner;
    // A covered screen's listen is over, whether or not it said so.
    _setListener(null);
    _interrupt();
    return owner;
  }

  void _interrupt() => _queue.cancel();

  /// The user asked for quiet (D12 rule R8, [SkipSpeech]): what's being
  /// said and what's waiting is dropped, whoever owns the voice. Each
  /// dropped `say` returns, so a screen waiting to listen does so at once.
  /// Nothing else changes: no question is answered and no trip ends.
  void skip() {
    _interrupt();
    skipped.value++;
  }

  /// Counts [skip]s, for a screen that wants to react to one (the tutorial
  /// moving on sooner happens by itself: its sentence ends).
  final ValueNotifier<int> skipped = ValueNotifier(0);

  Future<void> _say(VoiceOwner owner, String text, bool interrupt) async {
    if (!identical(owner, _owner)) return;
    // The listening screen speaking has closed its own microphone: a listen
    // that ended without saying so must not silence it. That kept "¿Ir a
    // X? Di sí…" waiting until a tap, after a place was heard.
    while (listening.value && !identical(_listener, owner)) {
      await _whenNotListening();
      if (!identical(owner, _owner)) return;
    }
    await _ready;
    if (!identical(owner, _owner)) return;
    await _queue.say(text, interrupt: interrupt);
  }

  Future<void> _whenNotListening() {
    final done = Completer<void>();
    void check() {
      if (listening.value) return;
      listening.removeListener(check);
      if (!done.isCompleted) done.complete();
    }

    listening.addListener(check);
    check();
    return done.future;
  }
}

/// A screen's right to speak, from [AppVoice.claim]. Once another screen
/// claims the voice, this one's sentences are dropped.
class VoiceOwner {
  VoiceOwner._(this._voice);

  final AppVoice _voice;

  bool get isCurrent => identical(_voice._owner, this);

  /// Says [text] after anything queued before it, and returns once it has
  /// been said (or dropped). With [interrupt], what's being said or waiting
  /// is dropped first.
  Future<void> say(String text, {bool interrupt = false}) =>
      _voice._say(this, text, interrupt);

  /// The microphone is open for this owner; nothing others say is heard
  /// until [endListening].
  void beginListening() {
    if (isCurrent) _voice._setListener(this);
  }

  void endListening() {
    if (identical(_voice._listener, this)) _voice._setListener(null);
  }

  /// Silences this owner's speech, if it still owns the voice.
  void stop() {
    if (isCurrent) _voice._interrupt();
  }

  /// Gives the voice up: what this owner was saying stops, and nothing it
  /// says afterwards is heard.
  void release() {
    endListening();
    if (!isCurrent) return;
    _voice._interrupt();
    _voice._owner = null;
  }
}
