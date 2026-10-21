import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';

/// "Press back again to exit" for the app's root screens (the admin and
/// user homes are `AuthGate`'s child, not pushed routes, so a bare system
/// back used to close the app with no warning). The first back shows a
/// SnackBar; a second one within [window] exits.
class ExitGuard {
  static const window = Duration(seconds: 2);

  DateTime? _lastBackAt;

  void onBack(BuildContext context) {
    final now = DateTime.now();
    if (_lastBackAt != null && now.difference(_lastBackAt!) < window) {
      SystemNavigator.pop();
      return;
    }
    _lastBackAt = now;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)!.commonPressBackAgainToExit,
          ),
          duration: window,
        ),
      );
  }
}
