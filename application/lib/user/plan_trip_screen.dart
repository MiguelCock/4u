import 'package:flutter/material.dart';

import '../services/api_service.dart';
import 'anchor_point_picker_screen.dart';
import 'navigation_screen.dart';

/// "Where to?" - the Uber-style entry point into navigation: pick a start
/// and an end anchor point (not a flat pre-made list of routes), then ask
/// the backend for an existing route between them or a freshly computed
/// one (POST /routes/find_or_create).
class PlanTripScreen extends StatefulWidget {
  const PlanTripScreen({super.key});

  @override
  State<PlanTripScreen> createState() => _PlanTripScreenState();
}

class _PlanTripScreenState extends State<PlanTripScreen> {
  final _routeApi = RouteManagementApi();

  Map<String, dynamic>? _start;
  Map<String, dynamic>? _end;
  bool _finding = false;
  String? _error;

  Future<void> _pickStart() async {
    final picked = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) =>
            const AnchorPointPickerScreen(title: 'Where are you starting?'),
      ),
    );
    if (picked != null) setState(() => _start = picked);
  }

  Future<void> _pickEnd() async {
    final picked = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) =>
            const AnchorPointPickerScreen(title: 'Where do you want to go?'),
      ),
    );
    if (picked != null) setState(() => _end = picked);
  }

  Future<void> _findRoute() async {
    final start = _start;
    final end = _end;
    if (start == null || end == null) return;
    setState(() {
      _finding = true;
      _error = null;
    });
    try {
      final route = await _routeApi.post('/routes/find_or_create', {
        'start_anchor_id': start['id'],
        'end_anchor_id': end['id'],
      });
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) =>
              NavigationScreen(route: route as Map<String, dynamic>),
        ),
      );
    } on ApiException catch (e) {
      setState(() {
        _error = e.statusCode == 404
            ? "No walkable path found between these two points yet - an admin needs to add connections between them first."
            : 'Failed to find a route: $e';
        _finding = false;
      });
    }
  }

  Widget _pointTile({
    required String label,
    required Map<String, dynamic>? point,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(
        point == null ? Icons.radio_button_unchecked : Icons.location_on,
        color: point == null ? Colors.grey : Colors.blue,
      ),
      title: Text(label),
      subtitle: Text(
        point == null
            ? 'Tap to choose'
            : (point['location_description'] as String? ?? point['id']),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Where to?')),
      body: Column(
        children: [
          _pointTile(label: 'Start', point: _start, onTap: _pickStart),
          const Divider(height: 1),
          _pointTile(label: 'Destination', point: _end, onTap: _pickEnd),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: ElevatedButton(
              onPressed: (_start != null && _end != null && !_finding)
                  ? _findRoute
                  : null,
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
