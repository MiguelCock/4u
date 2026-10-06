import 'package:flutter/material.dart';

import '../services/api_service.dart';
import 'session_tracking_screen.dart';

/// Admin-only: one user's full session history (every status - active,
/// completed, abandoned, failed), with a Watch action into
/// SessionTrackingScreen (works for any status - a non-active session just
/// shows its final static trail, since nothing is still being logged) and
/// a Delete action per session (DELETE /navigation/sessions/{id}, newly
/// added alongside this screen - admin-only server-side too).
class UserSessionsScreen extends StatefulWidget {
  final String userId;
  final String userName;
  final List<Map<String, dynamic>> sessions;

  const UserSessionsScreen({
    super.key,
    required this.userId,
    required this.userName,
    required this.sessions,
  });

  @override
  State<UserSessionsScreen> createState() => _UserSessionsScreenState();
}

class _UserSessionsScreenState extends State<UserSessionsScreen> {
  final _navigationApi = NavigationManagementApi();
  final _routeApi = RouteManagementApi();
  late List<Map<String, dynamic>> _sessions;
  Map<String, Map<String, dynamic>> _routesById = {};
  bool _loadingRoutes = true;

  @override
  void initState() {
    super.initState();
    _sessions = List.of(widget.sessions)
      ..sort(
        (a, b) => (b['start_time'] as String? ?? '').compareTo(
          a['start_time'] as String? ?? '',
        ),
      );
    _loadRoutes();
  }

  Future<void> _loadRoutes() async {
    try {
      final result = await _routeApi.get('/routes');
      final routes = (result as List? ?? []).cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _routesById = {for (final r in routes) r['id'] as String: r};
        _loadingRoutes = false;
      });
    } on ApiException {
      // The route name is a nice-to-have label - a failed fetch shouldn't
      // block showing the sessions themselves.
      if (mounted) setState(() => _loadingRoutes = false);
    }
  }

  Future<bool> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this session?'),
        content: const Text(
          'This also deletes its logged GPS history. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _deleteSession(Map<String, dynamic> session) async {
    final confirmed = await _confirmDelete();
    if (!confirmed) return;
    try {
      await _navigationApi.delete('/sessions/${session['id']}');
      if (!mounted) return;
      setState(() => _sessions.removeWhere((s) => s['id'] == session['id']));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to delete: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.userName)),
      body: _sessions.isEmpty
          ? const Center(child: Text('No sessions for this user.'))
          : ListView.builder(
              itemCount: _sessions.length,
              itemBuilder: (context, index) {
                final session = _sessions[index];
                final routeId = session['route_id'] as String?;
                final routeName = _loadingRoutes || routeId == null
                    ? null
                    : _routesById[routeId]?['name'] as String?;
                return ListTile(
                  leading: Icon(
                    Icons.my_location,
                    color: session['status'] == 'active'
                        ? Colors.teal
                        : Colors.grey,
                  ),
                  title: Text('Session ${session['id']}'),
                  subtitle: Text(
                    'Status: ${session['status'] ?? 'unknown'} · '
                    'Started ${session['start_time'] ?? '?'}'
                    '${routeName != null ? ' · $routeName' : ''}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  SessionTrackingScreen(session: session),
                            ),
                          );
                        },
                        child: const Text('Watch'),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Delete',
                        onPressed: () => _deleteSession(session),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
