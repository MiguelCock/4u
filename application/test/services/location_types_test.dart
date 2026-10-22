import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/services/destinations.dart';
import 'package:eyes4u/services/location_types.dart';

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final es = lookupAppLocalizations(const Locale('es'));

  test('catalog matches db_schema/location_type.sql exactly', () {
    final sql = File('../db_schema/location_type.sql').readAsStringSync();
    final rows = {
      for (final m in RegExp(r"\((\d+), '(\w+)'").allMatches(sql))
        int.parse(m.group(1)!): m.group(2)!,
    };
    expect(kLocationTypes, rows);
  });

  test('ids are unique and hallway / outdoor path come first', () {
    final ids = kLocationTypeCatalog.map((t) => t.id).toList();
    expect(ids.toSet().length, ids.length);
    expect(kLocationTypeCatalog.take(2).map((t) => t.key), [
      'hallway',
      'outdoor_path',
    ]);
  });

  test('every type and category has a real label in both languages', () {
    for (final l10n in [en, es]) {
      for (final type in kLocationTypeCatalog) {
        expect(locationTypeLabel(l10n, type.key), isNot(type.key));
      }
      for (final category in LocationCategory.values) {
        expect(locationCategoryLabel(l10n, category), isNotEmpty);
      }
    }
  });

  test('in-between paths are never destinations, the new places are', () {
    for (final type in kLocationTypeCatalog) {
      if (type.category == LocationCategory.paths) {
        expect(isDestinationType(type.id), isFalse, reason: type.key);
      }
    }
    for (var id = 19; id <= 33; id++) {
      expect(isDestinationType(id), isTrue, reason: '$id');
    }
  });

  test('search is accent-insensitive and follows the language', () {
    expect(searchLocationTypes(es, 'pape').map((t) => t.key), [
      'stationery_shop',
    ]);
    expect(
      searchLocationTypes(es, 'cómputo').map((t) => t.key),
      contains('computer_room'),
    );
    expect(searchLocationTypes(en, 'library').map((t) => t.key), ['library']);
    expect(searchLocationTypes(en, ''), kLocationTypeCatalog);
    // A category name finds all its types.
    expect(
      searchLocationTypes(en, 'wellbeing').map((t) => t.key),
      containsAll(['infirmary', 'sports_area', 'chapel']),
    );
  });
}
