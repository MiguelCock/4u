import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/api_error_messages.dart';
import '../services/destinations.dart';
import '../widgets/scrollable_message.dart';

/// University -> Building -> anchor-point drill-down list, for picking a
/// destination anchor point (see UserHomeScreen - the start point is
/// auto-selected as the nearest verified anchor to the user's current GPS
/// fix, not picked through here). Pops with the chosen anchor point's
/// full map on confirm, or null if the caller just backs all the way out.
/// "University" here is the display rename of the backend's generic
/// `places` concept - see #106.
class AnchorPointPickerScreen extends StatefulWidget {
  final String title;

  /// Left out of the list entirely - UserHomeScreen passes the auto-picked
  /// start point here, so a user can't choose it as the destination too.
  final String? excludeAnchorId;

  const AnchorPointPickerScreen({
    super.key,
    required this.title,
    this.excludeAnchorId,
  });

  @override
  State<AnchorPointPickerScreen> createState() =>
      _AnchorPointPickerScreenState();
}

class _AnchorPointPickerScreenState extends State<AnchorPointPickerScreen> {
  final _mapApi = MapManagementApi();

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _places = [];
  List<Map<String, dynamic>> _buildings = [];
  List<Map<String, dynamic>> _anchorPoints = [];

  // 0 = picking a university, 1 = picking a building, 2 = picking an
  // anchor point.
  int _step = 0;
  Map<String, dynamic>? _selectedPlace;
  Map<String, dynamic>? _selectedBuilding;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _mapApi.get('/places'),
        _mapApi.get('/buildings'),
        _mapApi.get('/anchor-points'),
      ]);
      if (!mounted) return;
      // Only real destinations (an important type with a name) are offered;
      // unnamed hallway/intersection points exist just to connect routes.
      // Universities and buildings with no destinations are hidden too, so
      // the drill-down never leads to an empty list.
      final anchors = (results[2] as List)
          .cast<Map<String, dynamic>>()
          .where(
            (a) =>
                a['status'] == 'verified' &&
                isDestinationAnchor(a) &&
                a['id'] != widget.excludeAnchorId,
          )
          .toList();
      final buildingIds = anchors.map((a) => a['building_id']).toSet();
      final buildings = (results[1] as List)
          .cast<Map<String, dynamic>>()
          .where((b) => buildingIds.contains(b['id']))
          .toList();
      final placeIds = buildings.map((b) => b['place_id']).toSet();
      setState(() {
        _places = (results[0] as List)
            .cast<Map<String, dynamic>>()
            .where((p) => placeIds.contains(p['id']))
            .toList();
        _buildings = buildings;
        _anchorPoints = anchors;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = AppLocalizations.of(
          context,
        )!.pickerErrorLoadFailed(friendlyApiErrorMessage(context, e));
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _buildingsInSelectedPlace {
    final placeId = _selectedPlace?['id'];
    return _buildings.where((b) => b['place_id'] == placeId).toList();
  }

  List<Map<String, dynamic>> get _anchorsInSelectedBuilding {
    final buildingId = _selectedBuilding?['id'];
    return _anchorPoints.where((a) => a['building_id'] == buildingId).toList();
  }

  void _goBack() {
    if (_step == 0) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _step -= 1;
      if (_step == 0) _selectedPlace = null;
      if (_step <= 1) _selectedBuilding = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final stepTitle = switch (_step) {
      0 => widget.title,
      1 => _selectedPlace?['name'] as String? ?? l10n.pickerSelectBuilding,
      _ =>
        _selectedBuilding?['name'] as String? ?? l10n.pickerSelectAnchorPoint,
    };

    return PopScope(
      canPop: _step == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _goBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(stepTitle),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: _goBack,
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: _error != null
                    ? ScrollableMessage(_error!, liveRegion: true)
                    : _buildStep(),
              ),
      ),
    );
  }

  Widget _buildStep() {
    final l10n = AppLocalizations.of(context)!;
    switch (_step) {
      case 0:
        return _list(
          items: _places,
          icon: Icons.flag,
          color: Colors.purple,
          emptyText: l10n.pickerNoUniversitiesYet,
          onTap: (place) => setState(() {
            _selectedPlace = place;
            _step = 1;
          }),
        );
      case 1:
        return _list(
          items: _buildingsInSelectedPlace,
          icon: Icons.apartment,
          color: Colors.orange,
          emptyText: l10n.pickerNoBuildingsInUniversity,
          onTap: (building) => setState(() {
            _selectedBuilding = building;
            _step = 2;
          }),
        );
      default:
        return _list(
          items: _anchorsInSelectedBuilding,
          icon: Icons.location_pin,
          color: Colors.green,
          emptyText: l10n.pickerNoVerifiedAnchorsInBuilding,
          onTap: (anchor) => Navigator.of(context).pop(anchor),
        );
    }
  }

  Widget _list({
    required List<Map<String, dynamic>> items,
    required IconData icon,
    required Color color,
    required String emptyText,
    required void Function(Map<String, dynamic>) onTap,
  }) {
    if (items.isEmpty) {
      return ScrollableMessage(emptyText);
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return ListTile(
          leading: Icon(icon, color: color),
          title: Text(
            (item['name'] ?? item['location_description'] ?? item['id'])
                as String,
          ),
          onTap: () => onTap(item),
        );
      },
    );
  }
}
