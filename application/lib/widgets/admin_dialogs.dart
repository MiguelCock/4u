import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/api_error_messages.dart';

/// "Are you sure?" with Cancel and [confirmLabel] (Delete when not given).
/// True only when confirmed.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String content,
  String? confirmLabel,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel ?? l10n.commonDelete),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// A failed request, as a SnackBar: the screen's own [sentence] around the
/// error in plain words (friendlyApiErrorMessage). [messenger] when it was
/// taken before an `await`.
void showApiError(
  BuildContext context,
  Object error,
  String Function(String reason) sentence, {
  ScaffoldMessengerState? messenger,
}) {
  (messenger ?? ScaffoldMessenger.of(context)).showSnackBar(
    SnackBar(content: Text(sentence(friendlyApiErrorMessage(context, error)))),
  );
}
