import 'package:flutter/material.dart';

import '../admin/edit_anchor_point_screen.dart' show anchorStatusLabel;
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/location_types.dart';
import '../services/map_sync.dart';

/// Saves [changes] to an anchor point, with the values they were based on, so
/// another admin's edit is never silently overwritten (A5). On a conflict it
/// shows both versions and asks. Returns false when the admin kept the other
/// admin's version, and rethrows any other error. [id] is separate from
/// [original], which may hold only the edited fields: taking it from there
/// sent the edit screen's saves to `/anchor-points/null`, a 404.
Future<bool> saveAnchorPoint(
  BuildContext context,
  ApiService api, {
  required String id,
  required Map<String, dynamic> original,
  required Map<String, dynamic> changes,
  required String name,
}) async {
  final path = '/anchor-points/$id';
  try {
    await api.patch(path, {
      ...changes,
      'expected': expectedFor(original, changes),
    });
    return true;
  } on ApiException catch (error) {
    final conflict = MapConflict.of(error);
    if (conflict == null || !context.mounted) rethrow;
    final saveMine = await showMapConflictDialog(
      context,
      conflict: conflict,
      changes: changes,
      name: name,
    );
    if (saveMine != true) return false;
    await api.patch(path, changes);
    return true;
  }
}

/// True to save over the other admin's change, false or null to keep it.
Future<bool?> showMapConflictDialog(
  BuildContext context, {
  required MapConflict conflict,
  required Map<String, dynamic> changes,
  required String name,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.mapConflictTitle),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.mapConflictBody(name)),
            const SizedBox(height: 12),
            for (final row in conflictRows(l10n, conflict, changes))
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(row.label),
                subtitle: Text(
                  l10n.mapConflictTheirsYours(row.theirs, row.yours),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.mapConflictKeepTheirs),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.mapConflictSaveMine),
        ),
      ],
    ),
  );
}

class ConflictRow {
  const ConflictRow(this.label, this.theirs, this.yours);

  final String label;
  final String theirs;
  final String yours;
}

/// One row per thing that differs, in words: latitude and longitude are one
/// "Position", shown as moved rather than as coordinates.
List<ConflictRow> conflictRows(
  AppLocalizations l10n,
  MapConflict conflict,
  Map<String, dynamic> changes,
) {
  String show(String field, Object? value) {
    if (value == null || value == '') return l10n.mapConflictEmpty;
    return switch (field) {
      'status' => anchorStatusLabel(l10n, value as String),
      'location_type_id' => locationTypeLabel(
        l10n,
        kLocationTypes[value as int] ?? '$value',
      ),
      'floor' => '${(value as num).toInt() + 1}',
      _ => '$value',
    };
  }

  final rows = <ConflictRow>[];
  final fields = conflict.fields.toSet();
  if (fields.remove('latitude') | fields.remove('longitude')) {
    rows.add(
      ConflictRow(
        l10n.mapConflictFieldPosition,
        l10n.mapConflictFieldPositionMoved,
        l10n.mapConflictFieldPositionMoved,
      ),
    );
  }
  for (final field in fields) {
    final label = switch (field) {
      'location_description' => l10n.mapConflictFieldDescription,
      'floor' => l10n.mapConflictFieldFloor,
      'location_type_id' => l10n.mapConflictFieldType,
      'status' => l10n.mapConflictFieldStatus,
      _ => l10n.mapConflictFieldDetails,
    };
    final details = field == 'metadata';
    rows.add(
      ConflictRow(
        label,
        details ? '…' : show(field, conflict.current[field]),
        details ? '…' : show(field, changes[field]),
      ),
    );
  }
  return rows;
}
