import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Asks for a connection's warning for users, starting from [initial].
/// Returns the text, or null when cancelled.
Future<String?> showConnectionWarningDialog(
  BuildContext context,
  String initial,
) => showDialog<String>(
  context: context,
  builder: (_) => _ConnectionWarningDialog(initial),
);

/// Owns its text controller, so it's disposed only once the dialog is gone.
/// Disposing it as soon as showDialog returned broke the closing animation,
/// which still draws the field (a red "_dependents.isEmpty" screen).
class _ConnectionWarningDialog extends StatefulWidget {
  final String initial;
  const _ConnectionWarningDialog(this.initial);

  @override
  State<_ConnectionWarningDialog> createState() =>
      _ConnectionWarningDialogState();
}

class _ConnectionWarningDialogState extends State<_ConnectionWarningDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.connectionWarningLabel),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 3,
        decoration: InputDecoration(helperText: l10n.connectionWarningHint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(MaterialLocalizations.of(context).saveButtonLabel),
        ),
      ],
    );
  }
}
