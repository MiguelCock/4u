import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../admin/admin_home_screen.dart';
import '../l10n/app_localizations.dart';
import '../services/api_error_messages.dart';
import '../services/api_service.dart';
import '../services/app_preferences.dart';
import '../services/app_version.dart';
import '../user/user_home_screen.dart';
import '../widgets/app_update.dart';
import 'login_screen.dart';

/// Matches roles.sql's seeded values (`db_schema/roles.sql`).
const int kAdminRoleId = 2;

/// Shows LoginScreen when signed out; when signed in, fetches the user's
/// profile from backend-user-management to decide which role's home screen
/// to show. A 404 (no profile row - e.g. signup's POST /profiles call
/// failed after the Supabase Auth account was already created, since
/// there's no compensating transaction between the two - see
/// signup_screen.dart) self-heals by creating the missing row right here,
/// rather than just working around its absence - a real production
/// account was once left stuck with no profile at all (no Settings access,
/// couldn't be promoted to admin) until this existed. Anything else that
/// goes wrong (backend unreachable, a non-404 error response, a hung
/// connection, or the self-heal POST itself failing) shows a distinct
/// error screen with a retry action instead - silently landing on the user
/// home screen for a real failure masked a real backend outage as what
/// looked like a login bug (see #114/#115).
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final _userApi = UserManagementApi();

  /// The deprecated-version notice is shown once per launch.
  static bool _versionChecked = false;

  String? _fetchedForUserId;
  Future<Map<String, dynamic>?>? _profileFuture;

  Future<Map<String, dynamic>?> _fetchProfile(String userId) async {
    try {
      final result = await _userApi
          .get('/profiles/$userId')
          .timeout(const Duration(seconds: 10));
      if (result is Map<String, dynamic>) return _applyAndReturn(result);
      return null;
    } on ApiException catch (e) {
      // Anything but a missing row (5xx, etc.) is a real failure and
      // should propagate to FutureBuilder's hasError instead of being
      // swallowed here.
      if (e.statusCode != 404) rethrow;
    }
    // No profile row - self-heal it now rather than just working around
    // its absence. id/role_id are forced server-side to this verified
    // caller / the default `user` role regardless of what's sent (see
    // backend-user-management's create_profile), so an empty body is
    // enough. If this also fails (e.g. a rare race with another self-heal
    // attempt), let it propagate the same way a GET failure would.
    // The name typed at signup travels as Supabase user metadata, since
    // with email confirmation on there's no session to create the profile
    // with until the confirmation link signs the user in (signup_screen).
    final fullName =
        Supabase.instance.client.auth.currentUser?.userMetadata?['full_name']
            as String?;
    final created = await _userApi.post('/profiles', {
      if (fullName != null && fullName.trim().isNotEmpty)
        'full_name': fullName.trim(),
    });
    final row = (created as List).first as Map<String, dynamic>;
    return _applyAndReturn(row);
  }

  /// Resolves after an await, outside any widget's build() call stack -
  /// safe to mutate a ValueNotifier an ancestor listens to here, unlike
  /// doing it synchronously inside build() (which would trip a "setState
  /// called during build" assertion on MainApp's ValueListenableBuilder
  /// while this subtree is still building).
  Map<String, dynamic> _applyAndReturn(Map<String, dynamic> result) {
    _checkAppVersion();
    if (mounted) {
      applyPreferences(
        result['preferences'] as Map<String, dynamic>?,
        defaultHighContrast: MediaQuery.of(context).highContrast,
        defaultTextScale: MediaQuery.of(context).textScaler.scale(1.0),
      );
    }
    return result;
  }

  /// Once per launch, after sign-in: is this version still the newest?
  /// Best effort - a failure here never blocks the app, and an unsupported
  /// version is caught by the backend's 426 anyway.
  Future<void> _checkAppVersion() async {
    final running = runningAppVersion;
    if (_versionChecked || running == null) return;
    _versionChecked = true;
    try {
      final policy = AppVersionPolicy.fromJson(
        await _userApi.get('/app-version'),
      );
      if (policy == null || !mounted) return;
      switch (appVersionStatus(running, policy)) {
        case AppVersionStatus.unsupported:
          updateRequiredNotifier.value = policy;
        case AppVersionStatus.deprecated:
          await showUpdateAvailableDialog(context, policy);
        case AppVersionStatus.current:
          break;
      }
    } on ApiException catch (_) {}
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
              final l10n = AppLocalizations.of(context)!;
              return Scaffold(
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            friendlyApiErrorMessage(
                              context,
                              profileSnapshot.error!,
                              fallback: l10n.authGateUnreachable,
                            ),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: () => _retry(session.user.id),
                          child: Text(l10n.commonRetry),
                        ),
                        // A way out if retrying keeps failing (e.g. a
                        // session that can't be refreshed) - otherwise this
                        // screen is a dead end.
                        TextButton(
                          onPressed: () =>
                              Supabase.instance.client.auth.signOut(),
                          child: Text(l10n.commonLogOut),
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
            // The web app is only for managing the data: trips need the
            // phone's camera, GPS and sensors.
            if (kIsWeb) return const _WebAdminOnlyScreen();
            return const UserHomeScreen();
          },
        );
      },
    );
  }
}

class _WebAdminOnlyScreen extends StatelessWidget {
  const _WebAdminOnlyScreen();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.webAdminOnlyTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.phone_android, size: 56),
                const SizedBox(height: 16),
                Text(l10n.webAdminOnlyBody, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                OutlinedButton(
                  onPressed: () => Supabase.instance.client.auth.signOut(),
                  child: Text(l10n.commonLogOut),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
