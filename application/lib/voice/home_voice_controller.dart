import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show SystemSound, SystemSoundType;
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../services/buzz.dart';
import '../services/speech_voice.dart';
import 'app_voice.dart';

/// How a call to [HomeVoiceController.listen] went.
enum ListenStart {
  /// The microphone is open; the answer goes to the callback.
  started,

  /// No recognizer or microphone on this phone. Retrying can't bring one
  /// back.
  unavailable,

  /// The screen was covered or closed before the microphone opened.
  gone,
}

/// The home screen's voice (#268): speaking, listening, their order, the
/// listen's timeout, the count of misses, and going quiet while a page
/// covers the screen. The first piece of D12's library (#260).
///
/// It came out of `UserHomeScreen`, where this state was mixed with the
/// destination and route logic, and bugs came from that mixing: #265's
/// flag was set in one method and cleared in only one of the others.
class HomeVoiceController {
  HomeVoiceController({
    SpeechToText? speech,
    AppVoice? voice,
    Future<void> Function()? marks,
  }) : _speech = speech ?? SpeechToText(),
       _appVoice = voice ?? AppVoice.instance,
       _marks = marks ?? _buzzAndClick {
    _owner = _appVoice.claim();
  }

  final SpeechToText _speech;
  final AppVoice _appVoice;

  /// Felt and heard just before the microphone opens. Once it's on,
  /// anything the app plays would be taken as speech.
  final Future<void> Function() _marks;

  static Future<void> _buzzAndClick() async {
    await buzz(Buzz.short);
    await SystemSound.play(SystemSoundType.click);
  }

  /// This screen's right to speak (the app's one voice, #258).
  late VoiceOwner _owner;
  bool _covered = false;
  bool _disposed = false;

  /// Whether the microphone is open, for the Speak button.
  final ValueNotifier<bool> listening = ValueNotifier(false);

  /// What the current listen has heard so far.
  String _heard = '';

  /// Who gets the current listen's answer; null when nobody is listening.
  /// The recognizer is one object for the whole app, and keeps the callbacks
  /// of its first `initialize` (speech_to_text 7.5). #225 passed a new
  /// callback each time, so every answer after the first, and every one after
  /// logging in again, went to a callback that was already done, and the
  /// button stayed on "Listening". Now the listeners are set before every
  /// listen, and they hand the answer to this field.
  Future<void> Function(String heard)? _onHeard;
  Timer? _listenTimeout;

  /// Whether the current listen has itself reported "listening". A listen
  /// that ended a moment ago still sends its "done" late, and it reached the
  /// next one (the "sí" at "Go to X?"), ending it at once with the old words.
  /// Until this is set, "done" and errors belong to an earlier listen.
  bool _listenSawStart = false;

  /// How many times in a row nothing usable was heard (see [missed]).
  int _misses = 0;

  /// Retries after the first try, before giving up.
  static const retries = 2;

  bool get isCovered => _covered;
  bool get isListening => listening.value;

  void setLanguage(String languageCode) => _appVoice.setLanguage(languageCode);

