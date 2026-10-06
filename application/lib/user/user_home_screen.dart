import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:latlong2/latlong.dart';

import '../camera.dart';
import '../services/api_service.dart';
import '../services/geo_utils.dart';
import '../services/location_service.dart';
import 'anchor_point_picker_screen.dart';
import 'navigation_screen.dart';

/// The `user`-role home screen IS the trip-planning flow now (not a map,
/// not a separate screen reached via a FAB): the user only picks a
/// destination - the start point is auto-selected as the verified anchor
/// point nearest their current GPS fix, Uber-pickup-pin style, rather than
/// making them pick both ends.
class UserHomeScreen extends StatefulWidget {
  const UserHomeScreen({super.key});

  @override
  State<UserHomeScreen> createState() => _UserHomeScreenState();
}

class _UserHomeScreenState extends State<UserHomeScreen> {
  final _mapApi = MapManagementApi();
  final _routeApi = RouteManagementApi();
  final _locationService = LocationService();

  Map<String, dynamic>? _end;
  bool _finding = false;
  String? _error;

  Future<void> _pickEnd() async {
    final picked = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) =>
            const AnchorPointPickerScreen(title: 'Where do you want to go?'),
      ),
    );
    if (picked != null) setState(() => _end = picked);
  }

  Map<String, dynamic>? _nearestAnchor(
    List<Map<String, dynamic>> anchors,
    LatLng from,
  ) {
    Map<String, dynamic>? nearest;
    double? nearestDistance;
    for (final anchor in anchors) {
      final lat = (anchor['latitude'] as num?)?.toDouble();
      final lng = (anchor['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      final distance = haversineMeters(from, LatLng(lat, lng));
      if (nearestDistance == null || distance < nearestDistance) {
        nearestDistance = distance;
        nearest = anchor;
      }
    }
    return nearest;
  }

  Future<void> _findRoute() async {
    final end = _end;
    if (end == null) return;
    setState(() {
      _finding = true;
      _error = null;
    });

    final position = _locationService.lastPosition;
    if (position == null) {
      setState(() {
        _error = 'Current location not available yet - try again shortly.';
        _finding = false;
      });
      return;
    }

    try {
      final anchors = await _mapApi.get('/anchor-points');
      final verified = (anchors as List)
          .cast<Map<String, dynamic>>()
          .where((a) => a['status'] == 'verified')
          .toList();
      final start = _nearestAnchor(
        verified,
        LatLng(position.latitude, position.longitude),
      );
      if (start == null) {
        setState(() {
          _error = 'No verified anchor points exist yet.';
          _finding = false;
        });
        return;
      }

      final route = await _routeApi.post('/routes/find_or_create', {
        'start_anchor_id': start['id'],
        'end_anchor_id': end['id'],
      });
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              NavigationScreen(route: route as Map<String, dynamic>),
        ),
      );
      setState(() => _finding = false);
    } on ApiException catch (e) {
      setState(() {
        _error = e.statusCode == 404
            ? "No walkable path found to that destination yet - an admin needs to add connections first."
            : 'Failed to find a route: $e';
        _finding = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('4u'),
        backgroundColor: Colors.blue,
        actions: [
          IconButton(
            icon: const Icon(Icons.camera_alt_outlined),
            tooltip: 'Data collection camera',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: const Text('Data collection')),
                    body: const SimpleCameraWidget(),
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => Supabase.instance.client.auth.signOut(),
          ),
        ],
      ),
      body: Column(
        children: [
          const ListTile(
            leading: Icon(Icons.radio_button_checked, color: Colors.blue),
            title: Text('Start'),
            subtitle: Text('Your current location'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(
              _end == null ? Icons.radio_button_unchecked : Icons.location_on,
              color: _end == null ? Colors.grey : Colors.blue,
            ),
            title: const Text('Where to?'),
            subtitle: Text(
              _end == null
                  ? 'Tap to choose a destination'
                  : (_end!['location_description'] as String? ??
                        _end!['id'] as String),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickEnd,
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: ElevatedButton(
              onPressed: (_end != null && !_finding) ? _findRoute : null,
              child: _finding
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Find route'),
            ),
          ),
        ],
      ),
    );
  }
}
