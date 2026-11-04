import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../services/floor_view.dart';

/// Points on the floor above and below the one a map is showing. Shape as well
/// as color (see [floorPointMarker]), for colorblind admins.
const Color kFloorAboveColor = Colors.purple;
const Color kFloorBelowColor = Colors.deepOrange;

/// A point on the floor directly above or below the selected one.
Marker floorPointMarker(LatLng point, FloorRelation relation) {
  final above = relation == FloorRelation.above;
  return Marker(
    point: point,
    width: 32,
    height: 32,
    child: Icon(
      above ? Icons.arrow_drop_up : Icons.arrow_drop_down,
      color: above ? kFloorAboveColor : kFloorBelowColor,
      size: 32,
    ),
  );
}

const _kOnlySelectedKey = 'map_only_selected_floor';

/// "Only this floor", remembered per device.
Future<bool> loadOnlySelectedFloor() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kOnlySelectedKey) ?? false;
  } catch (_) {
    return false;
  }
}

Future<void> saveOnlySelectedFloor(bool value) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOnlySelectedKey, value);
  } catch (_) {
    // A convenience: it just won't be remembered.
  }
}

/// Like elevator buttons, over a map: up, the floor being shown, down, and
/// "only this floor". [floors] gives the range; a floor in between with no
/// points can still be selected. Takes no space when there's a single floor.
class FloorSelector extends StatelessWidget {
  final List<int> floors;
  final int selected;
  final bool onlySelected;
  final ValueChanged<int> onFloorChanged;
  final ValueChanged<bool>? onOnlySelectedChanged;

  /// False on a map with no adjacent-floor markers: no legend or toggle.
  final bool showAdjacent;

  const FloorSelector({
    super.key,
    required this.floors,
    required this.selected,
    required this.onlySelected,
    required this.onFloorChanged,
    this.onOnlySelectedChanged,
    this.showAdjacent = true,
  });

  @override
  Widget build(BuildContext context) {
    if (floors.length < 2) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final canGoUp = selected < floors.last;
    final canGoDown = selected > floors.first;
    Widget legend(IconData icon, Color color, int floor) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 18),
        Text(
          l10n.commonFloorOption(floor + 1),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
    return Card(
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_up),
              iconSize: 32,
              tooltip: l10n.mapFloorUp,
              onPressed: canGoUp ? () => onFloorChanged(selected + 1) : null,
            ),
            Semantics(
              liveRegion: true,
              child: Text(
                l10n.commonFloorOption(selected + 1),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down),
              iconSize: 32,
              tooltip: l10n.mapFloorDown,
              onPressed: canGoDown ? () => onFloorChanged(selected - 1) : null,
            ),
            if (showAdjacent && !onlySelected && canGoUp)
              legend(Icons.arrow_drop_up, kFloorAboveColor, selected + 1),
            if (showAdjacent && !onlySelected && canGoDown)
              legend(Icons.arrow_drop_down, kFloorBelowColor, selected - 1),
            if (showAdjacent) ...[
              const SizedBox(height: 4),
              FilterChip(
                label: Text(l10n.mapOnlyThisFloor),
                selected: onlySelected,
                visualDensity: VisualDensity.compact,
                onSelected: onOnlySelectedChanged,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
