import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import 'user_sessions_screen.dart' show sessionStatusLabel;

/// Admin-only: every submitted comment (`GET /navigation/feedback`, finally
/// a real caller - previously write-only, see #89), newest first, with the
/// submitting user's name (`GET /user/profiles`) and the linked session's
/// status - or "Session deleted" when `session_id` is null, since deleting
/// a session deliberately detaches its feedback rather than deleting them
/// (see backend-navigation-management's `DELETE /sessions/{id}`). Rows with
/// no comment text are skipped - nothing to show.
class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  final _navigationApi = NavigationManagementApi();
  final _userApi = UserManagementApi();
  late Future<_FeedbackData> _dataFuture;

  @override
  void initState() {
    super.initState();
    _dataFuture = _load();
  }

  Future<_FeedbackData> _load() async {
    final results = await Future.wait([
      _navigationApi.get('/feedback'),
      _userApi.get('/profiles'),
      _navigationApi.get('/sessions'),
    ]);
    final feedback =
        (results[0] as List? ?? [])
            .cast<Map<String, dynamic>>()
            .where((f) => (f['comment'] as String? ?? '').trim().isNotEmpty)
            .toList()
          ..sort(
            (a, b) => (b['created_at'] as String? ?? '').compareTo(
              a['created_at'] as String? ?? '',
            ),
          );
    final profiles = (results[1] as List? ?? []).cast<Map<String, dynamic>>();
    final sessions = (results[2] as List? ?? []).cast<Map<String, dynamic>>();
    return _FeedbackData(
      feedback: feedback,
      profilesById: {for (final p in profiles) p['id'] as String: p},
      sessionsById: {for (final s in sessions) s['id'] as String: s},
    );
  }

  void _refresh() {
    setState(() => _dataFuture = _load());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.feedbackScreenTitle),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => _refresh(),
        child: FutureBuilder<_FeedbackData>(
          future: _dataFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Text(
                  l10n.feedbackErrorLoadFailed(snapshot.error.toString()),
                ),
              );
            }
            final data = snapshot.data!;
            if (data.feedback.isEmpty) {
              return Center(child: Text(l10n.feedbackEmpty));
            }
            return ListView.builder(
              itemCount: data.feedback.length,
              itemBuilder: (context, index) {
                final item = data.feedback[index];
                final userId = item['user_id'] as String?;
                final sessionId = item['session_id'] as String?;
                final profile = userId != null
                    ? data.profilesById[userId]
                    : null;
                final session = sessionId != null
                    ? data.sessionsById[sessionId]
                    : null;
                return ListTile(
                  leading: const Icon(Icons.comment_outlined),
                  title: Text(item['comment'] as String? ?? ''),
                  subtitle: Text(
                    '${profile?['full_name'] as String? ?? userId ?? '?'} · '
                    '${item['created_at'] as String? ?? '?'} · '
                    '${session != null ? sessionStatusLabel(l10n, session['status'] as String?) : l10n.feedbackSessionDeleted}',
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

class _FeedbackData {
  final List<Map<String, dynamic>> feedback;
  final Map<String, Map<String, dynamic>> profilesById;
  final Map<String, Map<String, dynamic>> sessionsById;

  _FeedbackData({
    required this.feedback,
    required this.profilesById,
    required this.sessionsById,
  });
}
