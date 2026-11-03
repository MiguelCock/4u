import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/location_types.dart';

/// Confirmations for admin choices that look like mistakes but are
/// sometimes deliberate (see `lib/services/capture_checks.dart`).

/// A name on an in-between type hides the point from users. True to save
/// it as it is; false sends the admin back to change the type.
Future<bool> confirmInBetweenName(
  BuildContext context, {
  required String name,
  required int locationTypeId,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final type = locationTypeLabel(l10n, kLocationTypes[locationTypeId]!);
  final keep = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.captureNamedHallwayTitle),
      content: Text(l10n.captureNamedHallwayBody(name, type)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.captureNamedHallwayKeep(type)),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.captureNamedHallwayChangeType),
        ),
      ],
    ),
  );
  return keep ?? false;
}

/// Verifying a point with no connections: users can neither reach it nor
/// start from it, which is what broke route-finding at Icesi.
Future<bool> confirmVerifyUnconnected(
  BuildContext context, {
  required String name,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final verify = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.verifyUnconnectedTitle),
      content: Text(l10n.verifyUnconnectedBody(name)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.verifyUnconnectedConfirm),
        ),
      ],
    ),
  );
  return verify ?? false;
}
