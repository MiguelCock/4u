import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../voice/home_voice_controller.dart';
import '../voice/notices.dart' show SpokenText;

/// The home screen's tutorial (#268): shown once on first launch, and from
/// "How does it work?". Came out of `UserHomeScreen`.

/// v3: the tutorial for the one-button, voice-first screen (D1).
const kTutorialSeenKey = 'tutorial_seen_v3';

/// True the first time it's asked, once per install, and marks it seen.
/// False without storage, so it doesn't nag on every launch.
Future<bool> firstRunTutorialDue() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(kTutorialSeenKey) ?? false) return false;
    await prefs.setBool(kTutorialSeenKey, true);
    return true;
  } catch (_) {
    return false;
  }
}

/// A tutorial page's buttons.
enum _Step { back, repeat, skip, next }

/// What the app does and how to use it, a page at a time, each shown and
/// read out by [voice] (not TalkBack: reading it as well spoke over it,
/// #257). The first user test had to explain every button by hand, and one
/// long paragraph was too much to take in at Icesi (2026-11-03).
///
/// Each page moves on by itself [pause] after its last word (#259): the
/// Next button was hard to find without sight. The last one ends the
/// tutorial, and the home screen goes on to ask for a destination. Back,
/// Repeat and Skip stay, and Next still works for anyone faster.
Future<void> showHomeTutorial(
  BuildContext context, {
  required HomeVoiceController voice,
  Duration pause = const Duration(milliseconds: 1500),
}) async {
  final l10n = AppLocalizations.of(context)!;
  final pages = [
    l10n.homeTutorialPage1,
    l10n.homeTutorialPage2,
    l10n.homeTutorialPage3,
  ];
  // Each page shown gets its own number, so a sentence that ends after its
  // page was left (back, repeat) doesn't move the next one on.
  var shown = 0;
  var i = 0;
  while (i < pages.length) {
    if (!context.mounted) break;
    final id = ++shown;
    // The page this dialog shows, fixed: `i` moves on as it closes.
    final page = i;
    BuildContext? dialog;
    final step = showDialog<_Step>(
      context: context,
      builder: (dialogContext) {
        dialog = dialogContext;
        void choose(_Step step) {
          voice.stopSpeaking();
          Navigator.of(dialogContext).pop(step);
        }

        final last = page == pages.length - 1;
        return AlertDialog(
          title: SpokenText(
            child: Text(
              '${l10n.homeTutorialTitle} '
              '(${l10n.homeTutorialProgress(page + 1, pages.length)})',
            ),
          ),
          content: SpokenText(
            child: SingleChildScrollView(
              child: Text(pages[page], style: const TextStyle(fontSize: 18)),
            ),
          ),
          actionsOverflowButtonSpacing: 8,
          actions: [
            if (page > 0)
              TextButton(
                onPressed: () => choose(_Step.back),
                child: Text(l10n.homeTutorialBack),
              ),
            TextButton(
              onPressed: () => choose(_Step.repeat),
              child: Text(l10n.homeTutorialRepeat),
            ),
            if (!last)
              TextButton(
                onPressed: () => choose(_Step.skip),
                child: Text(l10n.homeTutorialSkip),
              ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(160, 56)),
              autofocus: true,
              onPressed: () => choose(_Step.next),
              child: Text(last ? l10n.homeTutorialDone : l10n.homeTutorialNext),
            ),
          ],
        );
      },
    );
    voice.say(pages[page]).then((_) async {
      await Future<void>.delayed(pause);
      final open = dialog;
      if (id == shown && open != null && open.mounted) {
        Navigator.of(open).pop(_Step.next);
      }
    });
    switch (await step) {
      case _Step.next:
        i++;
      case _Step.back:
        i--;
      case _Step.repeat:
        break;
      case _Step.skip || null:
        // Skipped, or closed with system back.
        i = pages.length;
    }
  }
  voice.stopSpeaking();
}
