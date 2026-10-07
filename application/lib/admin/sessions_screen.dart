import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import 'user_sessions_screen.dart';

/// Admin-only: all navigation sessions (every status, not just active),
/// grouped by user - fetches GET /sessions + GET /profiles once (same
/// "fetch all, map/group client-side" convention every other list in this
/// app already uses, same two endpoints AdminHomeScreen's Users tab already
/// calls) and lists one row per user who has at least one session. Tapping
/// a user drills into UserSessionsScreen for that user's full session
/// history, including watching and deleting individual sessions.
class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key});

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  final _navigationApi = NavigationManagementApi();
  final _userApi = UserManagementApi();
  late Future<_UserSessions> _dataFuture;

  @override
  void initState() {
    super.initState();
    _dataFuture = _load();
  }

  Future<_UserSessions> _load() async {
    final results = await Future.wait([
      _navigationApi.get('/sessions'),
      _userApi.get('/profiles'),
    ]);
    final sessions = (results[0] as List? ?? []).cast<Map<String, dynamic>>();
    final profiles = (results[1] as List? ?? []).cast<Map<String, dynamic>>();
    final profilesById = {for (final p in profiles) p['id'] as String: p};

    final byUser = <String, List<Map<String, dynamic>>>{};
    for (final session in sessions) {
      final userId = session['user_id'] as String?;
      if (userId == null) continue;
      byUser.putIfAbsent(userId, () => []).add(session);
    }
    return _UserSessions(byUser: byUser, profilesById: profilesById);
  }

  void _refresh() {
    setState(() {
      _dataFuture = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.adminSessions),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => _refresh(),
        child: FutureBuilder<_UserSessions>(
          future: _dataFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Text(
                  l10n.sessionsErrorLoadFailed(snapshot.error.toString()),
                ),
              );
            }
            final data = snapshot.data!;
            final userIds = data.byUser.keys.toList()
              ..sort((a, b) {
                final nameA =
                    data.profilesById[a]?['full_name'] as String? ?? a;
                final nameB =
                    data.profilesById[b]?['full_name'] as String? ?? b;
                return nameA.compareTo(nameB);
              });
            if (userIds.isEmpty) {
              return Center(child: Text(l10n.sessionsEmpty));
            }
            return ListView.builder(
              itemCount: userIds.length,
              itemBuilder: (context, index) {
                final userId = userIds[index];
                final userSessions = data.byUser[userId]!;
                final activeCount = userSessions
                    .where((s) => s['status'] == 'active')
                    .length;
                final profile = data.profilesById[userId];
                return ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(profile?['full_name'] as String? ?? userId),
                  subtitle: Text(
                    l10n.sessionsCountLabel(userSessions.length) +
                        (activeCount > 0
                            ? l10n.sessionsActiveSuffix(activeCount)
                            : ''),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => UserSessionsScreen(
                          userId: userId,
                          userName: profile?['full_name'] as String? ?? userId,
                          sessions: userSessions,
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _UserSessions {
  final Map<String, List<Map<String, dynamic>>> byUser;
  final Map<String, Map<String, dynamic>> profilesById;

  _UserSessions({required this.byUser, required this.profilesById});
}
