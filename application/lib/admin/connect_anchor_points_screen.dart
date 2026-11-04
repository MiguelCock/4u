import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/map_tile_config.dart';
import '../services/api_error_messages.dart';
import '../services/capture_checks.dart';
import '../services/floor_view.dart';
import '../services/location_types.dart' show anchorLabel;
import '../services/map_tap.dart';
import '../widgets/floor_selector.dart';

/// Map-tap flow for building the anchor-point walkability graph: tap one
/// anchor point, then another, to create a connection between them. The
/// second point stays selected after each connection so an admin can keep
/// tapping a third, fourth, etc. point to chain-connect along a corridor
/// without re-entering the flow. Tapping a connection line (away from any
/// point) offers to delete that connection.
///
/// One floor shows at a time (FloorSelector). The floors directly above and
/// below show as small triangles that can be tapped, which is how stairs get
/// connected across floors; connecting to one moves the view to its floor, so
/// a chain carries on. The selected point always shows.
///
/// The `initial*` params let a caller jump straight in from a specific
/// anchor point (admin_home_screen.dart's anchor-point row tap): its
/// university/building are pre-selected, the map opens zoomed in on it, and
/// it's already the first point of the pair - the next marker tapped
/// connects to it.
class ConnectAnchorPointsScreen extends StatefulWidget {
  final String? initialPlaceId;
  final String? initialBuildingId;
  final String? initialAnchorPointId;

  const ConnectAnchorPointsScreen({
    super.key,
    this.initialPlaceId,
    this.initialBuildingId,
    this.initialAnchorPointId,
  });

  @override
  State<ConnectAnchorPointsScreen> createState() =>
      _ConnectAnchorPointsScreenState();
}

class _ConnectAnchorPointsScreenState extends State<ConnectAnchorPointsScreen> {
  final _mapApi = MapManagementApi();

  List<Map<String, dynamic>> _places = [];
  List<Map<String, dynamic>> _buildings = [];
  List<Map<String, dynamic>> _anchorPoints = [];
  List<Map<String, dynamic>> _connections = [];
  String? _selectedPlaceId;
  String? _selectedBuildingId;
  String? _selectedAnchorPointId;
  bool _loading = true;
  String? _error;
  final _mapController = MapController();
  int? _floor;
  bool _onlySelectedFloor = false;

  /// Pairs (see [_pairKey]) whose connection is still being saved.
  final Set<String> _pendingPairs = {};

