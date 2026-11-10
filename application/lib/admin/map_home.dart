import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../l10n/app_localizations.dart';
import '../services/floor_view.dart';
import '../services/map_scope.dart';
import '../services/map_tap.dart';
import '../widgets/admin_map/admin_map.dart';
import '../widgets/admin_map/layers.dart';

/// The admin's first screen (C2): every university on a map. Tapping a
/// university fits its buildings, tapping a building fits its points, and
/// tapping a point opens its details. The search box finds any of the three,
/// and the breadcrumb goes back up. Details are a bottom sheet, or a side
/// panel when [sidePanel]. [scope] belongs to the caller, so system back can
/// go up a level too.
class MapHome extends StatefulWidget {
  final List<Map<String, dynamic>> places;
  final List<Map<String, dynamic>> buildings;
  final List<Map<String, dynamic>> points;
  final List<Map<String, dynamic>> connections;

  final MapScope scope;
  final ValueChanged<MapScope> onScopeChanged;

  /// A point being moved, as on the Anchor points map.
  final String? movingPointId;
  final LatLng? moveTarget;
  final ValueChanged<LatLng>? onMoveTargetTapped;

  /// What a university, building or point shows when opened. [close] hides
  /// the sheet or panel; actions call it first.
  final Widget Function(
    BuildContext context,
    AdminMapHit item,
    VoidCallback close,
  )
  details;

  final String Function(Map<String, dynamic> point) pointName;

  /// Details beside the map (a wide screen) instead of in a bottom sheet.
  final bool sidePanel;

  /// Room above the floor selector, for the move banner.
  final double controlsTop;

  @visibleForTesting
  final bool showTiles;

  const MapHome({
    super.key,
    required this.places,
    required this.buildings,
    required this.points,
    required this.connections,
    required this.scope,
    required this.onScopeChanged,
    required this.details,
    required this.pointName,
    this.movingPointId,
    this.moveTarget,
    this.onMoveTargetTapped,
    this.sidePanel = false,
    this.controlsTop = 8,
    this.showTiles = true,
  });

  @override
  State<MapHome> createState() => _MapHomeState();
}

/// What the camera frames for a scope: its items, kept in its zoom band.
typedef _Frame = ({List<LatLng> coordinates, double minZoom, double maxZoom});

class _MapHomeState extends State<MapHome> {
  final _controller = MapController();
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _hover = ValueNotifier<({String label, Offset at})?>(null);
  bool _ready = false;
  int? _focusFloor;

  /// Shown in the side panel.
  AdminMapHit? _selected;

