import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../l10n/app_localizations.dart';
import 'app_voice.dart';

/// Quick taps that stop the app's voice (D12 rule R8): three within
/// [SkipSpeech.window].
const int kSkipTaps = 3;

/// Wraps the whole app: tapping the screen [kSkipTaps] times quickly stops
/// what the app is saying ([AppVoice.skip]). A listen waiting on that
/// sentence then opens at once. The taps still reach what's under them.
///
/// With TalkBack on, its gestures never reach the app as taps, so the same
/// thing is [QuietAction], a custom action on the main buttons.
class SkipSpeech extends StatefulWidget {
  const SkipSpeech({
    super.key,
    required this.child,
    this.voice,
    this.window = const Duration(milliseconds: 1200),
  });

  final Widget child;
  final AppVoice? voice;

  /// How close together the taps must come.
  final Duration window;

  @override
  State<SkipSpeech> createState() => _SkipSpeechState();
}

class _SkipSpeechState extends State<SkipSpeech> {
  final List<DateTime> _taps = [];

  void _onDown(PointerDownEvent event) {
    final now = clock.now();
    _taps
      ..add(now)
      ..removeWhere((t) => now.difference(t) > widget.window);
    if (_taps.length >= kSkipTaps) {
      _taps.clear();
      (widget.voice ?? AppVoice.instance).skip();
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _onDown,
    child: widget.child,
  );
}

/// Adds "Quiet the app" to [child]'s actions for TalkBack (its actions
/// menu), doing what [SkipSpeech]'s taps do (D12 rule R8). Put it on the
/// control that has focus while the app talks: the Speak button, the trip's
/// Repeat button, a dialog's main button.
class QuietAction extends StatelessWidget {
  const QuietAction({super.key, required this.child, this.voice});

  final Widget child;
  final AppVoice? voice;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (l10n == null) return child;
    return MergeSemantics(
      child: Semantics(
        customSemanticsActions: {
          CustomSemanticsAction(label: l10n.voiceQuietAction): () =>
              (voice ?? AppVoice.instance).skip(),
        },
        child: child,
      ),
    );
  }
}