  @override
  void initState() {
    super.initState();
    _selectedPlaceId = widget.initialPlaceId;
    _selectedBuildingId = widget.initialBuildingId;
    _selectedAnchorPointId = widget.initialAnchorPointId;
    _loadData();
    loadOnlySelectedFloor().then((value) {
      if (mounted) setState(() => _onlySelectedFloor = value);
    });
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    try {
      final results = await Future.wait([
        _mapApi.get('/places'),
        _mapApi.get('/buildings'),
        _mapApi.get('/anchor-points'),
        _mapApi.get('/anchor-point-connections'),
      ]);
      if (!mounted) return;
      setState(() {
        _places = (results[0] as List).cast<Map<String, dynamic>>();
        _buildings = (results[1] as List).cast<Map<String, dynamic>>();
        _anchorPoints = (results[2] as List).cast<Map<String, dynamic>>();
        _connections = (results[3] as List).cast<Map<String, dynamic>>();
        // Drop any seeded selection that no longer exists (e.g. deleted
        // since the caller's list was loaded) before defaulting.
        if (!_places.any((p) => p['id'] == _selectedPlaceId)) {
          _selectedPlaceId = null;
        }
        if (!_buildings.any(
          (b) =>
              b['id'] == _selectedBuildingId &&
              b['place_id'] == _selectedPlaceId,
        )) {
          _selectedBuildingId = null;
        }
        if (!_anchorPoints.any((p) => p['id'] == _selectedAnchorPointId)) {
          _selectedAnchorPointId = null;
        }
        if (_selectedPlaceId == null && _places.isNotEmpty) {
          _selectedPlaceId = _places.first['id'] as String?;
        }
        final selected = _selectedAnchorPointId;
        if (selected != null) _floor = pointFloor(_pointById(selected));
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(
        () => _error = AppLocalizations.of(
          context,
        )!.commonErrorLoadDataFailed(friendlyApiErrorMessage(context, e)),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _buildingsInPlace =>
      _buildings.where((b) => b['place_id'] == _selectedPlaceId).toList();

  List<Map<String, dynamic>> get _visibleAnchorPoints {
    final buildingIds = _selectedBuildingId != null
        ? {_selectedBuildingId!}
        : _buildingsInPlace.map((b) => b['id'] as String).toSet();
    return _anchorPoints
        .where((p) => buildingIds.contains(p['building_id']))
        .toList();
  }

  int get _selectedFloor {
    final floors = floorsOf(_visibleAnchorPoints);
    return floorInRange(_floor ?? openingFloor(floors) ?? 0, floors) ?? 0;
  }

  FloorRelation _relation(Map<String, dynamic> point) =>
      floorRelation(point, _selectedFloor, onlySelected: _onlySelectedFloor);

  /// Drawn, tappable and joined by lines: the selected floor, those directly
  /// next to it, and the selected point wherever it is.
  bool _isShown(Map<String, dynamic> point) =>
      point['id'] == _selectedAnchorPointId ||
      _relation(point) != FloorRelation.hidden;

  /// Whether the line between [a] and [b] is drawn (and can be tapped).
  bool _showsLine(Map<String, dynamic> a, Map<String, dynamic> b) =>
      floorShowsConnection(
        a,
        b,
        _selectedFloor,
        onlySelected: _onlySelectedFloor,
      );

  /// A tap within this many logical pixels of a point's dot selects it -
  /// far more forgiving than the dot itself, which is what made taps feel
  /// missed.
  static const double _kTapRadiusPx = 32;

  /// Taps come from `MapOptions.onTap` instead of a GestureDetector per
  /// marker: with double-tap zoom off, flutter_map fires it immediately,
  /// where a marker's own detector waited out the double-tap timeout
  /// (~300ms) first.
  void _onMapTap(LatLng tapped) {
    final point = _pointNear(tapped);
    if (point != null) {
      _onPointTap(point);
      return;
    }
    final connection = _connectionNear(tapped);
    if (connection != null) _confirmDeleteConnection(connection);
  }

  /// A tap within this many logical pixels of a connection line (and not
  /// near a point, which wins) offers to delete that connection.
  static const double _kLineTapRadiusPx = 16;

  Map<String, dynamic>? _connectionNear(LatLng tapped) {
    final camera = _mapController.camera;
    final tap = camera.latLngToScreenOffset(tapped);
    final byId = {for (final p in _visibleAnchorPoints) p['id'] as String: p};
    Offset? screen(Map<String, dynamic>? point) {
      final lat = (point?['latitude'] as num?)?.toDouble();
      final lng = (point?['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) return null;
      return camera.latLngToScreenOffset(LatLng(lat, lng));
    }

    Map<String, dynamic>? nearest;
    var nearestDistance = _kLineTapRadiusPx;
    for (final c in _connections) {
      if (c['pending'] == true) continue;
      final pointA = byId[c['anchor_point_a_id']];
      final pointB = byId[c['anchor_point_b_id']];
      if (pointA == null || pointB == null || !_showsLine(pointA, pointB)) {
        continue;
      }
      final a = screen(pointA);
      final b = screen(pointB);
      if (a == null || b == null) continue;
      final distance = _distanceToSegment(tap, a, b);
      if (distance <= nearestDistance) {
        nearestDistance = distance;
        nearest = c;
      }
    }
    return nearest;
  }

  static double _distanceToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
    if (lengthSquared == 0) return (p - a).distance;
    final ap = p - a;
    final t = ((ap.dx * ab.dx + ap.dy * ab.dy) / lengthSquared).clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }

  Future<void> _confirmDeleteConnection(Map<String, dynamic> connection) async {
    final l10n = AppLocalizations.of(context)!;
    final fromDesc = _describePoint(connection['anchor_point_a_id'] as String);
    final toDesc = _describePoint(connection['anchor_point_b_id'] as String);
    HapticFeedback.selectionClick();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.adminDeleteConnectionTitle),
        content: Text(l10n.connectDeleteContent(fromDesc, toDesc)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _mapApi.delete('/anchor-point-connections/${connection['id']}');
      if (!mounted) return;
      setState(() {
        _connections = [
          for (final c in _connections)
            if (c['id'] != connection['id']) c,
        ];
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(l10n.connectSnackbarDeleted(fromDesc, toDesc)),
          ),
        );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.commonErrorDeleteFailed(friendlyApiErrorMessage(context, e)),
          ),
        ),
      );
    }
  }

  /// The selected floor first: stairs on two floors are on top of each other.
  Map<String, dynamic>? _pointNear(LatLng tapped) {
    Map<String, dynamic>? nearest(
      bool Function(Map<String, dynamic>) showing,
    ) => nearestOnScreen(
      camera: _mapController.camera,
      tapped: tapped,
      items: _visibleAnchorPoints.where(showing),
      positionOf: anchorPosition,
      radiusPx: _kTapRadiusPx,
    );
    return nearest((p) => _relation(p) == FloorRelation.current) ??
        nearest(_isShown);
  }

  static String _pairKey(String a, String b) =>
      a.compareTo(b) < 0 ? '$a|$b' : '$b|$a';

  bool _alreadyConnected(String a, String b) => _connections.any(
    (c) =>
        _pairKey(
          c['anchor_point_a_id'] as String? ?? '',
          c['anchor_point_b_id'] as String? ?? '',
        ) ==
        _pairKey(a, b),
  );

  Future<void> _onPointTap(Map<String, dynamic> point) async {
    final id = point['id'] as String;
    HapticFeedback.selectionClick();
    if (_selectedAnchorPointId == null) {
      setState(() => _selectedAnchorPointId = id);
      return;
    }
    if (_selectedAnchorPointId == id) {
      setState(() => _selectedAnchorPointId = null);
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      setState(() => _error = l10n.commonNotSignedIn);
      return;
    }

    final fromId = _selectedAnchorPointId!;
    final key = _pairKey(fromId, id);
    if (_alreadyConnected(fromId, id)) {
      // Nothing to send - just move on, so chaining along a corridor keeps
      // working when it crosses an existing line.
      setState(() {
        _selectedAnchorPointId = id;
        _floor = pointFloor(point);
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(l10n.connectErrorAlreadyConnected)),
        );
      return;
    }

    // Refused before sending (the backend refuses it too): keep the
    // selection, so a mistaken far tap doesn't lose the place in the chain.
    final from = _pointById(fromId);
    final to = _pointById(id);
    final problem = connectionProblem(from, to);
    final distance = anchorDistance(from, to);
    if (problem != null) {
      HapticFeedback.heavyImpact();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 6),
            content: Text(
              problem == ConnectionProblem.tooLong
                  ? l10n.connectErrorTooFar(
                      _describePoint(fromId),
                      _describePoint(id),
                      distance!.toStringAsFixed(0),
                    )
                  : l10n.connectErrorFloorChange(
                      _describePoint(fromId),
                      _describePoint(id),
                    ),
            ),
          ),
        );
      return;
    }

