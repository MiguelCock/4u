import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../voice/notices.dart' show SpokenText;

/// "How did it go?" after a trip: a comment, or skip. The title is said
/// aloud just before by the trip's voice ([speak]), so TalkBack doesn't
/// read it as well (#257). A comment is sent best effort: it never blocks
/// leaving the screen.
Future<void> showTripFeedback(
  BuildContext context, {
  required NavigationManagementApi api,
  required String sessionId,
  required String? userId,
  required Future<void> Function(String text) speak,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final controller = TextEditingController();
  await speak(l10n.navFeedbackTitle);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: SpokenText(child: Text(l10n.navFeedbackTitle)),
      content: TextField(
        controller: controller,
        decoration: InputDecoration(hintText: l10n.navFeedbackHint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.navFeedbackSkip),
        ),
        TextButton(
          onPressed: () async {
            final comment = controller.text.trim();
            if (comment.isNotEmpty && userId != null) {
              try {
                await api.post('/feedback', {
                  'user_id': userId,
                  'session_id': sessionId,
                  'comment': comment,
                });
              } on ApiException catch (_) {
                // Best effort.
              }
            }
            if (context.mounted) Navigator.of(context).pop();
          },
          child: Text(l10n.navFeedbackSubmit),
        ),
      ],
    ),
  );
}
