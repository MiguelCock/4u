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

/// What the app does and how to use it, a page at a time, each shown and
/// read out by [voice] (not TalkBack: reading it as well spoke over it,
/// #257). The first user test had to explain every button by hand, and one
/// long paragraph was too much to take in at Icesi (2026-11-03).
Future<void> showHomeTutorial(
  BuildContext context, {
  required HomeVoiceController voice,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final pages = [
    l10n.homeTutorialPage1,
    l10n.homeTutorialPage2,
    l10n.homeTutorialPage3,
  ];
  for (var i = 0; i < pages.length && context.mounted; i++) {
    voice.say(pages[i]);
    final next = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: SpokenText(
          child: Text(
            '${l10n.homeTutorialTitle} '
            '(${l10n.homeTutorialProgress(i + 1, pages.length)})',
          ),
        ),
        content: SpokenText(
          child: SingleChildScrollView(
            child: Text(pages[i], style: const TextStyle(fontSize: 18)),
          ),
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(160, 56)),
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              i == pages.length - 1
                  ? l10n.homeTutorialDone
                  : l10n.homeTutorialNext,
            ),
          ),
        ],
      ),
    );
    if (next != true) break;
  }
  voice.stopSpeaking();
}