  /// A searched point: the next fit centres on it instead.
  LatLng? _centerOn;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(MapHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.scope != oldWidget.scope) _fit();
  }

  @override
  void dispose() {
    _controller.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _hover.dispose();
    super.dispose();
  }

  Map<String, Map<String, dynamic>> get _placesById => {
    for (final p in widget.places) p['id'] as String: p,
  };
  Map<String, Map<String, dynamic>> get _buildingsById => {
    for (final b in widget.buildings) b['id'] as String: b,
  };

  /// The points of the scope: a building's, a university's, or all.
  List<Map<String, dynamic>> get _scopedPoints {
    final scope = widget.scope;
    if (scope.buildingId case final id?) {
      return [
        for (final p in widget.points)
          if (p['building_id'] == id) p,
      ];
    }
    if (scope.placeId case final id?) {
      final buildingIds = {
        for (final b in widget.buildings)
          if (b['place_id'] == id) b['id'],
      };
      return [
        for (final p in widget.points)
          if (buildingIds.contains(p['building_id'])) p,
      ];
    }
    return widget.points;
  }

  _Frame _frame() {
    List<LatLng> positions(Iterable<Map<String, dynamic>> rows) =>
        rows.map(anchorPosition).whereType<LatLng>().toList();
    final scope = widget.scope;
    if (scope.buildingId case final id?) {
      final inside = positions(_scopedPoints);
      return (
        coordinates: inside.isNotEmpty
            ? inside
            : positions([?_buildingsById[id]]),
        minZoom: kMapPointsZoom,
        maxZoom: 19,
      );
    }
    if (scope.placeId case final id?) {
      final inside = positions(
        widget.buildings.where((b) => b['place_id'] == id),
      );
      return (
        coordinates: inside.isNotEmpty ? inside : positions([?_placesById[id]]),
        minZoom: kMapBuildingsZoom,
        maxZoom: kMapPointsZoom - 0.5,
      );
    }
    final places = positions(widget.places);
    return (
      coordinates: places.isNotEmpty ? places : positions(widget.buildings),
      minZoom: 3,
      maxZoom: kMapBuildingsZoom - 0.5,
    );
  }

  /// Moves the camera to the scope, or to a searched point in it.
  void _fit() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_ready) return;
      final center = _centerOn;
      _centerOn = null;
      if (center != null) {
        _controller.move(center, 19);
        return;
      }
      final frame = _frame();
      if (frame.coordinates.isEmpty) return;
      if (frame.coordinates.length == 1) {
        _controller.move(frame.coordinates.single, frame.maxZoom);
        return;
      }
      _controller.fitCamera(
        CameraFit.coordinates(
          coordinates: frame.coordinates,
          padding: const EdgeInsets.all(48),
          minZoom: frame.minZoom,
          maxZoom: frame.maxZoom,
        ),
      );
    });
  }

  void _go(MapScope scope) {
    if (scope == widget.scope) {
      _fit();
    } else {
      widget.onScopeChanged(scope);
    }
  }

  void _open(AdminMapHit item) {
    if (widget.sidePanel) {
      setState(() => _selected = item);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: widget.details(
            context,
            item,
            () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );
  }

  void _onHit(AdminMapHit hit) {
    switch (hit) {
      case PlaceHit(:final place):
        _go(MapScope(placeId: place['id'] as String?));
        if (widget.sidePanel) setState(() => _selected = hit);
      case BuildingHit(:final building):
        _go(MapScope.building(building));
        if (widget.sidePanel) setState(() => _selected = hit);
      case PointHit():
        _open(hit);
    }
  }

  void _choose(MapSearchResult result) {
    _search.clear();
    _searchFocus.unfocus();
    switch (result.kind) {
      case MapSearchKind.place:
        _onHit(PlaceHit(result.item));
      case MapSearchKind.building:
        _onHit(BuildingHit(result.item));
      case MapSearchKind.point:
        final point = result.item;
        final building = _buildingsById[point['building_id']];
        setState(() {
          _focusFloor = pointFloor(point);
          _centerOn = anchorPosition(point);
        });
        _go(building != null ? MapScope.building(building) : widget.scope);
        _open(PointHit(point));
    }
  }

  String _hoverLabel(AdminMapHit hit) => switch (hit) {
    PlaceHit(:final place) => place['name'] as String? ?? '',
    BuildingHit(:final building) => building['name'] as String? ?? '',
    PointHit(:final point) => widget.pointName(point),
  };

  /// [item] as it is in the latest data, after a refresh; null once deleted.
  AdminMapHit? _fresh(AdminMapHit item) {
    Map<String, dynamic>? find(List<Map<String, dynamic>> rows, Map row) {
      for (final r in rows) {
        if (r['id'] == row['id']) return r;
      }
      return null;
    }

    return switch (item) {
      PlaceHit(:final place) => switch (find(widget.places, place)) {
        final p? => PlaceHit(p),
        null => null,
      },
      BuildingHit(:final building) => switch (find(
        widget.buildings,
        building,
      )) {
        final b? => BuildingHit(b),
        null => null,
      },
      PointHit(:final point) => switch (find(widget.points, point)) {
        final p? => PointHit(p),
        null => null,
      },
    };
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected == null ? null : _fresh(_selected!);
    final map = Stack(
      fit: StackFit.expand,
      children: [
        _map(),
        ValueListenableBuilder(
          valueListenable: _hover,
          builder: (context, hover, _) => hover == null
              ? const SizedBox.shrink()
              : Positioned(
                  left: hover.at.dx + 14,
                  top: hover.at.dy + 14,
                  child: IgnorePointer(
                    child: Material(
                      elevation: 2,
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Text(hover.label),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
    return Column(
      children: [
        _searchBar(),
        _breadcrumb(),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (widget.sidePanel && selected != null)
                Row(
                  children: [
                    Expanded(child: map),
                    const VerticalDivider(width: 1),
                    SizedBox(width: 340, child: _panel(selected)),
                  ],
                )
              else
                map,
              _results(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _map() {
    final frame = _frame();
    final points = _scopedPoints;
    final movingId = widget.movingPointId;
    int? movingFloor;
    for (final p in points) {
      if (movingId != null && p['id'] == movingId) movingFloor = pointFloor(p);
    }
    final buildingCounts = <String, int>{};
    for (final b in widget.buildings) {
      final placeId = b['place_id'] as String?;
      if (placeId != null) {
        buildingCounts[placeId] = (buildingCounts[placeId] ?? 0) + 1;
      }
    }
    final pointCounts = <String, int>{};
    for (final p in widget.points) {
      final buildingId = p['building_id'] as String?;
      if (buildingId != null) {
        pointCounts[buildingId] = (pointCounts[buildingId] ?? 0) + 1;
      }
    }
    final target = widget.moveTarget;
    return AdminMap(
      controller: _controller,
      onReady: () => _ready = true,
      showTiles: widget.showTiles,
      floors: floorsOf(points),
      fitTo: frame.coordinates,
      fitMinZoom: frame.minZoom,
      fitMaxZoom: frame.maxZoom,
      mode: movingId == null ? AdminMapMode.browse : AdminMapMode.move,
      focusFloor: movingFloor ?? _focusFloor,
      controlsTop: widget.controlsTop,
      layers: [
        PlacesLayer(places: widget.places, buildingCounts: buildingCounts),
        BuildingsLayer(buildings: widget.buildings, pointCounts: pointCounts),
        ConnectionsLayer(
          points: points,
          connections: widget.connections,
          minZoom: kMapPointsZoom,
        ),
        PointsLayer(
          points: points,
          movingId: movingId,
          minZoom: kMapPointsZoom,
        ),
        if (target != null) PinLayer(position: target),
      ],
      onHit: _onHit,
      onTapPosition: movingId == null ? null : widget.onMoveTargetTapped,
      onHover: (hit, at) =>
          _hover.value = hit == null ? null : (label: _hoverLabel(hit), at: at),
    );
  }

  Widget _searchBar() {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: TextField(
        controller: _search,
        focusNode: _searchFocus,
        decoration: InputDecoration(
          hintText: l10n.adminMapSearchHint,
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _search.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  tooltip: l10n.adminMapSearchClear,
                  onPressed: _search.clear,
                ),
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  Widget _results() {
    final query = _search.text.trim();
    if (query.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final results = searchMap(
      query,
      places: widget.places,
      buildings: widget.buildings,
      points: widget.points,
      pointName: widget.pointName,
    );
    IconData icon(MapSearchKind kind) => switch (kind) {
      MapSearchKind.place => Icons.flag,
      MapSearchKind.building => Icons.apartment,
      MapSearchKind.point => Icons.location_pin,
    };
    return Positioned(
      left: 12,
      right: 12,
      top: 0,
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: results.isEmpty
              ? ListTile(title: Text(l10n.adminMapSearchNoResults))
              : ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    for (final result in results)
                      ListTile(
                        leading: Icon(icon(result.kind)),
                        title: Text(result.title),
                        subtitle: result.subtitle.isEmpty
                            ? null
                            : Text(result.subtitle),
                        onTap: () => _choose(result),
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _breadcrumb() {
    final l10n = AppLocalizations.of(context)!;
    final scope = widget.scope;
    final place = scope.placeId == null ? null : _placesById[scope.placeId];
    final building = scope.buildingId == null
        ? null
        : _buildingsById[scope.buildingId];
    Widget crumb(String label, MapScope target, {IconData? icon}) => ActionChip(
      avatar: icon == null ? null : Icon(icon, size: 18),
      label: Text(label),
      onPressed: () => _go(target),
    );
    const separator = Icon(Icons.chevron_right, size: 18);
    final AdminMapHit? current = building != null
        ? BuildingHit(building)
        : place != null
        ? PlaceHit(place)
        : null;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: [
          crumb(l10n.adminMapAll, MapScope.all, icon: Icons.public),
          if (place != null) ...[
            separator,
            crumb(
              place['name'] as String? ?? '',
              MapScope(placeId: scope.placeId),
              icon: Icons.flag,
            ),
          ],
          if (building != null) ...[
            separator,
            crumb(
              building['name'] as String? ?? '',
              scope,
              icon: Icons.apartment,
            ),
          ],
          if (current != null)
            IconButton(
              icon: const Icon(Icons.info_outline),
              tooltip: l10n.adminMapDetailsTooltip,
              onPressed: () => _open(current),
            ),
        ],
      ),
    );
  }

  Widget _panel(AdminMapHit item) {
    final l10n = AppLocalizations.of(context)!;
    return Material(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 16),
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              icon: const Icon(Icons.close),
              tooltip: l10n.commonClose,
              onPressed: () => setState(() => _selected = null),
            ),
          ),
          widget.details(context, item, () => setState(() => _selected = null)),
        ],
      ),
    );
  }
}
