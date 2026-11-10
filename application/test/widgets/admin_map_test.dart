import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/services/floor_view.dart';
import 'package:eyes4u/services/map_tap.dart';
import 'package:eyes4u/widgets/admin_map/admin_map.dart';
import 'package:eyes4u/theme/admin_palette.dart';
import 'package:eyes4u/widgets/admin_map/layers.dart';

const _here = LatLng(6.2, -75.58);

Map<String, dynamic> _point(String id, int floor, {LatLng at = _here}) => {
  'id': id,
  'floor': floor,
  'status': 'verified',
  'latitude': at.latitude,
  'longitude': at.longitude,
};

Future<void> _pump(
  WidgetTester tester,
  List<Map<String, dynamic>> points, {
  AdminMapMode mode = AdminMapMode.browse,
  ValueChanged<AdminMapHit>? onHit,
  ValueChanged<LatLng>? onTapPosition,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: AdminMap(
          showTiles: false,
          floors: floorsOf(points),
          // One position: the map opens centred on it.
          fitTo: [_here],
          mode: mode,
          layers: [PointsLayer(points: points)],
          onHit: onHit,
          onTapPosition: onTapPosition,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapCentre(WidgetTester tester) async {
  await tester.tapAt(tester.getCenter(find.byType(FlutterMap)));
  // flutter_map's tap gesture finishes on a timer.
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a tap picks the point on the selected floor first', (
    tester,
  ) async {
    final hits = <String>[];
    // Stairs on two floors, one on top of the other.
    await _pump(tester, [
      _point('ground', 0),
      _point('first', 1),
    ], onHit: (hit) => hits.add((hit as PointHit).point['id'] as String));

    await _tapCentre(tester);
    await tester.tap(find.byTooltip('Go up a floor'));
    await tester.pumpAndSettle();
    await _tapCentre(tester);

    expect(hits, ['ground', 'first']);
  });

  testWidgets('moving reports the position, even on a point', (tester) async {
    final hits = <AdminMapHit>[];
    final taps = <LatLng>[];
    await _pump(
      tester,
      [_point('p', 0)],
      mode: AdminMapMode.move,
      onHit: hits.add,
      onTapPosition: taps.add,
    );

    await _tapCentre(tester);

    expect(hits, isEmpty);
    expect(taps.single.latitude, closeTo(_here.latitude, 1e-6));
    expect(taps.single.longitude, closeTo(_here.longitude, 1e-6));
  });

  testWidgets('a tap far from every point hits nothing', (tester) async {
    final hits = <AdminMapHit>[];
    await _pump(tester, [
      _point('far', 0, at: const LatLng(6.201, -75.58)),
      // Two floors up: neither shown nor tappable.
      _point('hidden', 2),
    ], onHit: hits.add);

    await _tapCentre(tester);

    expect(hits, isEmpty);
  });

  testWidgets('"only this floor" is remembered for every map', (tester) async {
    await _pump(tester, [_point('a', 0), _point('b', 1)]);

    await tester.tap(find.text('Only this floor'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('map_only_selected_floor'), isTrue);
  });

  testWidgets('a thousand points cost no more widgets than ten', (
    tester,
  ) async {
    List<Map<String, dynamic>> grid(int n) => [
      for (var i = 0; i < n; i++)
        _point(
          'p$i',
          0,
          at: LatLng(6.2 + (i ~/ 40) * 1e-5, -75.58 + (i % 40) * 1e-5),
        ),
    ];
    int elements() => find
        .descendant(of: find.byType(FlutterMap), matching: find.byType(Widget))
        .evaluate()
        .length;

    await _pump(tester, grid(10));
    final few = elements();
    final watch = Stopwatch()..start();
    await _pump(tester, grid(1000));
    watch.stop();

    expect(elements(), few);
    // Generous, for slow CI machines; the widget count above is the real check.
    expect(watch.elapsedMilliseconds, lessThan(3000));
  });

  test('status colours come from the palette', () {
    expect(anchorStatusColor('verified'), kAdminPalette.verified);
    expect(anchorStatusColor('rejected'), kAdminPalette.rejected);
    expect(anchorStatusColor('pending'), kAdminPalette.pending);
    expect(anchorStatusColor(null), kAdminPalette.pending);
    expect(anchorPosition(_point('p', 0)), _here);
  });

  testWidgets('each layer shows and is tapped only in its zoom band', (
    tester,
  ) async {
    Future<AdminMapHit?> tapAtZoom(double maxZoom) async {
      AdminMapHit? hit;
      final place = {'id': 'u', 'latitude': 6.2, 'longitude': -75.58};
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AdminMap(
              key: UniqueKey(),
              showTiles: false,
              floors: const [0],
              fitTo: [_here],
              fitMaxZoom: maxZoom,
              layers: [
                PlacesLayer(places: [place], buildingCounts: const {}),
                PointsLayer(points: [_point('p', 0)], minZoom: kMapPointsZoom),
              ],
              onHit: (h) => hit = h,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _tapCentre(tester);
      return hit;
    }

    // The same spot: far out it's the university, close in it's the point.
    expect(await tapAtZoom(14), isA<PlaceHit>());
    expect(await tapAtZoom(19), isA<PointHit>());
  });
}
