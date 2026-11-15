import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/anchor_filters.dart';
import '../../services/connection_filters.dart';
import '../../services/location_types.dart';

/// The points' filters sheet (the Map and the Anchor points tab). Each
/// change applies right away ([onChanged]) to the list or map behind it;
/// [current] is read again after each one. [count] gives a status's
/// points before these filters (null: all), [maxFloors] the floors offered.
Future<void> showAnchorFiltersSheet(
  BuildContext context, {
  required AnchorFilters Function() current,
  required void Function(AnchorFilters next) onChanged,
  required int Function(String? status) count,
  required int maxFloors,
}) async {
  final l10n = AppLocalizations.of(context)!;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheetState) {
        final f = current();
        void update(AnchorFilters next) {
          onChanged(next);
          setSheetState(() {});
        }

        Widget section(String title, List<Widget> chips) => Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Wrap(spacing: 6, runSpacing: 4, children: chips),
            ],
          ),
        );
        Widget choice<T>(
          String label,
          T? value,
          T? current,
          void Function(T?) set,
        ) => ChoiceChip(
          label: Text(label),
          selected: value == current,
          onSelected: (_) => set(value),
        );

        final typesInCategory = f.category == null
            ? const <LocationType>[]
            : kLocationTypeCatalog
                  .where((t) => t.category == f.category)
                  .toList();

        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.8,
            ),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.adminFiltersTitle,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (!f.isEmpty)
                      TextButton(
                        onPressed: () => update(AnchorFilters.none),
                        child: Text(l10n.adminFiltersClear),
                      ),
                  ],
                ),
                section(l10n.adminFilterStatus, [
                  for (final (value, label) in [
                    (null, l10n.commonStatusAll),
                    ('pending', l10n.commonStatusPending),
                    ('verified', l10n.commonStatusVerified),
                    ('rejected', l10n.commonStatusRejected),
                  ])
                    choice<String>(
                      l10n.adminStatusChipLabel(label, count(value)),
                      value,
                      f.status,
                      (v) => update(f.copyWith(status: v)),
                    ),
                ]),
                section(l10n.adminFilterCategory, [
                  choice<LocationCategory>(
                    l10n.adminFilterAny,
                    null,
                    f.category,
                    (v) =>
                        update(f.copyWith(category: v, locationTypeId: null)),
                  ),
                  for (final category in LocationCategory.values)
                    choice<LocationCategory>(
                      locationCategoryLabel(l10n, category),
                      category,
                      f.category,
                      (v) =>
                          update(f.copyWith(category: v, locationTypeId: null)),
                    ),
                ]),
                if (typesInCategory.isNotEmpty)
                  section(l10n.adminFilterType, [
                    choice<int>(
                      l10n.adminFilterAny,
                      null,
                      f.locationTypeId,
                      (v) => update(f.copyWith(locationTypeId: v)),
                    ),
                    for (final type in typesInCategory)
                      choice<int>(
                        locationTypeLabel(l10n, type.key),
                        type.id,
                        f.locationTypeId,
                        (v) => update(f.copyWith(locationTypeId: v)),
                      ),
                  ]),
                section(l10n.adminFilterFloor, [
                  choice<int>(
                    l10n.adminFilterAny,
                    null,
                    f.floor,
                    (v) => update(f.copyWith(floor: v)),
                  ),
                  for (var floor = 0; floor < maxFloors; floor++)
                    choice<int>(
                      l10n.commonFloorOption(floor + 1),
                      floor,
                      f.floor,
                      (v) => update(f.copyWith(floor: v)),
                    ),
                ]),
                section(l10n.adminFilterPlace, [
                  for (final (label, value) in [
                    (l10n.adminFilterAny, null),
                    (l10n.adminFilterIndoor, 'indoor'),
                    (l10n.adminFilterOutdoor, 'outdoor'),
                    (l10n.adminFilterNotSet, 'unset'),
                  ])
                    choice<String>(
                      label,
                      value,
                      f.indoor,
                      (v) => update(f.copyWith(indoor: v)),
                    ),
                ]),
                section(l10n.adminFilterLighting, [
                  for (final (label, value) in [
                    (l10n.adminFilterAny, null),
                    (l10n.commonLightingBright, 'bright'),
                    (l10n.commonLightingModerate, 'moderate'),
                    (l10n.commonLightingDim, 'dim'),
                    (l10n.adminFilterNotSet, 'unset'),
                  ])
                    choice<String>(
                      label,
                      value,
                      f.lighting,
                      (v) => update(f.copyWith(lighting: v)),
                    ),
                ]),
                section(l10n.adminFilterPhotos, [
                  for (final (label, value) in [
                    (l10n.adminFilterAny, null),
                    (l10n.adminFilterHas, true),
                    (l10n.adminFilterHasNone, false),
                  ])
                    choice<bool>(
                      label,
                      value,
                      f.hasPhotos,
                      (v) => update(f.copyWith(hasPhotos: v)),
                    ),
                ]),
                section(l10n.adminFilterConnections, [
                  for (final (label, value) in [
                    (l10n.adminFilterAny, null),
                    (l10n.adminFilterHas, true),
                    (l10n.adminFilterHasNone, false),
                  ])
                    choice<bool>(
                      label,
                      value,
                      f.hasConnections,
                      (v) => update(f.copyWith(hasConnections: v)),
                    ),
                ]),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// The Connections tab's filters sheet: long, with a warning, changes
/// floor. Like [showAnchorFiltersSheet], each change applies right away.
Future<void> showConnectionFiltersSheet(
  BuildContext context, {
  required ConnectionFilters Function() current,
  required void Function(ConnectionFilters next) onChanged,
}) async {
  final l10n = AppLocalizations.of(context)!;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheetState) {
        final f = current();
        void update(ConnectionFilters next) {
          onChanged(next);
          setSheetState(() {});
        }

        Widget section(String title, bool? current, void Function(bool?) set) {
          Widget choice(String label, bool? value) => ChoiceChip(
            label: Text(label),
            selected: value == current,
            onSelected: (_) => set(value),
          );
          return Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  children: [
                    choice(l10n.adminFilterAny, null),
                    choice(l10n.adminFilterYes, true),
                    choice(l10n.adminFilterNo, false),
                  ],
                ),
              ],
            ),
          );
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.adminConnectionFiltersTitle,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (!f.isEmpty)
                      TextButton(
                        onPressed: () => update(ConnectionFilters.none),
                        child: Text(l10n.adminFiltersClear),
                      ),
                  ],
                ),
                section(
                  l10n.adminConnectionFilterLong,
                  f.long,
                  (v) => update(f.copyWith(long: v)),
                ),
                section(
                  l10n.adminConnectionFilterWarning,
                  f.hasWarning,
                  (v) => update(f.copyWith(hasWarning: v)),
                ),
                section(
                  l10n.adminConnectionChangesFloor,
                  f.changesFloor,
                  (v) => update(f.copyWith(changesFloor: v)),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
