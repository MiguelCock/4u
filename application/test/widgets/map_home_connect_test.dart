import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eyes4u/admin/location_picker_screen.dart';
import 'package:eyes4u/admin/map_home.dart';
import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/services/map_scope.dart';
import 'package:eyes4u/services/map_tap.dart';
import 'package:eyes4u/widgets/admin_map/admin_map.dart';

const _bib = MapScope(placeId: 'eafit', buildingId: 'bib');

/// A point [metres] east of the building's corner.
Map<String, dynamic> _point(String id, double metres, {String? status}) => {
  'id': id,
  'building_id': 'bib',
  'floor': 0,
  'status': status ?? 'verified',
  'location_description': 'Point $id',
  'latitude': 6.2,
  'longitude': -75.58 + metres / 110600,
};

final _a = _point('a', 0);
final _b = _point('b', 20);
final _rejected = _point('r', 40, status: 'rejected');
final _line = {
  'id': 'line',
  'anchor_point_a_id': 'a',
  'anchor_point_b_id': 'b',
};

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

String _detailsOf(AdminMapHit hit) => switch (hit) {
  PlaceHit(:final place) => 'details ${place['name']}',
  BuildingHit(:final building) => 'details ${building['name']}',
  PointHit(:final point) => 'details ${point['id']}',
  ConnectionHit(:final connection) => 'details ${connection['id']}',
};

/// Shows a building's points, with [focus] settable afterwards.
Future<ValueNotifier<MapFocus?>> _pump(
  WidgetTester tester, {
  bool connecting = false,
  ValueChanged<Map<String, dynamic>>? onConnectTap,
  bool Function(Map<String, dynamic>)? pointFilter,
}) async {
  final focus = ValueNotifier<MapFocus?>(null);
  var scope = _bib;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ValueListenableBuilder(
          valueListenable: focus,
          builder: (context, value, _) => StatefulBuilder(
            builder: (context, setState) => MapHome(
              showTiles: false,
              places: _places,
              buildings: _buildings,
              points: [_a, _b, _rejected],
              connections: [_line],
              scope: scope,
              onScopeChanged: (next) => setState(() => scope = next),
              connecting: connecting,
              onConnectingChanged: (_) {},
              onConnectTap: onConnectTap,
              pointFilter: pointFilter,
              focus: value,
              pointName: (p) => p['location_description'] as String,
              details: (context, item, close) => Text(_detailsOf(item)),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return focus;
}

/// Where [position] is on the screen, through the map's own camera.
Offset _screenOf(WidgetTester tester, LatLng position) {
  final inside = find.descendant(
    of: find.byType(FlutterMap),
    matching: find.byType(MobileLayerTransformer),
  );
  final camera = MapCamera.of(tester.element(inside.first));
  return tester.getTopLeft(find.byType(FlutterMap)) +
      camera.latLngToScreenOffset(position);
}

Future<void> _tapAt(WidgetTester tester, Offset at) async {
  await tester.tapAt(at);
  // flutter_map's tap gesture finishes on a timer.
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // The picker builds its API client; with nothing to show, it never calls.
    dotenv.testLoad(fileInput: 'API_GATEWAY_URL=http://gateway.example');
  });

  testWidgets('connecting: each point tapped goes to the chain', (
    tester,
  ) async {
    final tapped = <String>[];
    await _pump(
      tester,
      connecting: true,
      onConnectTap: (p) => tapped.add(p['id'] as String),
    );

    await _tapAt(tester, _screenOf(tester, anchorPosition(_a)!));
    await _tapAt(tester, _screenOf(tester, anchorPosition(_b)!));

    expect(tapped, ['a', 'b']);
    expect(find.text('Done'), findsOneWidget);
    expect(find.textContaining('details'), findsNothing);
  });

  testWidgets('a line opens its details, a point wins over it', (tester) async {
    await _pump(tester);
    final a = _screenOf(tester, anchorPosition(_a)!);
    final b = _screenOf(tester, anchorPosition(_b)!);

    await _tapAt(tester, (a + b) / 2);
    expect(find.text('details line'), findsOneWidget);

    Navigator.of(tester.element(find.text('details line'))).pop();
    await tester.pumpAndSettle();
    await _tapAt(tester, a);
    expect(find.text('details a'), findsOneWidget);
  });

  testWidgets('a point the filters hide can\'t be tapped', (tester) async {
    await _pump(tester, pointFilter: (p) => p['status'] != 'rejected');

    await _tapAt(tester, _screenOf(tester, anchorPosition(_rejected)!));

    expect(find.textContaining('details'), findsNothing);
  });

  testWidgets('a focus request opens its item', (tester) async {
    final focus = await _pump(tester);

    focus.value = MapFocus(ConnectionHit(_line));
    await tester.pumpAndSettle();

    expect(find.text('details line'), findsOneWidget);
  });

  testWidgets('the location picker returns the spot tapped', (tester) async {
    LatLng? picked;
    const start = LatLng(6.2, -75.58);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => picked = await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const LocationPickerScreen(
                  initialPosition: start,
                  showTiles: false,
                ),
              ),
            ),
            child: const Text('pick'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('pick'));
    await tester.pumpAndSettle();

    await _tapAt(tester, _screenOf(tester, start) + const Offset(60, 0));
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(picked!.longitude, greaterThan(start.longitude));
    expect(picked!.latitude, closeTo(start.latitude, 1e-6));
  });
}
