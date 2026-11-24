import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../services/app_preferences.dart' show voiceGuidanceNotifier;
import '../services/buzz.dart';
import 'app_voice.dart';

/// Cues that are instructions: a short vibration comes first, so a user
/// holding the phone in front (not at the ear) knows to listen.
const Set<String> kInstructionCues = {
  'turn',
  'leg',
  'turn_ahead',
  'hazard',
  'away',
  'slow_turn',
  'floor',
  'drift',
};

/// How the trip speaks (D12 rules R6 and R7): through the trip's
/// [VoiceOwner], logged, with a buzz before instructions, polite unless
/// it's safety, and with the last instruction kept for Repeat.
///
/// It came out of `NavigationScreen._speak` (#260, #269), so guidance can
/// be tested without the screen.
class TripAnnouncer {
  TripAnnouncer({
    required this._owner,
    required this._logCue,
    Future<void> Function(Buzz kind)? buzzer,
    ValueListenable<bool>? voiceOn,
    this.micOpen,
    this.closeMic,
  }) : _buzz = buzzer ?? buzz,
       _voiceOn = voiceOn ?? voiceGuidanceNotifier;

  /// Whether the trip's microphone is open (a spoken command, #228): then
  /// nothing is said into it (R4). A safety message closes it first
  /// ([closeMic]); anything else is logged and kept for Repeat, not said.
  final ValueListenable<bool>? micOpen;
  final void Function()? closeMic;

  /// Guidance paused by the user (#228): cues are logged and kept, but
  /// neither said nor buzzed, until [resume]. Safety and endings
  /// (assertive) are still said.
  bool get paused => _paused;
  bool _paused = false;

  final VoiceOwner _owner;
  final void Function(String type, String text) _logCue;
  final Future<void> Function(Buzz kind) _buzz;

  /// The user's voice guidance setting: off, cues are still logged and
  /// buzzed, but not spoken.
  final ValueListenable<bool> _voiceOn;

  /// The last instruction said, for Repeat and the wrong-instruction
  /// report. Notices aren't instructions ([speak]'s `repeatable`).
  String? lastAnnouncement;

  /// What kind of cue [lastAnnouncement] was (turn, start_walking, leg,
  /// meters_ahead, arrival, start...).
  String? lastCueType;

  /// When anything was last said, notices included.
  DateTime? lastSpokenAt;

  /// Says [text], after what's queued. [assertive] drops what's queued
  /// first: only for safety (a covered camera) and requested repeats (R6).
  /// Returns once said, dropped or skipped.
  Future<void> speak(
    String text, {
    bool assertive = false,
    String cueType = 'info',
    bool repeatable = true,
  }) async {
    if (repeatable) {
      lastAnnouncement = text;
      lastCueType = cueType;
    }
    final quiet = _paused && !assertive;
    if (quiet) {
      _logCue(cueType, text);
      return;
    }
    lastSpokenAt = clock.now();
    if (kInstructionCues.contains(cueType)) {
      _buzz(Buzz.short);
    } else if (cueType == 'start_walking') {
      // The "I'll vibrate when you face the right way" of SlowTurnCue.
      _buzz(Buzz.long);
    }
    _logCue(cueType, text);
    if (!_voiceOn.value) return;
    if (micOpen?.value ?? false) {
      if (!assertive) return;
      closeMic?.call();
    }
    await _owner.say(text, interrupt: assertive);
  }

  /// Says the last instruction again, at once (R7), after [prefix]
  /// ("Repito: ", #228) so it's never taken for a new one, and returns what
  /// was said; null when nothing has been said yet.
  String? repeat({String prefix = ''}) {
    final text = lastAnnouncement;
    if (text == null) return null;
    final said = '$prefix$text';
    speak(
      said,
      assertive: true,
      cueType: lastCueType ?? 'info',
      repeatable: false,
    );
    return said;
  }

  /// Stops the instructions until [resume] (#228). What's being said stops
  /// too; [notice] says so.
  Future<void> pause(String notice) async {
    _paused = true;
    _owner.stop();
    _logCue('pause', notice);
    if (_voiceOn.value) await _owner.say(notice);
  }

  /// Instructions again: [intro] ("Seguimos") then the current instruction.
  Future<void> resume(String intro) async {
    _paused = false;
    final text = lastAnnouncement;
    await speak(
      text == null ? intro : '$intro $text',
      cueType: 'resume',
      repeatable: false,
    );
  }

  /// The trip is over: what it was saying stops, and nothing more is heard.
  void release() => _owner.release();
}
