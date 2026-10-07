import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';

/// Matches roles.sql's seeded values (`db_schema/roles.sql`) — this is
/// static reference data with no CRUD anywhere, so it's hardcoded here
/// rather than fetched.
const int kUserRoleId = 1;

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _fullNameController = TextEditingController();
  final _userApi = UserManagementApi();
  bool _submitting = false;
  String? _error;

  Future<void> _signUp() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final response = await Supabase.instance.client.auth.signUp(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
      final user = response.user;
      if (user == null) {
        if (mounted) {
          setState(
            () => _error = AppLocalizations.of(context)!.signupErrorNoUser,
          );
        }
        return;
      }

      // backend-user-management/CLAUDE.md: profiles.id has to be set
      // explicitly to the Supabase Auth user id since this service can't
      // rely on the auth.uid() DB default without a per-request session.
      try {
        await _userApi.post('/profiles', {
          'id': user.id,
          'role_id': kUserRoleId,
          if (_fullNameController.text.trim().isNotEmpty)
            'full_name': _fullNameController.text.trim(),
        });
      } on ApiException catch (e) {
        // Auth account was created even if profile creation failed; surface
        // it but don't block the auth flow itself on the backend being up.
        if (mounted) {
          setState(
            () => _error = AppLocalizations.of(
              context,
            )!.signupErrorProfileSetupFailed(e.toString()),
          );
        }
        return;
      }
      // On success, AuthGate's onAuthStateChange listener takes over.
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = AppLocalizations.of(
            context,
          )!.signupErrorSignUpFailed(e.toString()),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _fullNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.signupTitle)),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: _fullNameController,
              decoration: InputDecoration(
                labelText: l10n.signupFullNameOptional,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(labelText: l10n.loginEmailLabel),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: InputDecoration(labelText: l10n.loginPasswordLabel),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _submitting ? null : _signUp,
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.signupButton),
            ),
          ],
        ),
      ),
    );
  }
}
