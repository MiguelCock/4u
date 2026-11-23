import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/destination_matcher.dart';
import '../services/place_suggestions.dart' show asksForMore;
import '../voice/notices.dart' show SpokenText;
import '../voice/home_voice_controller.dart';
import '../voice/skip_speech.dart';

/// The home screen's questions (#268): which of several places, "Go to X?",
/// and which floor. Each is shown and spoken through [HomeVoiceController],
/// and, where [listen] is on, answered by voice too; the buttons are always
/// there to tap. Came out of `UserHomeScreen`.

/// Listening for a short answer (the number, yes or no).
const _kAnswerListenFor = Duration(seconds: 20);
const _kAnswerPauseFor = Duration(seconds: 3);

/// [chooseDestination]'s spoken "más": not an option's index, nor "none".
const _kMore = -2;

/// What [chooseDestination] ended with: an option, "none of them" (ask
/// again), "more" (the next few, D9), or none of these (closed).
typedef DestinationChoice = ({
  Map<String, dynamic>? picked,
  bool noneOfThem,
  bool more,
});

/// Several places matched: they're read out numbered ("1, Baño, Biblioteca;
/// 2, …"), then chosen by saying the number or the name (D1), or tapped.
/// [label] is what's shown, [spoken] what's read. [intro] says the list
/// ("Cerca hay: …"; by default "Encontré varios lugares: …"). With [more],
/// there are others after these: "más" (or the button) asks for them.
Future<DestinationChoice> chooseDestination(
  BuildContext context, {
  required HomeVoiceController voice,
  required String language,
  required List<Map<String, dynamic>> options,
  required String Function(Map<String, dynamic>) label,
  required String Function(Map<String, dynamic>) spoken,
  required bool listen,
  String Function(String options)? intro,
  bool more = false,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final labels = options.map(spoken).toList();
  const none = <String, dynamic>{};
  const moreOfThem = <String, dynamic>{'more': true};
  BuildContext? openSheet;
  () async {
    final list = [
      for (final (i, label) in labels.indexed) '${i + 1}, $label',
    ].join('; ');
    await voice.say((intro ?? l10n.homeVoiceSeveralMatches)(list));
    final sheet = openSheet;
    if (!listen || sheet == null || !sheet.mounted) return;
    await voice.askUntil<int>(
      (heard) =>
          more && asksForMore(heard) ? _kMore : pickSpokenOption(heard, labels),
      onAnswer: (picked) => Navigator.of(sheet).pop(
        picked == _kMore
            ? moreOfThem
            : picked < 0
            ? none
            : options[picked],
      ),
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
          if (more)
            ListTile(
              leading: const Icon(Icons.more_horiz),
              title: Text(l10n.homeMorePlacesButton),
              onTap: () => Navigator.of(context).pop(moreOfThem),
            ),
        ],
      ),
    ),
  );
  openSheet = null;
  voice.stopListening();
  if (identical(picked, moreOfThem)) {
    return (picked: null, noneOfThem: false, more: true);
  }
  return identical(picked, none)
      ? (picked: null, noneOfThem: true, more: false)
      : (picked: picked, noneOfThem: false, more: false);
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
        QuietAction(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size(220, 64),
              textStyle: Theme.of(dialogContext).textTheme.titleLarge,
            ),
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.directions_walk),
            label: Text(l10n.homeStartRouteButton),
          ),
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
