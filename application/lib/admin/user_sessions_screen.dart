import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import 'session_tracking_screen.dart';

/// `navigation_sessions.status`'s stable storage values - this maps one to
/// its localized label without changing what's actually stored.
String sessionStatusLabel(AppLocalizations l10n, String? status) {
  return switch (status) {
    'active' => l10n.commonSessionStatusActive,
    'completed' => l10n.commonSessionStatusCompleted,
    'abandoned' => l10n.commonSessionStatusAbandoned,
    'failed' => l10n.commonSessionStatusFailed,
    _ => l10n.commonSessionStatusUnknown,
  };
}

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
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.userSessionsDeleteTitle),
        content: Text(l10n.userSessionsDeleteContent),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)!.commonErrorDeleteFailed(e.toString()),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(widget.userName)),
      body: _sessions.isEmpty
          ? Center(child: Text(l10n.userSessionsEmpty))
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
                  title: Text(l10n.userSessionsSessionLabel(session['id'])),
                  subtitle: Text(
                    l10n.userSessionsSubtitle(
                      sessionStatusLabel(l10n, session['status'] as String?),
                      session['start_time'] as String? ?? '?',
                      routeName != null ? ' · $routeName' : '',
                    ),
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
                        child: Text(l10n.userSessionsWatchButton),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: l10n.commonDelete,
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
