import 'dart:math';

import 'package:flutter/material.dart';
import '../voice/skip_speech.dart';

/// The home screen's one big Speak button (D1).
///
/// For the screen reader it is always the same button, with [label], and
/// always enabled (#257): its text changing to "Stop" as the microphone
/// opened, or turning disabled while a route was found, made TalkBack read
/// it again, and the microphone heard TalkBack instead of the user. The
/// screen still shows the change, and the click and vibration mark the
/// microphone opening.
class SpeakCircle extends StatelessWidget {
  final bool listening;

  /// A route is being found: taps do nothing.
  final bool busy;
  final String label;
  final String stopLabel;
  final VoidCallback onPressed;

  const SpeakCircle({
    super.key,
    required this.listening,
    required this.busy,
    required this.label,
    required this.stopLabel,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = min(320.0, MediaQuery.sizeOf(context).width * 0.85);
    void tap() {
      if (!busy) onPressed();
    }

    return QuietAction(
      child: Semantics(
        button: true,
        enabled: true,
        label: label,
        onTap: tap,
        excludeSemantics: true,
        child: SizedBox.square(
          dimension: size,
          child: FilledButton(
            style: FilledButton.styleFrom(
              shape: const CircleBorder(),
              backgroundColor: listening ? scheme.error : scheme.primary,
              foregroundColor: listening ? scheme.onError : scheme.onPrimary,
              padding: const EdgeInsets.all(24),
              textStyle: Theme.of(context).textTheme.headlineSmall,
            ),
            onPressed: busy ? null : onPressed,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(listening ? Icons.stop_rounded : Icons.mic, size: 96),
                const SizedBox(height: 8),
                Text(
                  listening ? stopLabel : label,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
