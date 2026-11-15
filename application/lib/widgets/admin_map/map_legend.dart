import 'package:flutter/material.dart';

import '../../admin/edit_anchor_point_screen.dart' show anchorStatusLabel;
import '../../l10n/app_localizations.dart';
import '../../services/location_types.dart';
import '../../theme/admin_palette.dart';
import '../../theme/palette_checks.dart' show kMarkerCategories;

/// What the admin map's colours mean (C7, C8): the connection lengths, the
/// categories of named places and the review statuses.
Future<void> showMapLegend(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => const MapLegend(),
);

class MapLegend extends StatelessWidget {
  const MapLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final p = kAdminPalette;
    final heading = Theme.of(context).textTheme.titleSmall;
    Widget line(
      Color color,
      double width,
      String label, {
      bool dashed = false,
    }) => ListTile(
      dense: true,
      leading: SizedBox(
        width: 40,
        child: dashed
            ? Row(
                children: [
                  for (var i = 0; i < 3; i++) ...[
                    Container(width: 8, height: width, color: color),
                    const SizedBox(width: 5),
                  ],
                ],
              )
            : Container(height: width, color: color),
      ),
      title: Text(label),
    );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.adminMapLegend,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Text(l10n.adminLegendConnections, style: heading),
            line(p.connectionShort, 3, l10n.adminLegendShort),
            line(p.connectionMid, 5, l10n.adminLegendMid),
            line(p.connectionLong, 5, l10n.adminLegendLong),
            line(p.connectionTooLong, 5, l10n.adminLegendTooLong),
            line(
              p.connectionShort,
              3,
              l10n.adminLegendFloorChange,
              dashed: true,
            ),
            const SizedBox(height: 12),
            Text(l10n.adminLegendPlaces, style: heading),
            for (final category in kMarkerCategories)
              ListTile(
                dense: true,
                leading: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: p.category(category),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    locationTypeIcon(_exampleType(category)),
                    color: Colors.white,
                    size: 18,
                  ),
                ),
                title: Text(locationCategoryLabel(l10n, category)),
              ),
            Text(l10n.adminLegendPlacesHint),
            const SizedBox(height: 12),
            Text(l10n.adminLegendStatus, style: heading),
            for (final status in ['verified', 'pending', 'rejected'])
              ListTile(
                dense: true,
                leading: Icon(
                  status == 'rejected'
                      ? Icons.close
                      : status == 'verified'
                      ? Icons.circle
                      : Icons.circle_outlined,
                  color: p.status(status),
                ),
                title: Text(anchorStatusLabel(l10n, status)),
              ),
          ],
        ),
      ),
    );
  }
}

/// The first type of [category], whose icon stands for it in the legend.
String? _exampleType(LocationCategory category) {
  for (final type in kLocationTypeCatalog) {
    if (type.category == category) return type.key;
  }
  return null;
}
