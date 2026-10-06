import 'package:flutter/material.dart';

import '../services/api_service.dart';

/// Place -> Building -> anchor-point drill-down list, for picking a
/// destination anchor point (see UserHomeScreen - the start point is
/// auto-selected as the nearest verified anchor to the user's current GPS
/// fix, not picked through here). Pops with the chosen anchor point's
/// full map on confirm, or null if the caller just backs all the way out.
///
/// Fetches all three lists up front (same "fetch all, filter client-side"
/// pattern AdminHomeScreen/LocationPickerScreen already use) rather than
/// re-fetching per drill-down step. Anchor points are filtered to
/// `status == 'verified'` - an unverified point has no indexed photos, so
/// it's not a trustworthy destination/start for the visual-correction
/// pipeline yet.
class AnchorPointPickerScreen extends StatefulWidget {
  final String title;

  const AnchorPointPickerScreen({super.key, required this.title});

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

  // 0 = picking a place, 1 = picking a building, 2 = picking an anchor point.
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
      setState(() {
        _places = (results[0] as List).cast<Map<String, dynamic>>();
        _buildings = (results[1] as List).cast<Map<String, dynamic>>();
        _anchorPoints = (results[2] as List)
            .cast<Map<String, dynamic>>()
            .where((a) => a['status'] == 'verified')
            .toList();
        _loading = false;
      });
    } on ApiException catch (e) {
      setState(() {
        _error = 'Failed to load locations: $e';
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
    final stepTitle = switch (_step) {
      0 => widget.title,
      1 => _selectedPlace?['name'] as String? ?? 'Select a building',
      _ => _selectedBuilding?['name'] as String? ?? 'Select an anchor point',
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
            onPressed: _goBack,
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(child: Text(_error!))
            : _buildStep(),
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case 0:
        return _list(
          items: _places,
          icon: Icons.flag,
          color: Colors.purple,
          emptyText: 'No places yet.',
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
          emptyText: 'No buildings in this place yet.',
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
          emptyText: 'No verified anchor points in this building yet.',
          subtitleKey: 'location_description',
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
    String? subtitleKey,
  }) {
    if (items.isEmpty) {
      return Center(child: Text(emptyText));
    }
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final subtitle = subtitleKey != null
            ? item[subtitleKey] as String?
            : null;
        return ListTile(
          leading: Icon(icon, color: color),
          title: Text(
            (item['name'] ?? item['location_description'] ?? item['id'])
                as String,
          ),
          subtitle: subtitle != null && subtitle != item['name']
              ? Text(subtitle)
              : null,
          onTap: () => onTap(item),
        );
      },
    );
  }
}
