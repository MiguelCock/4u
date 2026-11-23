import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/anchor_indexing.dart';
import '../services/api_error_messages.dart';
import '../services/api_service.dart';
import '../widgets/admin_dialogs.dart';
import '../widgets/connection_warning_dialog.dart';
import '../widgets/guardrail_dialogs.dart';
import '../widgets/map_conflict.dart';
import 'admin_map_data.dart';

/// What the admin home does to the map (Phase D): deletes with their
/// cascade counts, verifying and unverifying with photo search, a
/// connection's warning, and re-indexing. Each asks or reports in
/// [BuildContext] given (the admin home's), then [reload]s.
class AdminActions {
  AdminActions({
    required this.mapApi,
    required this.aiTrainingApi,
    required this.data,
    required this.reload,
    required this.pointLabel,
    required this.onReindexing,
  });

  final MapManagementApi mapApi;
  final AiTrainingApi aiTrainingApi;
  final AdminMapData data;

  /// Fetches what changed, after an edit.
  final Future<void> Function() reload;

  /// A point as admins see it: its name, then its building.
  final String Function(Map<String, dynamic>? point) pointLabel;

  /// Re-indexing started (true) or ended (false).
  final void Function(bool running) onReindexing;

  /// Re-sends every verified point with photos to the search index. Points
  /// verified while indexing was failing were never searchable, and
  /// re-saving each one by hand is slow.
  /// Sends to `/index_anchor` the verified points with a photo that isn't
  /// searchable yet (`/index_status`; all of them if that can't be read),
  /// retrying each failure twice, then lists the points that still failed.
  Future<void> reindexVerified(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    // First drop index entries that shouldn't be there (deleted photos,
    // unverified points); best effort, older servers lack it.
    try {
      await aiTrainingApi.post('/reconcile', {});
    } on ApiException {
      // Re-indexing below still helps.
    }
    final indexed = await fetchIndexedPhotoIds(aiTrainingApi);
    if (!context.mounted) return;
    final targets = pointsMissingFromIndex(
      data.anchorPoints,
      data.lists.photosOf,
      indexed,
    );
    if (targets.isEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            indexed == null
                ? l10n.adminReindexNothing
                : l10n.adminReindexAllSearchable,
          ),
        ),
      );
      data.unsearchablePhotos = 0;
      return;
    }
    onReindexing(true);
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.adminReindexRunning(targets.length))),
    );
    var ok = 0;
    Object? lastError;
    final failed = <Map<String, dynamic>>[];
    for (final point in targets) {
      var done = false;
      for (var attempt = 0; attempt < 3 && !done; attempt++) {
        try {
          await indexAnchorPoint(
            aiTrainingApi,
            point,
            data.lists.photosOf(point['id'] as String),
          );
          done = true;
        } on ApiException catch (e) {
          lastError = e;
        }
      }
      if (done) {
        ok++;
      } else {
        failed.add(point);
      }
    }
    if (!context.mounted) return;
    onReindexing(false);
    messenger.hideCurrentSnackBar();
    data.refreshIndexStatus();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.adminReindexResultTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.adminReindexDone(ok, targets.length)),
              if (failed.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  l10n.adminReindexFailedList(
                    friendlyApiErrorMessage(context, lastError!),
                  ),
                ),
                for (final point in failed) Text('• ${pointLabel(point)}'),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
        ],
      ),
    );
  }

  /// Deletes in the database first; [afterSuccess] (removing the points
  /// from photo search) runs only once that worked. The other way round, a
  /// delete that failed left points listed but no longer recognisable.
  Future<void> _runDelete(
    BuildContext context,
    Future<void> Function() action, {
    Future<void> Function()? afterSuccess,
  }) async {
    try {
      await action();
      if (afterSuccess != null) await _bestEffort(afterSuccess);
      await reload();
    } on ApiException catch (e) {
      if (context.mounted) {
        showApiError(
          context,
          e,
          AppLocalizations.of(context)!.commonErrorDeleteFailed,
        );
      }
    }
  }

  /// Qdrant cleanup that never blocks or surfaces as the "delete failed"
  /// error - the Postgres delete succeeding is what the confirmation dialog
  /// and reload actually depend on; leaving a few stale vectors behind on a
  /// bad day is far better than refusing to delete.
  Future<void> _bestEffort(Future<void> Function() action) async {
    try {
      await action();
    } on ApiException {
      // Swallowed - see doc comment above.
    }
  }

  Future<void> deletePlace(
    BuildContext context,
    Map<String, dynamic> place,
  ) async {
    final cascade = data.lists.placeCascade(place['id'] as String);
    final buildings = cascade.buildings;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await confirmAction(
      context,
      title: l10n.adminDeletePlaceTitle,
      content:
          l10n.adminDeletePlaceContent(
            place['name'] as String? ?? place['id'] as String,
            buildings.length,
            cascade.anchors.length,
            cascade.photos,
            cascade.connections,
          ) +
          l10n.adminDeleteKeepsHistoryNote,
    );
    if (!confirmed || !context.mounted) return;
    await _runDelete(
      context,
      () => mapApi.delete('/places/${place['id']}'),
      afterSuccess: () => Future.wait(
        buildings.map(
          (b) => aiTrainingApi.delete('/index_building/${b['id']}'),
        ),
      ),
    );
  }

  Future<void> deleteBuilding(
    BuildContext context,
    Map<String, dynamic> building,
  ) async {
    final cascade = data.lists.buildingCascade(building['id'] as String);
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await confirmAction(
      context,
      title: l10n.adminDeleteBuildingTitle,
      content:
          l10n.adminDeleteBuildingContent(
            building['name'] as String? ?? building['id'] as String,
            cascade.anchors.length,
            cascade.photos,
            cascade.connections,
          ) +
          l10n.adminDeleteKeepsHistoryNote,
    );
    if (!confirmed || !context.mounted) return;
    await _runDelete(
      context,
      () => mapApi.delete('/buildings/${building['id']}'),
      afterSuccess: () =>
          aiTrainingApi.delete('/index_building/${building['id']}'),
    );
  }

  Future<void> deleteAnchorPoint(
    BuildContext context,
    Map<String, dynamic> point,
  ) async {
    final photoCount = data.lists.photosOf(point['id'] as String).length;
    final connectionCount = data.lists
        .connectionsOf(point['id'] as String)
        .length;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await confirmAction(
      context,
      title: l10n.adminDeleteAnchorTitle,
      content:
          l10n.adminDeleteAnchorContent(photoCount, connectionCount) +
          l10n.adminDeleteKeepsHistoryNote,
    );
    if (!confirmed || !context.mounted) return;
    await _runDelete(
      context,
      () => mapApi.delete('/anchor-points/${point['id']}'),
      afterSuccess: () => aiTrainingApi.delete('/index_anchor/${point['id']}'),
    );
  }

  Future<void> deleteConnection(
    BuildContext context,
    Map<String, dynamic> connection,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await confirmAction(
      context,
      title: l10n.adminDeleteConnectionTitle,
      content: l10n.commonCannotBeUndone,
    );
    if (!confirmed || !context.mounted) return;
    await _runDelete(
      context,
      () => mapApi.delete('/anchor-point-connections/${connection['id']}'),
    );
  }

  /// The connection's warning for users ("three steps down"), spoken as
  /// they start walking it. Testers asked to be told about obstacles.
  Future<void> editConnectionWarning(
    BuildContext context,
    Map<String, dynamic> connection,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final notes = await showConnectionWarningDialog(
      context,
      connection['notes'] as String? ?? '',
    );
    if (notes == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await mapApi.patch('/anchor-point-connections/${connection['id']}', {
        'notes': notes,
      });
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.connectionWarningSaved)),
      );
      await reload();
    } on ApiException catch (e) {
      if (!context.mounted) return;
      showApiError(
        context,
        e,
        l10n.connectionWarningSaveFailed,
        messenger: messenger,
      );
    }
  }

  /// [scopedAnchorPoints] is the building-filtered (but not yet
  /// status-filtered) list - counts here must reflect whichever building
  /// is currently selected, not every building's anchor points, or an
  /// admin drilled into one building sees a global "Verified (47)" count
  /// that doesn't match anything on screen.
  /// Verify or unverify straight from the list or the map. Verifying needs
  /// at least one photo (the backend enforces it too) and adds the point to
  /// photo search; unverifying puts it back to pending and removes it.
  Future<void> setAnchorStatus(
    BuildContext context,
    Map<String, dynamic> point,
    String status,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final id = point['id'] as String;
    final name = pointLabel(point);
    final photos = data.lists.photosOf(id);
    void show(String text) => messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));

    if (status == 'verified' && photos.isEmpty) {
      show(l10n.editAnchorErrorVerifyNeedsPhoto);
      return;
    }
    if (status == 'verified' &&
        data.lists.connectionsOf(id).isEmpty &&
        !await confirmVerifyUnconnected(context, name: name)) {
      return;
    }
    if (!context.mounted) return;
    try {
      // A second admin verifying the same point finds out here, instead of
      // both seeming to succeed.
      final saved = await saveAnchorPoint(
        context,
        mapApi,
        id: point['id'] as String,
        original: point,
        changes: {'status': status},
        name: name,
      );
      if (!saved) {
        show(l10n.mapConflictKeptTheirs(name));
        await reload();
        return;
      }
    } on ApiException catch (e) {
      if (context.mounted) {
        show(
          l10n.editAnchorErrorUpdateFailed(friendlyApiErrorMessage(context, e)),
        );
      }
      return;
    }
    try {
      if (status == 'verified') {
        await indexAnchorPoint(aiTrainingApi, point, photos);
      } else {
        await aiTrainingApi.delete('/index_anchor/$id');
      }
      show(
        status == 'verified'
            ? l10n.adminAnchorVerifiedSnackbar(name)
            : l10n.adminAnchorUnverifiedSnackbar(name),
      );
    } on ApiException catch (e) {
      if (context.mounted) {
        final reason = friendlyApiErrorMessage(context, e);
        show(
          status == 'verified'
              ? l10n.editAnchorErrorIndexingFailed(reason)
              : l10n.editAnchorErrorUnindexFailed(reason),
        );
      }
    }
    await reload();
  }
}
