import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// The home screen's pieces of layout (#268), so its `build` reads as the
/// screen. Each only shows what it's given and reports taps.

/// "Admin preview - testing the user flow", on the admin's Test as user.
class AdminPreviewBanner extends StatelessWidget {
  const AdminPreviewBanner({super.key});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: Colors.amber.shade100,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Text(
      AppLocalizations.of(context)!.adminPreviewBanner,
      // A fixed light amber in any theme: in dark mode the ambient text
      // colour would be near-white.
      style: const TextStyle(
        color: Colors.black87,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

/// The Start row: where the trip starts ([subtitle]), with a spinner while
/// the camera check runs. [onCheck] (admins' preview only) runs the check.
class StartRow extends StatelessWidget {
  const StartRow({
    super.key,
    required this.subtitle,
    required this.locating,
    required this.canCheck,
    this.onCheck,
  });

  final String subtitle;
  final bool locating;
  final bool canCheck;
  final VoidCallback? onCheck;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListTile(
      leading: const Icon(Icons.radio_button_checked, color: Colors.blue),
      title: Text(l10n.homeStartLabel),
      // Not a live region: it changes on every GPS fix, and the start
      // check's result is spoken (#257).
      subtitle: Semantics(child: Text(subtitle)),
      trailing: locating
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : canCheck
          ? Icon(Icons.my_location, semanticLabel: l10n.homeCheckStartTooltip)
          : null,
      onTap: onCheck,
    );
  }
}

/// The destination row: "Destination: X / Tap to change the destination".
/// "¿A dónde vas? Biblioteca" read as a question about the place already
/// chosen: no tester knew it was where to change it.
class DestinationRow extends StatelessWidget {
  const DestinationRow({super.key, required this.name, required this.onTap});

  /// The destination's name, or null when none is chosen.
  final String? name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final chosen = name;
    return ListTile(
      leading: Icon(
        chosen == null ? Icons.radio_button_unchecked : Icons.location_on,
        color: chosen == null ? Colors.grey : Colors.blue,
      ),
      title: Text(
        chosen == null
            ? l10n.homeChooseDestination
            : l10n.homeDestinationLabel(chosen),
      ),
      subtitle: Text(
        chosen == null
            ? l10n.homeTapToChooseDestination
            : l10n.homeTapToChangeDestination,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

/// "Say where you want to go", next to the choices; while listening, stop.
class SayDestinationButton extends StatelessWidget {
  const SayDestinationButton({
    super.key,
    required this.listening,
    required this.onPressed,
  });

  final bool listening;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56)),
        onPressed: onPressed,
        icon: Icon(listening ? Icons.stop_circle_outlined : Icons.mic),
        label: Text(
          listening ? l10n.homeListening : l10n.homeSayDestinationButton,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

/// Find route, with a spinner while [finding].
class FindRouteButton extends StatelessWidget {
  const FindRouteButton({
    super.key,
    required this.finding,
    required this.onPressed,
  });

  final bool finding;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: FilledButton(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(64),
          textStyle: Theme.of(context).textTheme.titleLarge,
        ),
        onPressed: onPressed,
        child: finding
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  semanticsLabel: l10n.homeFindingRoute,
                ),
              )
            : Text(l10n.homeFindRouteButton),
      ),
    );
  }
}

/// Help, settings and log out, at the bottom (D2): they don't compete with
/// the main task.
class HomeFooter extends StatelessWidget {
  const HomeFooter({
    super.key,
    required this.onHelp,
    required this.onSettings,
    required this.onLogOut,
  });

  final VoidCallback onHelp;
  final VoidCallback onSettings;
  final VoidCallback onLogOut;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.help_outline),
          title: Text(l10n.homeTutorialButton),
          onTap: onHelp,
        ),
        ListTile(
          leading: const Icon(Icons.settings_outlined),
          title: Text(l10n.homeSettingsTooltip),
          onTap: onSettings,
        ),
        ListTile(
          leading: const Icon(Icons.logout),
          title: Text(l10n.commonLogOut),
          onTap: onLogOut,
        ),
      ],
    );
  }
}
