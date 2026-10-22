import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/location_types.dart';

/// The anchor-point "Location type" field. Tapping it opens a sheet with a
/// search box and the types grouped by category; with 33 types a plain
/// dropdown had become a long, unsorted scroll.
class LocationTypeField extends StatelessWidget {
  final int? value;
  final ValueChanged<int> onChanged;

  const LocationTypeField({
    super.key,
    required this.value,
    required this.onChanged,
  });

  Future<void> _pick(BuildContext context) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _LocationTypeSheet(selected: value),
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final type = locationTypeById(value);
    return InkWell(
      onTap: () => _pick(context),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: l10n.commonLocationTypeLabel,
          suffixIcon: const Icon(Icons.arrow_drop_down),
          helperText: type == null
              ? null
              : locationCategoryLabel(l10n, type.category),
        ),
        child: Text(type == null ? '' : locationTypeLabel(l10n, type.key)),
      ),
    );
  }
}

class _LocationTypeSheet extends StatefulWidget {
  final int? selected;

  const _LocationTypeSheet({required this.selected});

  @override
  State<_LocationTypeSheet> createState() => _LocationTypeSheetState();
}

class _LocationTypeSheetState extends State<_LocationTypeSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final matches = searchLocationTypes(l10n, _query);
    final rows = <Widget>[];
    LocationCategory? currentCategory;
    for (final type in matches) {
      if (type.category != currentCategory) {
        currentCategory = type.category;
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Semantics(
              header: true,
              child: Text(
                locationCategoryLabel(l10n, type.category),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ),
        );
      }
      final selected = type.id == widget.selected;
      rows.add(
        ListTile(
          dense: true,
          title: Text(locationTypeLabel(l10n, type.key)),
          trailing: selected ? const Icon(Icons.check) : null,
          selected: selected,
          onTap: () => Navigator.of(context).pop(type.id),
        ),
      );
    }

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.75,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  autofocus: false,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: l10n.locationTypeSearchHint,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (text) => setState(() => _query = text),
                ),
              ),
              Expanded(
                child: rows.isEmpty
                    ? Center(child: Text(l10n.locationTypeNoMatches(_query)))
                    : ListView(children: rows),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
