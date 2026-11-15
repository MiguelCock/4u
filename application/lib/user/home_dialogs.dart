import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/destination_matcher.dart';
import '../voice/notices.dart' show SpokenText;
import '../voice/home_voice_controller.dart';

/// The home screen's questions (#268): which of several places, "Go to X?",
/// and which floor. Each is shown and spoken through [HomeVoiceController],
/// and, where [listen] is on, answered by voice too; the buttons are always
/// there to tap. Came out of `UserHomeScreen`.

/// Listening for a short answer (the number, yes or no).
const _kAnswerListenFor = Duration(seconds: 20);
const _kAnswerPauseFor = Duration(seconds: 3);

/// What [chooseDestination] ended with: an option, "none of them" (ask
/// again), or neither (closed).
typedef DestinationChoice = ({Map<String, dynamic>? picked, bool noneOfThem});

/// Several places matched: they're read out numbered ("1, Baño, Biblioteca;
/// 2, …"), then chosen by saying the number or the name (D1), or tapped.
/// [label] is what's shown, [spoken] what's read.
Future<DestinationChoice> chooseDestination(
  BuildContext context, {
  required HomeVoiceController voice,
  required String language,
  required List<Map<String, dynamic>> options,
  required String Function(Map<String, dynamic>) label,
  required String Function(Map<String, dynamic>) spoken,
  required bool listen,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final labels = options.map(spoken).toList();
  const none = <String, dynamic>{};
  BuildContext? openSheet;
  () async {
    await voice.say(
      l10n.homeVoiceSeveralMatches(
        [
          for (final (i, label) in labels.indexed) '${i + 1}, $label',
        ].join('; '),
      ),
    );
    final sheet = openSheet;
    if (!listen || sheet == null || !sheet.mounted) return;
    await voice.askUntil<int>(
      (heard) => pickSpokenOption(heard, labels),
      onAnswer: (picked) =>
          Navigator.of(sheet).pop(picked < 0 ? none : options[picked]),
      language: language,
      notUnderstood: l10n.homeVoiceOptionNotUnderstood,
      giveUp: l10n.homeOptionsGiveUp, // the list is still there to tap
      stillOpen: () => openSheet?.mounted ?? false,
      listenFor: _kAnswerListenFor,
      pauseFor: _kAnswerPauseFor,
    );
  }();
  final picked = await showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Builder(
              builder: (_) {
                openSheet = context;
                // Read out with the options by the app's voice.
                return SpokenText(
                  child: Text(
                    l10n.homeVoiceChooseTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                );
              },
            ),
          ),
          for (final option in options)
            ListTile(
              leading: const Icon(Icons.location_on, color: Colors.blue),
              title: Text(label(option)),
              onTap: () => Navigator.of(context).pop(option),
            ),
        ],
      ),
    ),
  );
  openSheet = null;
  voice.stopListening();
  return identical(picked, none)
      ? (picked: null, noneOfThem: true)
      : (picked: picked, noneOfThem: false);
}

/// "Go to X?" with one big Start route button: true to start, false to
/// change the destination, null if closed. With [listen], "di sí para
/// empezar" is added and a spoken yes or no answers it (D1). In the first
/// user test people expected the route to start once they'd said the place.
/// [label] is what's shown, [spoken] what's read.
Future<bool?> confirmDestination(
  BuildContext context, {
  required HomeVoiceController voice,
  required String language,
  required String label,
  required String spoken,
  required bool listen,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final title = l10n.homeGoToTitle(label);
  BuildContext? openDialog;
  () async {
    await voice.say(
      listen
          ? '${l10n.homeGoToTitle(spoken)} ${l10n.homeSayYesToStart}'
          : l10n.homeGoToTitle(spoken),
    );
    // Saying "yes" starts it: the buttons stay for everyone else.
    final dialog = openDialog;
    if (!listen || dialog == null || !dialog.mounted) return;
    await voice.askUntil<SpokenAnswer>(
      spokenAnswer,
      onAnswer: (answer) =>
          Navigator.of(dialog).pop(answer == SpokenAnswer.start),
      language: language,
      notUnderstood: l10n.homeSayYesOrNo,
      giveUp: l10n.homeConfirmGiveUp, // the buttons are still there
      stillOpen: () => openDialog?.mounted ?? false,
      listenFor: _kAnswerListenFor,
      pauseFor: _kAnswerPauseFor,
    );
  }();
  final start = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Builder(
        builder: (context) {
          openDialog = dialogContext;
          // The app asks it aloud, then listens: TalkBack reading it too
          // was heard by the microphone as the answer (#257).
          return SpokenText(child: Text(title));
        },
      ),
      actionsAlignment: MainAxisAlignment.center,
      actionsOverflowDirection: VerticalDirection.up,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.homeChangeDestinationButton),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            minimumSize: const Size(220, 64),
            textStyle: Theme.of(dialogContext).textTheme.titleLarge,
          ),
          autofocus: true,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          icon: const Icon(Icons.directions_walk),
          label: Text(l10n.homeStartRouteButton),
        ),
      ],
    ),
  );
  openDialog = null;
  voice.stopListening();
  voice.stopSpeaking();
  return start;
}

/// "Which floor are you on?", spoken with its options, and one big button
/// per floor (0-based in [floors]). Null if they back out. GPS can't tell
/// floors apart, so the nearest point may be overhead.
Future<int?> askStartFloor(
  BuildContext context, {
  required HomeVoiceController voice,
  required List<int> floors,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final labels = [for (final f in floors) l10n.commonFloorOption(f + 1)];
  voice.say('${l10n.homeWhichFloorTitle} ${labels.join(', ')}.');
  final floor = await showDialog<int>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: SpokenText(child: Text(l10n.homeWhichFloorTitle)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < floors.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(64),
                  textStyle: Theme.of(dialogContext).textTheme.titleLarge,
                ),
                onPressed: () => Navigator.of(dialogContext).pop(floors[i]),
                child: Text(labels[i]),
              ),
            ),
        ],
      ),
    ),
  );
  voice.stopSpeaking();
  return floor;
}
