import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Which floor of its building an anchor point is on. Stored 0-based
/// (`anchor_points.floor`, 0 = the ground floor) but shown 1-based ("Floor
/// 1" is the ground floor), the way floors are numbered in Colombia. Offers
/// one entry per floor of the building, plus the current value if it's
/// outside that range, so an existing point never loses its floor.
class FloorField extends StatelessWidget {
  final int value;
  final int buildingFloors;
  final ValueChanged<int> onChanged;

  const FloorField({
    super.key,
    required this.value,
    required this.buildingFloors,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final floors = {
      for (var i = 0; i < (buildingFloors < 1 ? 1 : buildingFloors); i++) i,
      value,
    }.toList()..sort();
    return DropdownButtonFormField<int>(
      key: ValueKey('floor-$buildingFloors'),
      initialValue: value,
      decoration: InputDecoration(labelText: l10n.commonFloorLabel),
      items: [
        for (final floor in floors)
          DropdownMenuItem(
            value: floor,
            child: Text(l10n.commonFloorOption(floor + 1)),
          ),
      ],
      onChanged: (floor) {
        if (floor != null) onChanged(floor);
      },
    );
  }
}
