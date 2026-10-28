import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../services/app_version.dart';

/// Opens the release download page in the browser, or says it couldn't.
Future<void> openDownload(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final failed = AppLocalizations.of(context)!.updateOpenFailed(url);
  var opened = false;
  try {
    opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {}
  if (!opened) messenger?.showSnackBar(SnackBar(content: Text(failed)));
}

/// All the app shows once the backend no longer serves this version (see
/// app_version.dart): what happened and a way to get the new one.
class UpdateRequiredScreen extends StatelessWidget {
  final AppVersionPolicy policy;

  const UpdateRequiredScreen({super.key, required this.policy});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.updateRequiredTitle)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.system_update, size: 64),
              const SizedBox(height: 16),
              Semantics(
                liveRegion: true,
                child: Text(
                  l10n.updateRequiredBody(
                    runningAppVersion ?? '?',
                    policy.latest,
                  ),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: const Icon(Icons.download),
                label: Text(l10n.updateDownload),
                onPressed: () => openDownload(context, policy.downloadUrl),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Deprecated version: says a new one is out and that this one stops
/// working at the next release. A dialog rather than a banner, so TalkBack
/// reads it.
Future<void> showUpdateAvailableDialog(
  BuildContext context,
  AppVersionPolicy policy,
) {
  final l10n = AppLocalizations.of(context)!;
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.updateAvailableTitle),
      content: Text(l10n.updateAvailableBody(policy.latest)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(l10n.updateLater),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            openDownload(context, policy.downloadUrl);
          },
          child: Text(l10n.updateDownload),
        ),
      ],
    ),
  );
}
