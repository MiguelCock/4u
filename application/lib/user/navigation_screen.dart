import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../location.dart';
import '../map.dart';
import '../services/api_service.dart';
import '../services/location_service.dart';

class NavigationScreen extends StatefulWidget {
  final Map<String, dynamic> route;

  const NavigationScreen({super.key, required this.route});

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  final _navigationApi = NavigationManagementApi();
  final _locationService = LocationService();
  String? _sessionId;
  Timer? _logTimer;
  bool _starting = true;
  bool _ending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startSession();
  }

  Future<void> _startSession() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      setState(() {
        _error = 'Not signed in.';
        _starting = false;
      });
      return;
    }
    try {
      final result = await _navigationApi.post('/sessions', {
        'user_id': userId,
        'building_id': widget.route['building_id'],
        'route_id': widget.route['id'],
      });
      // backend-navigation-management's POST /sessions returns Supabase's
      // insert result as-is, which is always a list (even for one row).
      final sessionData = (result as List).first as Map<String, dynamic>;
      setState(() {
        _sessionId = sessionData['id'] as String?;
        _starting = false;
      });
      // Raw-GPS logging tick - no visual correction pipeline exists yet
      // (see backend-navigation-management/CLAUDE.md), so corrected_* fields
      // are simply omitted from each POST /logs call below.
      _logTimer = Timer.periodic(const Duration(seconds: 5), (_) => _logTick());
    } on ApiException catch (e) {
      setState(() {
        _error = 'Failed to start navigation session: $e';
        _starting = false;
      });
    }
  }

  Future<void> _logTick() async {
    final sessionId = _sessionId;
    final position = _locationService.lastPosition;
    if (sessionId == null || position == null) return;
    try {
      await _navigationApi.post('/logs', {
        'session_id': sessionId,
        'gps_lat': position.latitude,
        'gps_long': position.longitude,
        'gps_accuracy': position.accuracy,
        'heading': position.heading,
      });
    } on ApiException catch (_) {
      // Best-effort logging - a dropped tick shouldn't interrupt navigation.
    }
  }

  Future<void> _endSession() async {
    final sessionId = _sessionId;
    if (sessionId == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() => _ending = true);
    _logTimer?.cancel();
    final position = _locationService.lastPosition;
    try {
      await _navigationApi.patch('/sessions/$sessionId', {
        'status': 'completed',
        'end_time': DateTime.now().toUtc().toIso8601String(),
        if (position != null)
          'end_position': {'latitude': position.latitude, 'longitude': position.longitude},
      });
    } on ApiException catch (_) {
      // Session end best-effort too - still let the user leave the screen.
    }
    if (mounted) await _showFeedbackDialog(sessionId);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _showFeedbackDialog(String sessionId) async {
    final controller = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('How did it go?'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Optional feedback'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Skip'),
          ),
          TextButton(
            onPressed: () async {
              final comment = controller.text.trim();
              final userId = Supabase.instance.client.auth.currentUser?.id;
              if (comment.isNotEmpty && userId != null) {
                try {
                  await _navigationApi.post('/feedback', {
                    'user_id': userId,
                    'session_id': sessionId,
                    'comment': comment,
                  });
                } on ApiException catch (_) {
                  // Feedback is best-effort - don't block leaving the screen.
                }
              }
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('Submit'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _logTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.route['name'] as String? ?? 'Navigating'),
      ),
      body: _starting
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text(_error!, style: const TextStyle(color: Colors.red)),
                  ),
                const LocationInfo(),
                const Expanded(child: SimpleMapWidget()),
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: ElevatedButton(
                    onPressed: _ending ? null : _endSession,
                    child: _ending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('End navigation'),
                  ),
                ),
              ],
            ),
    );
  }
}