    // Optimistic: draw the line and move the selection right away, so the
    // next tap works while this one is still being saved. Only a repeat of
    // this same pair is ignored until it's done.
    final pending = <String, dynamic>{
      'id': 'pending-$key',
      'anchor_point_a_id': fromId,
      'anchor_point_b_id': id,
      'pending': true,
    };
    setState(() {
      _error = null;
      _pendingPairs.add(key);
      _connections = [..._connections, pending];
      _selectedAnchorPointId = id;
      _floor = pointFloor(to);
    });

    try {
      final result = await _mapApi.post('/anchor-point-connections', {
        'anchor_point_a_id': fromId,
        'anchor_point_b_id': id,
        'created_by': userId,
      });
      if (!mounted) return;
      final created = result is List && result.isNotEmpty
          ? (result.first as Map).cast<String, dynamic>()
          : null;
      setState(() {
        _connections = [
          for (final c in _connections)
            if (!identical(c, pending)) c,
          created ?? {...pending, 'pending': false},
        ];
      });
      final long = distance != null && distance > kConnectionWarnMeters;
      long ? HapticFeedback.mediumImpact() : HapticFeedback.lightImpact();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            duration: Duration(seconds: long ? 4 : 2),
            content: Text(
              long
                  ? l10n.connectSnackbarConnectedLong(
                      distance.toStringAsFixed(0),
                    )
                  : l10n.connectSnackbarConnected(
                      _describePoint(fromId),
                      _describePoint(id),
                    ),
            ),
          ),
        );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _connections = [
          for (final c in _connections)
            if (!identical(c, pending)) c,
        ];
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              // Only a real duplicate; a 500 used to read as "already
              // connected" too, hiding outages.
              e.statusCode == 409
                  ? l10n.connectErrorAlreadyConnected
                  : l10n.connectErrorConnectFailed(
                      friendlyApiErrorMessage(context, e),
                    ),
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => _pendingPairs.remove(key));
    }
  }

  Map<String, dynamic> _pointById(String id) =>
      _anchorPoints.firstWhere((p) => p['id'] == id, orElse: () => {'id': id});

  String? _buildingNameOf(Map<String, dynamic> point) {
    for (final building in _buildings) {
      if (building['id'] == point['building_id']) {
        return building['name'] as String?;
      }
    }
    return null;
  }

  String _describePoint(String id) {
    final point = _pointById(id);
    return anchorLabel(
      AppLocalizations.of(context)!,
      point,
      _buildingNameOf(point),
    );
  }

  List<Polyline> _connectionLines() {
    final byId = {for (final p in _anchorPoints) p['id'] as String: p};
    final visibleIds = _visibleAnchorPoints
        .map((p) => p['id'] as String)
        .toSet();
    final lines = <Polyline>[];
    for (final c in _connections) {
      final aId = c['anchor_point_a_id'] as String?;
      final bId = c['anchor_point_b_id'] as String?;
      if (aId == null || bId == null) continue;
      if (!visibleIds.contains(aId) || !visibleIds.contains(bId)) continue;
      final a = byId[aId];
      final b = byId[bId];
      final aLat = (a?['latitude'] as num?)?.toDouble();
      final aLng = (a?['longitude'] as num?)?.toDouble();
      final bLat = (b?['latitude'] as num?)?.toDouble();
      final bLng = (b?['longitude'] as num?)?.toDouble();
      if (aLat == null || aLng == null || bLat == null || bLng == null) {
        continue;
      }
      if (!_showsLine(a!, b!)) continue;
      final pending = c['pending'] == true;
      lines.add(
        Polyline(
          points: [LatLng(aLat, aLng), LatLng(bLat, bLng)],
          color: pending ? Colors.grey : Colors.green,
          strokeWidth: pending ? 2 : 3,
          pattern: pending
              ? const StrokePattern.dotted()
              : pointFloor(a) == pointFloor(b)
              ? const StrokePattern.solid()
              : StrokePattern.dashed(segments: const [8, 6]),
        ),
      );
    }
    return lines;
  }

  List<Marker> _anchorMarkers() {
    final shown = _visibleAnchorPoints.where(_isShown).toList();
    bool onTop(Map<String, dynamic> p) =>
        p['id'] == _selectedAnchorPointId ||
        _relation(p) == FloorRelation.current;
    // The other floors first, so the selected one is drawn on top.
    return [...shown.where((p) => !onTop(p)), ...shown.where(onTop)]
        .map((point) {
          final lat = (point['latitude'] as num?)?.toDouble();
          final lng = (point['longitude'] as num?)?.toDouble();
          if (lat == null || lng == null) {
            return null;
          }
          final selected = point['id'] == _selectedAnchorPointId;
          if (!onTop(point)) {
            return floorPointMarker(LatLng(lat, lng), _relation(point));
          }
          // Taps are handled by _onMapTap, not here - see its comment.
          return Marker(
            point: LatLng(lat, lng),
            width: 48,
            height: 48,
            child: Icon(
              selected ? Icons.radio_button_checked : Icons.circle,
              color: selected ? Colors.blue : Colors.green,
              size: selected ? 36 : 22,
            ),
          );
        })
        .whereType<Marker>()
        .toList();
  }

  /// The map's initialCenter only applies once, so switching university or
  /// building used to leave the map showing the previous one.
  void _recentre() {
    try {
      _mapController.move(_initialCenter(), _mapController.camera.zoom);
    } catch (_) {
      // Map not built yet; it starts at _initialCenter() anyway.
    }
  }

  LatLng _initialCenter() {
    final focused = _anchorPoints.where(
      (p) => p['id'] == widget.initialAnchorPointId,
    );
    if (focused.isNotEmpty) {
      return LatLng(
        (focused.first['latitude'] as num).toDouble(),
        (focused.first['longitude'] as num).toDouble(),
      );
    }
    final points = _visibleAnchorPoints;
    if (points.isEmpty) return const LatLng(0, 0);
    final lat = (points.first['latitude'] as num).toDouble();
    final lng = (points.first['longitude'] as num).toDouble();
    return LatLng(lat, lng);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.adminFabConnectOnMap)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _selectedPlaceId,
                          decoration: InputDecoration(
                            labelText: l10n.commonUniversityLabel,
                            isDense: true,
                          ),
                          items: _places
                              .map(
                                (p) => DropdownMenuItem(
                                  value: p['id'] as String,
                                  child: Text(
                                    p['name'] as String? ?? p['id'] as String,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            setState(() {
                              _selectedPlaceId = value;
                              _selectedBuildingId = null;
                              _selectedAnchorPointId = null;
                            });
                            _recentre();
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<String?>(
                          initialValue: _selectedBuildingId,
                          decoration: InputDecoration(
                            labelText: l10n.commonBuildingLabel,
                            isDense: true,
                          ),
                          items: [
                            DropdownMenuItem<String?>(
                              value: null,
                              child: Text(l10n.commonAllBuildings),
                            ),
                            ..._buildingsInPlace.map(
                              (b) => DropdownMenuItem<String?>(
                                value: b['id'] as String,
                                child: Text(
                                  b['name'] as String? ?? b['id'] as String,
                                ),
                              ),
                            ),
                          ],
                          onChanged: (value) {
                            setState(() {
                              _selectedBuildingId = value;
                              _selectedAnchorPointId = null;
                            });
                            _recentre();
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12.0),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12.0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _selectedAnchorPointId == null
                          ? l10n.connectTapToStart
                          : l10n.connectTapToFinish(
                              _describePoint(_selectedAnchorPointId!),
                            ),
                    ),
                  ),
                ),
                if (_pendingPairs.isNotEmpty)
                  const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: Stack(
                    children: [
                      _map(),
                      Positioned(
                        right: 8,
                        top: 8,
                        child: FloorSelector(
                          floors: floorsOf(_visibleAnchorPoints),
                          selected: _selectedFloor,
                          onlySelected: _onlySelectedFloor,
                          onFloorChanged: (floor) =>
                              setState(() => _floor = floor),
                          onOnlySelectedChanged: (value) {
                            setState(() => _onlySelectedFloor = value);
                            saveOnlySelectedFloor(value);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _map() {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        // Double-tap zoom off: it made every single tap wait
        // for a possible second one. Pinch still zooms.
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.doubleTapZoom,
        ),
        onTap: (_, latLng) => _onMapTap(latLng),
        initialCenter: _initialCenter(),
        initialZoom: widget.initialAnchorPointId != null ? 19.5 : 18,
      ),
      children: [
        TileLayer(
          urlTemplate: kMapTileUrlTemplate,
          userAgentPackageName: kMapUserAgentPackageName,
        ),
        PolylineLayer(polylines: _connectionLines()),
        MarkerLayer(markers: _anchorMarkers()),
      ],
    );
  }
}
