import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// University and building dropdowns narrowing an admin list. A new
/// university resets the building, and the buildings offered are the
/// university's. Used by the Buildings (university only), Anchor points and
/// Connections tabs.
class ScopeDropdowns extends StatelessWidget {
  final List<Map<String, dynamic>> places;
  final List<Map<String, dynamic>> buildings;
  final String? placeId;
  final String? buildingId;

  /// Called with the new university and building (null: all).
  final void Function(String? placeId, String? buildingId) onChanged;

  /// False on the Buildings tab: only the university.
  final bool showBuilding;

  const ScopeDropdowns({
    super.key,
    required this.places,
    required this.buildings,
    required this.placeId,
    required this.buildingId,
    required this.onChanged,
    this.showBuilding = true,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    InputDecoration decoration(String label) => InputDecoration(
      labelText: label,
      isDense: true,
      border: const OutlineInputBorder(),
    );
    // A value no longer offered (deleted meanwhile) shows as "all".
    final place = places.any((p) => p['id'] == placeId) ? placeId : null;
    final offered = [
      for (final b in buildings)
        if (place == null || b['place_id'] == place) b,
    ];
    final building = offered.any((b) => b['id'] == buildingId)
        ? buildingId
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String?>(
              key: ValueKey('place-$place'),
              initialValue: place,
              isExpanded: true,
              decoration: decoration(l10n.commonUniversityLabel),
              items: [
                DropdownMenuItem(
                  value: null,
                  child: Text(l10n.commonStatusAll),
                ),
                for (final p in places)
                  DropdownMenuItem(
                    value: p['id'] as String,
                    child: Text(p['name'] as String? ?? ''),
                  ),
              ],
              onChanged: (id) => onChanged(id, null),
            ),
          ),
          if (showBuilding) ...[
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonFormField<String?>(
                // A new university resets the building list.
                key: ValueKey('building-$place-$building'),
                initialValue: building,
                isExpanded: true,
                decoration: decoration(l10n.commonBuildingLabel),
                items: [
                  DropdownMenuItem(
                    value: null,
                    child: Text(l10n.adminConnectionsAllBuildings),
                  ),
                  for (final b in offered)
                    DropdownMenuItem(
                      value: b['id'] as String,
                      child: Text(b['name'] as String? ?? ''),
                    ),
                ],
                onChanged: (id) {
                  // A building implies its university.
                  final chosen = offered.firstWhere(
                    (b) => b['id'] == id,
                    orElse: () => const {},
                  );
                  onChanged(chosen['place_id'] as String? ?? place, id);
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}
