import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/location_types.dart';
import '../../theme/admin_palette.dart';
import '../../widgets/category_mark.dart';
import '../edit_anchor_point_screen.dart' show anchorStatusLabel;

/// An Anchor points row: its first photo, name, building, status and photo
/// count, with verify ([statusButton]), Edit, and Add photo and Delete in
/// a menu so the row isn't crowded. A tap connects from it on the map.
class AnchorPointRow extends StatelessWidget {
  const AnchorPointRow({
    super.key,
    required this.point,
    required this.building,
    required this.photos,
    required this.statusButton,
    required this.onTap,
    required this.onEdit,
    required this.onAddPhoto,
    required this.onDelete,
  });

  final Map<String, dynamic> point;
  final Map<String, dynamic>? building;
  final List<Map<String, dynamic>> photos;
  final Widget statusButton;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onAddPhoto;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final thumbUrl = photos.isNotEmpty
        ? photos.first['image_url'] as String?
        : null;
    return ListTile(
      onTap: onTap,
      leading: thumbUrl != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.network(
                thumbUrl,
                width: 40,
                height: 40,
                fit: BoxFit.cover,
              ),
            )
          : Icon(Icons.location_pin, color: kAdminPalette.verified),
      title: CategoryTitle(
        anchorDisplayName(l10n, point),
        locationTypeId: point['location_type_id'] as int?,
      ),
      subtitle: Text(
        '${building?['name'] as String? ?? l10n.commonUnknownBuilding} · '
        '${l10n.adminStatusLabel(anchorStatusLabel(l10n, point['status'] as String? ?? 'unknown'))} · '
        '${l10n.adminPhotoCountLabel(photos.length)}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          statusButton,
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: l10n.commonEdit,
            onPressed: onEdit,
          ),
          PopupMenuButton<String>(
            tooltip: l10n.adminMoreActionsTooltip,
            onSelected: (choice) =>
                choice == 'photo' ? onAddPhoto() : onDelete(),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'photo',
                child: ListTile(
                  leading: const Icon(Icons.add_a_photo_outlined),
                  title: Text(l10n.adminAddPhotoTooltip),
                ),
              ),
              PopupMenuItem(
                value: 'delete',
                child: ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: Text(l10n.commonDelete),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A Connections row: both ends, their buildings, the distance in the
/// map's colour for it (C7) and the warning for users. A tap edits the
/// warning.
class ConnectionRow extends StatelessWidget {
  const ConnectionRow({
    super.key,
    required this.connection,
    required this.nameOf,
    required this.buildingA,
    required this.buildingB,
    required this.onTap,
    required this.onShowOnMap,
    required this.onDelete,
  });

  final Map<String, dynamic> connection;

  /// A point's name by id (the id itself when it's gone).
  final String Function(String? pointId) nameOf;
  final Map<String, dynamic>? buildingA;
  final Map<String, dynamic>? buildingB;
  final VoidCallback onTap;
  final VoidCallback onShowOnMap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final meters = (connection['distance_meters'] as num?)?.toDouble();
    final distance = meters?.toStringAsFixed(1);
    return ListTile(
      leading: Icon(Icons.timeline, color: kAdminPalette.connectionActive),
      title: Text(
        '${nameOf(connection['anchor_point_a_id'] as String?)} '
        '↔ ${nameOf(connection['anchor_point_b_id'] as String?)}',
      ),
      subtitle: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text:
                  '${buildingA?['name'] as String? ?? l10n.commonUnknownBuilding} / '
                  '${buildingB?['name'] as String? ?? l10n.commonUnknownBuilding}',
            ),
            if (distance != null) ...[
              const TextSpan(text: ' · '),
              TextSpan(
                text: '${distance}m',
                style: TextStyle(
                  color: kAdminPalette.connectionFor(meters!),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
            if ((connection['notes'] as String? ?? '').isNotEmpty)
              TextSpan(text: '\n⚠ ${connection['notes']}'),
          ],
        ),
      ),
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.map_outlined),
            tooltip: l10n.adminMapShowOnMap,
            onPressed: onShowOnMap,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: l10n.commonDelete,
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