  /// Speaks [text] with the app's own voice, and returns once it's been
  /// said. Never over an open microphone: a sentence spoken while the
  /// recognizer is still closing is lost on Android ("Di sí…" after a
  /// place, "gira despacio" after "sí"). Nothing is said while covered.
  Future<void> say(String text, {bool interrupt = false}) async {
    if (listening.value || _speech.isListening) stopListening();
    for (var i = 0; i < 10 && _speech.isListening; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (_disposed || _covered) return;
    // Returns when the voice says this sentence is over, after any before it.
    await _owner.say(text, interrupt: interrupt);
  }

  /// Silences what's being said and waiting.
  void stopSpeaking() => _owner.stop();

  /// A miss: true to try again, false when the retries are used up (and
  /// the count starts over).
  bool missed() {
    _misses++;
    if (_misses > retries) {
      _misses = 0;
      return false;
    }
    return true;
  }

  /// Something usable was heard, or the user started over.
  void resetMisses() => _misses = 0;

  /// A page (a trip, Settings) now covers the screen: stop listening and
  /// give up the voice until [uncover].
  void cover() {
    _covered = true;
    stopListening();
    _owner.release();
  }

  void uncover() {
    _covered = false;
    _owner = _appVoice.claim();
  }

  /// A dialog or list closed, or a page covers the screen: an answer still
  /// on its way is for something that's gone.
  void stopListening() {
    _onHeard = null;
    _listenTimeout?.cancel();
    _setListening(false);
    _speech.cancel();
  }

  /// Stopped by hand (the Speak button): no answer and no retry, at once,
  /// whatever the recognizer does next. Then [stopped] is said.
  Future<void> stopListeningByHand(String stopped) async {
    _onHeard = null; // stopped on purpose: no answer, no retry
    _listenTimeout?.cancel();
    _setListening(false);
    _misses = 0;
    await _speech.cancel();
    await say(stopped, interrupt: true);
  }

  void _setListening(bool on) {
    if (on) {
      _owner.beginListening();
    } else {
      _owner.endListening();
    }
    if (!_disposed) listening.value = on;
  }

  void _finish(String heard) {
    final onHeard = _onHeard;
    _onHeard = null;
    _listenTimeout?.cancel();
    if (_disposed) return;
    _setListening(false);
    if (onHeard != null) onHeard(heard);
  }

  /// "done" comes after the final result, if there was one.
  void _onStatus(String status) {
    if (status == 'listening') _listenSawStart = true;
    if (status == 'done' && _listenSawStart) _finish(_heard);
  }

  void _onError(SpeechRecognitionError error) {
    if (_listenSawStart) _finish('');
  }

  /// The recognizer locale for [language] (es-CO first, like the voice), or
  /// null to let the phone use its default.
  Future<String?> _locale(String language) async {
    final available = {
      for (final l in await _speech.locales())
        l.localeId.replaceAll('_', '-').toLowerCase(): l.localeId,
    };
    for (final candidate in ttsLanguageCandidates(language)) {
      final match = available[candidate.toLowerCase()];
      if (match != null) return match;
    }
    for (final entry in available.entries) {
      if (entry.key.startsWith(language)) return entry.value;
    }
    return null;
  }

  /// Opens the microphone once, after saying [prompt] (what to say: a
  /// tester heard nothing and didn't know what to answer), with the marks
  /// just before (the recognizer isn't on yet, so it doesn't take them as
  /// speech). [onHeard] gets what was said once, '' for nothing.
  Future<ListenStart> listen(
    Future<void> Function(String heard) onHeard, {
    required String language,
    String? prompt,
    Duration listenFor = const Duration(seconds: 30),
    Duration pauseFor = const Duration(seconds: 5),
  }) async {
    if (_disposed) return ListenStart.gone;
    _speech.statusListener = _onStatus;
    _speech.errorListener = _onError;
    final available = await _speech.initialize(
      onStatus: _onStatus,
      onError: _onError,
    );
    if (_disposed) return ListenStart.gone;
    if (!available) {
      _misses = 0;
      return ListenStart.unavailable;
    }
    if (prompt != null) {
      await say(prompt);
      if (_disposed) return ListenStart.gone;
    }
    // The prompt has finished (its own end event): a short pause, and then
    // the marks and the microphone, always in that order.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (_disposed) return ListenStart.gone;
    final localeId = await _locale(language);
    if (_disposed) return ListenStart.gone;
    await _marks();
    return await _open(
          onHeard,
          localeId: localeId,
          listenFor: listenFor,
          pauseFor: pauseFor,
        )
        ? ListenStart.started
        : ListenStart.gone;
  }

  /// One recognizer session, no prompt and no marks. Silence ends it, and
  /// the caller says so: reopening quietly left people in a long silent
  /// cycle, with the button flickering.
  Future<bool> _open(
    Future<void> Function(String heard) onHeard, {
    required String? localeId,
    required Duration listenFor,
    required Duration pauseFor,
  }) async {
    // One listen at a time: the last one may still be closing.
    for (var i = 0; i < 10 && _speech.isListening; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_speech.isListening) await _speech.cancel();
    if (_disposed || _covered) return false;
    _heard = '';
    _setListening(true);
    _onHeard = onHeard;
    _listenSawStart = false;
    // If the recognizer never reports back, this still ends the listen.
    _listenTimeout?.cancel();
    _listenTimeout = Timer(
      listenFor + const Duration(seconds: 4),
      () => _finish(_heard),
    );
    try {
      await _speech.listen(
        onResult: (result) {
          if (_disposed) return;
          _heard = result.recognizedWords;
          if (result.finalResult) _finish(result.recognizedWords);
        },
        listenOptions: SpeechListenOptions(
          localeId: localeId,
          listenFor: listenFor,
          pauseFor: pauseFor,
          partialResults: true,
          cancelOnError: true,
        ),
      );
    } catch (_) {
      _finish('');
      return false;
    }
    return true;
  }

  void dispose() {
    _onHeard = null;
    _listenTimeout?.cancel();
    // The recognizer outlives the screen: leave it no callbacks into it.
    if (_speech.statusListener == _onStatus) {
      _speech.statusListener = null;
      _speech.errorListener = null;
    }
    _speech.cancel();
    _owner.release();
    _disposed = true;
    listening.dispose();
  }
}
