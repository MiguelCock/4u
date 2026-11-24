import 'dart:async';

import 'package:eyes4u/voice/app_voice.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// A recognizer that listens when asked, and hears what a test says.
class FakeSpeech extends Fake implements SpeechToText {
  @override
  SpeechStatusListener? statusListener;
  @override
  SpeechErrorListener? errorListener;

  bool available = true;
  int listens = 0;
  bool _on = false;
  SpeechResultListener? _onResult;

  @override
  bool get isListening => _on;

  @override
  Future<bool> initialize({
    SpeechErrorListener? onError,
    SpeechStatusListener? onStatus,
    debugLogging = false,
    Duration finalTimeout = const Duration(milliseconds: 2000),
    List<SpeechConfigOption>? options,
  }) async => available;

  @override
  Future<List<LocaleName>> locales() async => [LocaleName('es_CO', 'Español')];

  @override
  Future listen({
    SpeechResultListener? onResult,
    Duration? listenFor,
    Duration? pauseFor,
    String? localeId,
    SpeechSoundLevelChange? onSoundLevelChange,
    cancelOnError = false,
    partialResults = true,
    onDevice = false,
    ListenMode listenMode = ListenMode.confirmation,
    sampleRate = 0,
    SpeechListenOptions? listenOptions,
  }) async {
    listens++;
    _on = true;
    _onResult = onResult;
    _onSound = onSoundLevelChange;
    if (reportsListening) statusListener?.call('listening');
  }

  @override
  Future<void> cancel() async {
    cancels++;
    _on = false;
  }

  int cancels = 0;
  SpeechSoundLevelChange? _onSound;

  /// False: a listen opens without reporting "listening" (see [reportStart]),
  /// like a recognizer that hasn't started yet.
  bool reportsListening = true;
  void reportStart() => statusListener?.call('listening');

  /// A "done" from a listen that already ended, arriving late.
  void lateDone() => statusListener?.call('done');

  /// The recognizer offered [alternates] (words and confidence, its best
  /// guess first), with sound peaking at [soundPeak], and the listen ended.
  void hearAlternates(
    List<(String, double)> alternates, {
    double soundPeak = 6,
  }) {
    expect(_on, isTrue, reason: 'heard with the microphone closed');
    _on = false;
    _onSound?.call(soundPeak);
    _onResult?.call(
      SpeechRecognitionResult([
        for (final (words, confidence) in alternates)
          SpeechRecognitionWords(words, null, confidence),
      ], ResultType.finalResult.value),
    );
    statusListener?.call('done');
  }

  /// The user said [words] ('' for silence), and the listen ended.
  void hear(String words) {
    expect(_on, isTrue, reason: 'heard "$words" with the microphone closed');
    _on = false;
    _onResult?.call(
      SpeechRecognitionResult([
        SpeechRecognitionWords(words, null, 1),
      ], ResultType.finalResult.value),
    );
    statusListener?.call('done');
  }
}

/// A voice that takes 100 ms per sentence and remembers what it said.
class FakeVoice {
  final said = <String>[];
  late final AppVoice voice = AppVoice(
    speak: (text) async {
      said.add(text);
      voice.onStarted();
      Timer(const Duration(milliseconds: 100), voice.onEnded);
    },
    stop: () async {},
    configure: (_) async => true,
  );
}
