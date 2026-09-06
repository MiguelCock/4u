import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../admin/admin_home_screen.dart';
import '../services/api_service.dart';
import '../user/user_home_screen.dart';
import 'login_screen.dart';

/// Matches roles.sql's seeded values (`db_schema/roles.sql`).
const int kAdminRoleId = 2;

/// Shows LoginScreen when signed out; when signed in, fetches the user's
/// profile from backend-user-management to decide which role's home screen
/// to show. If the profile fetch fails (backend down, profile row missing
/// because signup's POST /profiles call failed, etc.) this falls back to
/// the `user` home screen rather than getting stuck — there's no error
/// screen for "logged in but no profile" in this first pass.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final _userApi = UserManagementApi();

  Future<Map<String, dynamic>?> _fetchProfile(String userId) async {
    try {
      final result = await _userApi.get('/profiles/$userId');
      if (result is Map<String, dynamic>) return result;
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = Supabase.instance.client.auth.currentSession;
        if (session == null) {
          return const LoginScreen();
        }

        return FutureBuilder<Map<String, dynamic>?>(
          future: _fetchProfile(session.user.id),
          builder: (context, profileSnapshot) {
            if (profileSnapshot.connectionState != ConnectionState.done) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
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
