import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/floor_view.dart';
import '../../services/location_types.dart';
import '../../theme/admin_palette.dart';
import '../../widgets/category_mark.dart';
import '../edit_anchor_point_screen.dart' show anchorStatusLabel;

/// One of a details sheet's buttons.
typedef DetailsAction = ({IconData icon, String label, VoidCallback onTap});

/// A details sheet's buttons: each closes the sheet ([close]), then acts.
class DetailsActions extends StatelessWidget {
  const DetailsActions({super.key, required this.actions, required this.close});

  final List<DetailsAction> actions;
  final VoidCallback close;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 4,
    children: [
      for (final a in actions)
        TextButton.icon(
          icon: Icon(a.icon),
          label: Text(a.label),
          onPressed: () {
            close();
            a.onTap();
          },
        ),
    ],
  );
}

/// A point's data and actions: the map's sheet, or the map's side panel.
class PointDetails extends StatelessWidget {
  const PointDetails({
    super.key,
    required this.point,
    required this.building,
    required this.photos,
    required this.actions,
    required this.close,
  });

  final Map<String, dynamic> point;
  final Map<String, dynamic>? building;
  final List<Map<String, dynamic>> photos;
  final List<DetailsAction> actions;
  final VoidCallback close;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final type = kLocationTypes[point['location_type_id'] as int?];
    final thumbUrl = photos.isNotEmpty
        ? photos.first['image_url'] as String?
        : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (thumbUrl != null)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.network(
                    thumbUrl,
                    width: 64,
                    height: 64,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CategoryTitle(
                    anchorDisplayName(l10n, point),
                    locationTypeId: point['location_type_id'] as int?,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    [
                      if (type != null) locationTypeLabel(l10n, type),
                      building?['name'] as String? ??
                          l10n.commonUnknownBuilding,
                      l10n.adminStatusLabel(
                        anchorStatusLabel(
                          l10n,
                          point['status'] as String? ?? 'unknown',
                        ),
                      ),
                      l10n.adminPhotoCountLabel(photos.length),
                    ].join(' · '),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        DetailsActions(actions: actions, close: close),
      ],
    );
  }
}

/// A university's data and actions on the map.
class PlaceDetails extends StatelessWidget {
  const PlaceDetails({
    super.key,
    required this.place,
    required this.buildingCount,
    required this.actions,
    required this.close,
  });

  final Map<String, dynamic> place;
  final int buildingCount;
  final List<DetailsAction> actions;
  final VoidCallback close;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final active = place['is_active'] as bool? ?? true;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            Icons.flag,
            color: active ? kAdminPalette.university : kAdminPalette.inactive,
          ),
          title: Text(place['name'] as String? ?? ''),
          subtitle: Text(
            [
              if (place['code'] case final String code) code,
              l10n.adminBuildingCountLabel(buildingCount),
              if (!active) l10n.adminMapInactive,
            ].join(' · '),
          ),
        ),
        DetailsActions(actions: actions, close: close),
      ],
    );
  }
}

/// A building's data and actions on the map.
class BuildingDetails extends StatelessWidget {
  const BuildingDetails({
    super.key,
    required this.building,
    required this.place,
    required this.pointCount,
    required this.actions,
    required this.close,
  });

  final Map<String, dynamic> building;
  final Map<String, dynamic>? place;
  final int pointCount;
  final List<DetailsAction> actions;
  final VoidCallback close;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final active = building['is_active'] as bool? ?? true;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            Icons.apartment,
            color: active ? kAdminPalette.building : kAdminPalette.inactive,
          ),
          title: Text(building['name'] as String? ?? ''),
          subtitle: Text(
            [
              place?['name'] as String? ?? l10n.commonUnknownUniversity,
              if (building['floors'] case final int floors)
                l10n.adminMapFloorsLabel(floors),
              l10n.adminAnchorCountLabel(pointCount),
              if (!active) l10n.adminMapInactive,
            ].join(' · '),
          ),
        ),
        DetailsActions(actions: actions, close: close),
      ],
    );
  }
}

/// A connection's data and actions: its ends ([title]), distance (typed
/// or measured), whether it changes floor, and the warning for users.
class ConnectionDetails extends StatelessWidget {
  const ConnectionDetails({
    super.key,
    required this.connection,
    required this.title,
    required this.a,
    required this.b,
    required this.actions,
    required this.close,
  });

  final Map<String, dynamic> connection;
  final String title;

  /// Its two points, when they're loaded.
  final Map<String, dynamic>? a;
  final Map<String, dynamic>? b;
  final List<DetailsAction> actions;
  final VoidCallback close;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final c = connection;
    final meters = (c['distance_meters'] as num?)?.toStringAsFixed(1);
    final notes = (c['notes'] as String? ?? '').trim();
    final a = this.a;
    final b = this.b;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.timeline, color: kAdminPalette.connectionActive),
          title: Text(title),
          subtitle: Text(
            [
              if (meters != null)
                c['distance_manual'] == true
                    ? l10n.adminConnectionDistanceTyped(meters)
                    : l10n.adminConnectionDistance(meters),
              if (a != null && b != null && pointFloor(a) != pointFloor(b))
                l10n.adminConnectionChangesFloor,
              notes.isEmpty
                  ? l10n.adminConnectionNoWarning
                  : l10n.adminConnectionWarning(notes),
            ].join('\n'),
          ),
        ),
        DetailsActions(actions: actions, close: close),
      ],
    );
  }
}
