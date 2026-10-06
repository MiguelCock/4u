import 'package:flutter/material.dart';

import '../services/api_service.dart';
import 'session_tracking_screen.dart';

/// Admin-only: lists currently-active navigation sessions (GET /sessions,
/// filtered client-side to status == 'active' - same "fetch all, filter
/// client-side" convention every other list in this app already uses),
/// so an admin can watch one happen live via SessionTrackingScreen.
class LiveSessionsScreen extends StatefulWidget {
  const LiveSessionsScreen({super.key});

  @override
  State<LiveSessionsScreen> createState() => _LiveSessionsScreenState();
}

class _LiveSessionsScreenState extends State<LiveSessionsScreen> {
  final _navigationApi = NavigationManagementApi();
  late Future<List<Map<String, dynamic>>> _sessionsFuture;

  @override
  void initState() {
    super.initState();
    _sessionsFuture = _loadActiveSessions();
  }

  Future<List<Map<String, dynamic>>> _loadActiveSessions() async {
    final result = await _navigationApi.get('/sessions');
    if (result is! List) return [];
    return result
        .cast<Map<String, dynamic>>()
        .where((s) => s['status'] == 'active')
        .toList();
  }

  void _refresh() {
    setState(() {
      _sessionsFuture = _loadActiveSessions();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live sessions'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => _refresh(),
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _sessionsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Text('Failed to load sessions: ${snapshot.error}'),
              );
            }
            final sessions = snapshot.data ?? [];
            if (sessions.isEmpty) {
              return const Center(child: Text('No active sessions right now.'));
            }
            return ListView.builder(
              itemCount: sessions.length,
              itemBuilder: (context, index) {
                final session = sessions[index];
                return ListTile(
                  leading: const Icon(Icons.my_location, color: Colors.teal),
                  title: Text('Session ${session['id']}'),
                  subtitle: Text('Started ${session['start_time'] ?? '?'}'),
                  trailing: ElevatedButton(
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
                );
              },
            );
          },
        ),
      ),
    );
  }
}
