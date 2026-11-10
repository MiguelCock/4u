import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/floor_view.dart';
import '../widgets/admin_map/admin_map.dart';
import '../widgets/admin_map/layers.dart';
import '../theme/admin_palette.dart';

/// Reusable "tap the map to pick a location" screen - pops with the tapped
/// `LatLng` on confirm, or `null` if the admin just backs out. Used by
/// AddPlaceScreen, AddBuildingScreen, and CaptureScreen so latitude/longitude
/// can be set by tapping a map instead of typing coordinates or relying only
/// on device GPS.
///
/// Optionally overlays existing places/buildings/anchor points (each caller
/// opts into whichever are relevant) so an admin can see duplicates and
/// coverage gaps while picking - building markers show a small badge with
/// their anchor-point count, place markers show their building count, and
/// anchor-point markers are colored by `status` (green = verified, grey =
/// pending, red = rejected). Built on [AdminMap] in pick mode (C3).
class LocationPickerScreen extends StatefulWidget {
  final LatLng initialPosition;
  final bool showPlaces;
  final bool showBuildings;
  final bool showAnchorPoints;

  /// When set, only anchor points belonging to this building are overlaid -
  /// used by `CaptureScreen`, where anchor points are always scoped to
  /// whichever building is currently selected in the form.
  final String? anchorPointsBuildingId;

  /// When set, only buildings belonging to this place are overlaid - used by
  /// `CaptureScreen`/`AddBuildingScreen`, where buildings are always scoped
  /// to whichever place is currently selected in the form.
  final String? buildingsPlaceId;

  /// The floor of the point being placed: the anchor points overlay opens
  /// on it. Changing floor here only changes the view.
  final int? initialFloor;

  /// Off in tests, which have no network for tiles.
  @visibleForTesting
  final bool showTiles;

  const LocationPickerScreen({
    super.key,
    required this.initialPosition,
    this.showPlaces = false,
    this.showBuildings = false,
    this.showAnchorPoints = false,
    this.anchorPointsBuildingId,
    this.buildingsPlaceId,
    this.initialFloor,
    this.showTiles = true,
  });

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  final _mapApi = MapManagementApi();
  late LatLng _picked;
  List<Map<String, dynamic>> _places = [];
  List<Map<String, dynamic>> _buildings = [];
  List<Map<String, dynamic>> _anchorPoints = [];

  @override
  void initState() {
    super.initState();
    _picked = widget.initialPosition;
    _loadOverlayData();
  }

  /// The overlay's floors, plus the one the new point is going on.
  List<int> get _floors =>
      {...floorsOf(_anchorPoints), ?widget.initialFloor}.toList()..sort();

  Future<void> _loadOverlayData() async {
    try {
      final results = await Future.wait([
        widget.showPlaces ? _mapApi.get('/places') : Future.value(const []),
        widget.showBuildings
            ? _mapApi.get('/buildings')
            : Future.value(const []),
        widget.showAnchorPoints
            ? _mapApi.get('/anchor-points')
            : Future.value(const []),
      ]);
      if (!mounted) return;
      final buildings = (results[1] as List).cast<Map<String, dynamic>>();
      final anchorPoints = (results[2] as List).cast<Map<String, dynamic>>();
      setState(() {
        _places = (results[0] as List).cast<Map<String, dynamic>>();
        _buildings = widget.buildingsPlaceId == null
            ? buildings
            : buildings
                  .where((b) => b['place_id'] == widget.buildingsPlaceId)
                  .toList();
        _anchorPoints = widget.anchorPointsBuildingId == null
            ? anchorPoints
            : anchorPoints
                  .where(
                    (p) => p['building_id'] == widget.anchorPointsBuildingId,
                  )
                  .toList();
      });
    } on ApiException {
      // Overlay data is a convenience, not required to pick a location -
      // fail silently and just show the pick marker on its own.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final buildingCounts = <String, int>{};
    for (final building in _buildings) {
      final placeId = building['place_id'] as String?;
      if (placeId == null) continue;
      buildingCounts[placeId] = (buildingCounts[placeId] ?? 0) + 1;
    }
    final pointCounts = <String, int>{};
    for (final point in _anchorPoints) {
      final buildingId = point['building_id'] as String?;
      if (buildingId == null) continue;
      pointCounts[buildingId] = (pointCounts[buildingId] ?? 0) + 1;
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.locationPickerTitle),
        actions: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(_picked),
            icon: const Icon(Icons.check),
            tooltip: l10n.locationPickerConfirmTooltip,
          ),
        ],
      ),
      body: AdminMap(
        showTiles: widget.showTiles,
        floors: _floors,
        focusFloor: widget.initialFloor,
        fitTo: [widget.initialPosition],
        fitMinZoom: 16,
        fitMaxZoom: 16,
        mode: AdminMapMode.pick,
        onTapPosition: (point) => setState(() => _picked = point),
        // Everything at every zoom: the picker shows what's around the spot.
        layers: [
          PlacesLayer(
            places: _places,
            buildingCounts: buildingCounts,
            maxZoom: double.infinity,
          ),
          BuildingsLayer(
            buildings: _buildings,
            pointCounts: pointCounts,
            minZoom: 0,
            maxZoom: double.infinity,
          ),
          PointsLayer(points: _anchorPoints),
          PinLayer(position: _picked, color: kAdminPalette.pickPin),
        ],
      ),
    );
  }
}
