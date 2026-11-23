import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../widgets/scrollable_message.dart';

/// A tab's search box.
class AdminSearchField extends StatelessWidget {
  const AdminSearchField({
    super.key,
    required this.controller,
    required this.hint,
  });

  final TextEditingController controller;
  final String hint;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
    child: TextField(
      controller: controller,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(Icons.search),
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    ),
  );
}

/// A tab's list: a [header] (scope dropdowns), a [search] box, then
/// [itemCount] rows from [itemBuilder], or [empty] when there are none.
class AdminListTab extends StatelessWidget {
  const AdminListTab({
    super.key,
    this.header,
    required this.search,
    required this.empty,
    required this.itemCount,
    required this.itemBuilder,
    required this.bottomPadding,
  });

  final Widget? header;
  final Widget search;
  final String empty;
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;

  /// Clears the floating buttons, which otherwise cover the last row's
  /// trailing buttons.
  final double bottomPadding;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ?header,
      search,
      Expanded(
        child: itemCount == 0
            ? ScrollableMessage(empty)
            : ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(bottom: bottomPadding),
                itemCount: itemCount,
                itemBuilder: itemBuilder,
              ),
      ),
    ],
  );
}

/// The Universities and Buildings tabs: [rows] (already filtered and
/// sorted) under a [search] box, each opening what's inside it on a tap,
/// with Edit and Delete. [empty] is said when there are none.
class NamedRowsTab extends StatelessWidget {
  const NamedRowsTab({
    super.key,
    this.header,
    required this.search,
    required this.rows,
    required this.empty,
    required this.icon,
    required this.iconColor,
    required this.subtitle,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
    required this.bottomPadding,
  });

  /// Above the search box (the Buildings tab's university dropdown).
  final Widget? header;
  final Widget search;
  final List<Map<String, dynamic>> rows;
  final String empty;
  final IconData icon;
  final Color iconColor;
  final String Function(Map<String, dynamic> row) subtitle;
  final void Function(Map<String, dynamic> row) onOpen;
  final void Function(Map<String, dynamic> row) onEdit;
  final void Function(Map<String, dynamic> row) onDelete;

  /// Clears the floating buttons, which otherwise cover the last row's
  /// trailing buttons.
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AdminListTab(
      header: header,
      search: search,
      empty: empty,
      itemCount: rows.length,
      bottomPadding: bottomPadding,
      itemBuilder: (context, index) {
        final row = rows[index];
        return ListTile(
          onTap: () => onOpen(row),
          leading: Icon(icon, color: iconColor),
          title: Text(row['name'] as String? ?? row['id'] as String),
          subtitle: Text(subtitle(row)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: l10n.commonEdit,
                onPressed: () => onEdit(row),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: l10n.commonDelete,
                onPressed: () => onDelete(row),
              ),
            ],
          ),
        );
      },
    );
  }
}
