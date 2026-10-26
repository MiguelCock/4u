import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eyes4u/services/anchor_filters.dart';
import 'package:eyes4u/services/capture_defaults.dart';
import 'package:eyes4u/services/location_types.dart';

void main() {
  final hallway = {
    'id': 'h',
    'location_type_id': 10,
    'floor': 0,
    'metadata': {'indoor': true, 'lighting': 'dim'},
  };
  final library = {
    'id': 'l',
    'location_type_id': 23,
    'floor': 2,
    'metadata': <String, dynamic>{},
  };
  final outdoor = {
    'id': 'o',
    'location_type_id': 12,
    'metadata': {'indoor': false},
  };
  final all = [hallway, library, outdoor];

  List<String> ids(AnchorFilters f) => [
    for (final p in all)
      if (f.matches(p, withPhotos: {'h', 'l'}, connected: {'h'}))
        p['id'] as String,
  ];

  test('no filters match everything', () {
    expect(ids(AnchorFilters.none), ['h', 'l', 'o']);
    expect(AnchorFilters.none.activeCount, 0);
  });

  test('category and type', () {
    expect(ids(const AnchorFilters(category: LocationCategory.paths)), [
      'h',
      'o',
    ]);
    expect(ids(const AnchorFilters(locationTypeId: 23)), ['l']);
  });

  test('floor treats a missing floor as the ground floor', () {
    expect(ids(const AnchorFilters(floor: 0)), ['h', 'o']);
    expect(ids(const AnchorFilters(floor: 2)), ['l']);
  });

  test('indoor / outdoor / not set and lighting', () {
    expect(ids(const AnchorFilters(indoor: 'indoor')), ['h']);
    expect(ids(const AnchorFilters(indoor: 'outdoor')), ['o']);
    expect(ids(const AnchorFilters(indoor: 'unset')), ['l']);
    expect(ids(const AnchorFilters(lighting: 'dim')), ['h']);
    expect(ids(const AnchorFilters(lighting: 'unset')), ['l', 'o']);
  });

  test('photos and connections, combined with other filters', () {
    expect(ids(const AnchorFilters(hasPhotos: false)), ['o']);
    expect(ids(const AnchorFilters(hasConnections: false)), ['l', 'o']);
    const combined = AnchorFilters(hasPhotos: true, hasConnections: false);
    expect(ids(combined), ['l']);
    expect(combined.activeCount, 2);
  });

  test('copyWith can clear a single filter', () {
    const f = AnchorFilters(floor: 2, indoor: 'indoor');
    expect(f.copyWith(floor: null).floor, isNull);
    expect(f.copyWith(floor: null).indoor, 'indoor');
  });

  test('capture defaults round-trip through preferences', () async {
    SharedPreferences.setMockInitialValues({});
    expect((await CaptureDefaults.load()).buildingId, isNull);
    await const CaptureDefaults(
      buildingId: 'b1',
      locationTypeId: 12,
      floor: 1,
      indoor: false,
      lighting: 'bright',
    ).save();
    final loaded = await CaptureDefaults.load();
    expect(loaded.buildingId, 'b1');
    expect(loaded.locationTypeId, 12);
    expect(loaded.floor, 1);
    expect(loaded.indoor, isFalse);
    expect(loaded.lighting, 'bright');
  });
}
