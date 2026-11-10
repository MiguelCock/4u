import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eyes4u/admin/map_home.dart';
import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/services/map_scope.dart';
import 'package:eyes4u/widgets/admin_map/admin_map.dart';

// One of each, all on the same spot: each level's camera centres on the
// only thing it frames, so a tap in the middle of the map hits it.
final _places = [
  {'id': 'eafit', 'name': 'EAFIT', 'latitude': 6.2, 'longitude': -75.58},
];
final _buildings = [
  {
    'id': 'bib',
    'place_id': 'eafit',
    'name': 'Biblioteca',
    'latitude': 6.2,
    'longitude': -75.58,
  },
];
final _points = [
  {
    'id': 'p1',
    'building_id': 'bib',
    'floor': 0,
    'status': 'verified',
    'location_description': 'Entrada sur',
    'latitude': 6.2,
    'longitude': -75.58,
  },
];

String _detailsOf(AdminMapHit hit) => switch (hit) {
  PlaceHit(:final place) => 'details ${place['name']}',
  BuildingHit(:final building) => 'details ${building['name']}',
  PointHit(:final point) => 'details ${point['location_description']}',
};

/// A MapHome holding its own scope, as AdminHomeScreen does.
Future<List<MapScope>> _pump(
  WidgetTester tester, {
  bool sidePanel = false,
}) async {
  final scopes = <MapScope>[];
  var scope = MapScope.all;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => MapHome(
            showTiles: false,
            sidePanel: sidePanel,
            places: _places,
            buildings: _buildings,
            points: _points,
            connections: const [],
            scope: scope,
            onScopeChanged: (next) => setState(() {
              scope = next;
              scopes.add(next);
            }),
            pointName: (p) => p['location_description'] as String,
            details: (context, item, close) => Text(_detailsOf(item)),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return scopes;
}

Future<void> _tapCentre(WidgetTester tester) async {
  await tester.tapAt(tester.getCenter(find.byType(FlutterMap)));
  // flutter_map's tap gesture finishes on a timer.
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'from everything to a point and its data without leaving the map',
    (tester) async {
      final scopes = await _pump(tester);

      await _tapCentre(tester);
      expect(scopes.last, const MapScope(placeId: 'eafit'));
      expect(find.widgetWithText(ActionChip, 'EAFIT'), findsOneWidget);

      await _tapCentre(tester);
      expect(scopes.last, const MapScope(placeId: 'eafit', buildingId: 'bib'));
      expect(find.widgetWithText(ActionChip, 'Biblioteca'), findsOneWidget);

      await _tapCentre(tester);
      expect(find.text('details Entrada sur'), findsOneWidget);
    },
  );

  testWidgets('the breadcrumb goes back up', (tester) async {
    final scopes = await _pump(tester);
    await _tapCentre(tester);
    await _tapCentre(tester);

    await tester.tap(find.widgetWithText(ActionChip, 'EAFIT'));
    await tester.pumpAndSettle();
    expect(scopes.last, const MapScope(placeId: 'eafit'));

    await tester.tap(find.widgetWithText(ActionChip, 'All'));
    await tester.pumpAndSettle();
    expect(scopes.last, MapScope.all);
    expect(find.widgetWithText(ActionChip, 'EAFIT'), findsNothing);
  });

  testWidgets('searching a point goes to its building and opens it', (
    tester,
  ) async {
    final scopes = await _pump(tester);

    await tester.enterText(find.byType(TextField), 'entrada');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Entrada sur'));
    await tester.pumpAndSettle();

    expect(scopes.last, const MapScope(placeId: 'eafit', buildingId: 'bib'));
    expect(find.text('details Entrada sur'), findsOneWidget);
  });

  testWidgets('a search with no match says so', (tester) async {
    await _pump(tester);
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('Nothing found'), findsOneWidget);
  });

  testWidgets('on a wide screen details open beside the map', (tester) async {
    await _pump(tester, sidePanel: true);

    await _tapCentre(tester);
    // Drilling into a university shows it in the panel, no sheet.
    expect(find.text('details EAFIT'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('details EAFIT'), findsNothing);
  });
}
