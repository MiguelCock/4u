import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../admin/admin_home_screen.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/app_preferences.dart';
import '../user/user_home_screen.dart';
import 'login_screen.dart';

/// Matches roles.sql's seeded values (`db_schema/roles.sql`).
const int kAdminRoleId = 2;

/// Shows LoginScreen when signed out; when signed in, fetches the user's
/// profile from backend-user-management to decide which role's home screen
/// to show. A 404 (no profile row - e.g. signup's POST /profiles call
/// failed) is treated as "not an admin" and falls back to the `user` home
/// screen, same as before. Anything else that goes wrong (backend
/// unreachable, a non-404 error response, a hung connection) shows a
/// distinct error screen with a retry action instead - silently landing on
/// the user home screen for a real failure masked a real backend outage as
/// what looked like a login bug (see #114/#115).
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final _userApi = UserManagementApi();

  String? _fetchedForUserId;
  Future<Map<String, dynamic>?>? _profileFuture;

  Future<Map<String, dynamic>?> _fetchProfile(String userId) async {
    try {
      final result = await _userApi
          .get('/profiles/$userId')
          .timeout(const Duration(seconds: 10));
      if (result is Map<String, dynamic>) {
        // Resolves after an await, outside any widget's build() call stack -
        // safe to mutate a ValueNotifier an ancestor listens to here, unlike
        // doing it synchronously inside build() (which would trip a
        // "setState called during build" assertion on MainApp's
        // ValueListenableBuilder while this subtree is still building).
        if (mounted) {
          applyPreferences(
            result['preferences'] as Map<String, dynamic>?,
            defaultHighContrast: MediaQuery.of(context).highContrast,
            defaultTextScale: MediaQuery.of(context).textScaler.scale(1.0),
          );
        }
        return result;
      }
      return null;
    } on ApiException catch (e) {
      // No profile row isn't a failed round-trip - treat it the same as
      // "not an admin" (today's correct behavior). Anything else (5xx,
      // etc.) is a real failure and should propagate to FutureBuilder's
      // hasError instead of being swallowed here.
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  void _retry(String userId) {
    setState(() {
      _profileFuture = _fetchProfile(userId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = Supabase.instance.client.auth.currentSession;
        if (session == null) {
          _fetchedForUserId = null;
          _profileFuture = null;
          return const LoginScreen();
        }

        // Only start a fetch once per signed-in user id - calling
        // _fetchProfile directly inside FutureBuilder's `future:` would
        // kick off a brand new request on every rebuild, and would also
        // make a retry button impossible to wire up.
        if (_fetchedForUserId != session.user.id) {
          _fetchedForUserId = session.user.id;
          _profileFuture = _fetchProfile(session.user.id);
        }

        return FutureBuilder<Map<String, dynamic>?>(
          future: _profileFuture,
          builder: (context, profileSnapshot) {
            if (profileSnapshot.connectionState != ConnectionState.done) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            if (profileSnapshot.hasError) {
              return Scaffold(
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          AppLocalizations.of(context)!.authGateUnreachable,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.red),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: () => _retry(session.user.id),
                          child: Text(
                            AppLocalizations.of(context)!.commonRetry,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }
            final roleId = profileSnapshot.data?['role_id'] as int?;
            if (roleId == kAdminRoleId) {
              return const AdminHomeScreen();
            }
            return const UserHomeScreen();
          },
        );
      },
    );
  }
}
