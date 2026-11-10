import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'admin_guide.dart';

/// One row of a [ReviewList]: a thing to fix, and what tapping it does.
typedef ReviewItem = ({String title, String subtitle, VoidCallback onTap});

/// A menu notice's list of things to fix (in a bottom sheet). With a
/// [guideSection], a **How to fix** link opens the admin guide's pitfall
/// there (C6); only on the web, where the guide is.
class ReviewList extends StatelessWidget {
  final ScrollController? controller;
  final String title;
  final String hint;
  final List<ReviewItem> items;
  final String? guideSection;

  /// Off on phones, which have no guide page; a test sets it.
  final bool showGuideLink;

  const ReviewList({
    super.key,
    this.controller,
    required this.title,
    required this.hint,
    required this.items,
    this.guideSection,
    this.showGuideLink = kIsWeb,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final section = guideSection;
    return ListView(
      controller: controller,
      children: [
        ListTile(
          title: Text(title, style: Theme.of(context).textTheme.titleMedium),
          subtitle: Text(hint),
        ),
        if (section != null && showGuideLink)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: TextButton.icon(
                icon: const Icon(Icons.menu_book_outlined),
                label: Text(l10n.adminHealthHowToFix),
                onPressed: () => openAdminGuide(context, section: section),
              ),
            ),
          ),
        const Divider(),
        for (final item in items)
          ListTile(
            title: Text(item.title),
            subtitle: Text(item.subtitle),
            onTap: () {
              Navigator.of(context).pop();
              item.onTap();
            },
          ),
      ],
    );
  }
}
