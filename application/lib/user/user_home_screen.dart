import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:latlong2/latlong.dart';

import '../camera.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/geo_utils.dart';
import '../services/location_service.dart';
import 'anchor_point_picker_screen.dart';
import 'navigation_screen.dart';
import 'settings_screen.dart';

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
        builder: (_) => AnchorPointPickerScreen(
          title: AppLocalizations.of(context)!.homeWhereTo,
        ),
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
        _error = AppLocalizations.of(context)!.homeErrorLocationUnavailable;
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
          _error = AppLocalizations.of(context)!.homeErrorNoVerifiedAnchors;
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
      if (!mounted) return;
      setState(() {
        _error = e.statusCode == 404
            ? AppLocalizations.of(context)!.homeErrorNoPath
            : AppLocalizations.of(
                context,
              )!.homeErrorFailedToFindRoute(e.toString());
        _finding = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appTitle),
        backgroundColor: Colors.blue,
        actions: [
          IconButton(
            icon: const Icon(Icons.camera_alt_outlined),
            tooltip: l10n.homeCameraTooltip,
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: Text(l10n.homeDataCollectionTitle)),
                    body: const SimpleCameraWidget(),
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: l10n.homeSettingsTooltip,
            onPressed: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: l10n.commonLogOut,
            onPressed: () => Supabase.instance.client.auth.signOut(),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(
                Icons.radio_button_checked,
                color: Colors.blue,
              ),
              title: Text(l10n.homeStartLabel),
              subtitle: Text(l10n.homeStartSubtitle),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(
                _end == null ? Icons.radio_button_unchecked : Icons.location_on,
                color: _end == null ? Colors.grey : Colors.blue,
              ),
              title: Text(l10n.homeWhereTo),
              subtitle: Text(
                _end == null
                    ? l10n.homeTapToChooseDestination
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
                    : Text(l10n.homeFindRouteButton),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
