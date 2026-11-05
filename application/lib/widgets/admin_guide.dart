import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';

/// Where the admin tutorial is, next to the web app (`web/guide/`, built from
/// `docs/admin-guide/`; see `docs/admin-guide/tools/README.md`). [section] is
/// an anchor in its pages, such as `connections`.
Uri adminGuideUrl(Uri base, String language, {String? section}) {
  final page = base.resolve('guide/${language == 'es' ? 'es' : 'en'}/');
  return section == null ? page : page.replace(fragment: section);
}

/// Opens the tutorial in its own tab, to read next to the app. Web only: the
/// phone app has no entry for it.
Future<void> openAdminGuide(BuildContext context, {String? section}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final url = adminGuideUrl(
    Uri.base,
    Localizations.localeOf(context).languageCode,
    section: section,
  );
  final failed = AppLocalizations.of(context)!.updateOpenFailed(url.toString());
  var opened = false;
  try {
    opened = await launchUrl(url, webOnlyWindowName: '_blank');
  } catch (_) {}
  if (!opened) messenger?.showSnackBar(SnackBar(content: Text(failed)));
}
