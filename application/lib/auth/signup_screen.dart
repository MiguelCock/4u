import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/api_error_messages.dart';

/// Matches roles.sql's seeded values (`db_schema/roles.sql`) — this is
/// static reference data with no CRUD anywhere, so it's hardcoded here
/// rather than fetched.
const int kUserRoleId = 1;

/// Where Supabase's confirmation email sends the user: this app, via the
/// intent-filter for this scheme in AndroidManifest.xml. supabase_flutter
/// picks the link up and signs the user in. Must also be listed under
/// Authentication > URL Configuration > Redirect URLs in the Supabase
/// dashboard, or Supabase ignores it and falls back to the Site URL.
const String kAuthRedirectUrl = 'io.github.miguelcock.eyes4u://login-callback';

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

  /// Set once signup succeeded but needs the emailed link (no session yet).
  String? _confirmationSentTo;
  StreamSubscription<AuthState>? _authSub;

  @override
  void initState() {
    super.initState();
    // This screen is pushed over AuthGate's login screen, and AuthGate only
    // swaps what's under it - so once the user is signed in (straight away,
    // or later through the confirmation link), get out of the way.
    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((state) {
      if (state.event == AuthChangeEvent.signedIn && mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    });
  }

  Future<void> _signUp() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final fullName = _fullNameController.text.trim();
      final response = await Supabase.instance.client.auth.signUp(
        email: _emailController.text.trim(),
        password: _passwordController.text,
        emailRedirectTo: kAuthRedirectUrl,
        data: {if (fullName.isNotEmpty) 'full_name': fullName},
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

      // Email confirmation on: no session until the emailed link is
      // opened, so there's no token to create the profile with yet (this
      // used to fail with "Missing bearer token"). AuthGate creates it on
      // the first sign-in instead.
      if (response.session == null) {
        if (mounted) {
          setState(() => _confirmationSentTo = _emailController.text.trim());
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
            () => _error = AppLocalizations.of(context)!
                .signupErrorProfileSetupFailed(
                  friendlyApiErrorMessage(context, e),
                ),
          );
        }
        return;
      }
      // On success, AuthGate's onAuthStateChange listener takes over.
    } on AuthException catch (e) {
      setState(() => _error = friendlyApiErrorMessage(context, e));
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = AppLocalizations.of(
            context,
          )!.signupErrorSignUpFailed(friendlyApiErrorMessage(context, e)),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _emailController.dispose();
    _passwordController.dispose();
    _fullNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sentTo = _confirmationSentTo;
    if (sentTo != null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.signupCheckEmailTitle)),
        body: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.mark_email_unread_outlined, size: 64),
              const SizedBox(height: 16),
              Semantics(
                liveRegion: true,
                child: Text(
                  l10n.signupCheckEmailContent(sentTo),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.signupBackToLogin),
              ),
            ],
          ),
        ),
      );
    }
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
              Semantics(
                liveRegion: true,
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
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
