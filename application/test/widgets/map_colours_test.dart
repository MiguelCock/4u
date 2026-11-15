import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/services/location_types.dart';
import 'package:eyes4u/theme/admin_palette.dart';
import 'package:eyes4u/widgets/admin_map/admin_map.dart';
import 'package:eyes4u/widgets/admin_map/layers.dart';
import 'package:eyes4u/widgets/admin_map/map_legend.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';

const _view = AdminMapView(floor: 0, onlySelected: false);

Map<String, dynamic> _point(
  String id,
  double lat, {
  int type = 10,
  String? name,
}) => {
  'id': id,
  'latitude': lat,
  'longitude': -75.5,
  'floor': 0,
  'status': 'verified',
  'location_type_id': type,
  'location_description': name,
};

void main() {
  test('a named destination is a marker; an in-between point a dot', () {
    final layers = PointsLayer(
      points: [
        _point('a', 6.2),
        // Cafeteria (8), named.
        _point('b', 6.2001, type: 8, name: 'Cafetería'),
        // A hallway with a name is still an in-between point.
        _point('c', 6.2002, name: 'Pasillo'),
      ],
    ).build(_view);
    final circles = layers.whereType<CircleLayer>().single.circles;
    final markers = [
      for (final l in layers.whereType<MarkerLayer>()) ...l.markers,
    ];
    expect(circles, hasLength(2));
    expect(markers, hasLength(1));
  });

  test('connections are coloured by length, thicker past 15 m', () {
    final a = _point('a', 6.2);
    final b = _point('b', 6.2001);
    Polyline lineFor(num meters) =>
        (ConnectionsLayer(
                  points: [a, b],
                  connections: [
                    {
                      'id': 'c',
                      'anchor_point_a_id': 'a',
                      'anchor_point_b_id': 'b',
                      'distance_meters': meters,
                    },
                  ],
                ).build(_view).single
                as PolylineLayer)
            .polylines
            .single;

    final short = lineFor(4);
    final long = lineFor(25);
    expect(short.color, kAdminPalette.connectionShort);
    expect(lineFor(40).color, kAdminPalette.connectionTooLong);
    expect(long.strokeWidth, greaterThan(short.strokeWidth));
  });

  test('every type has a category colour of its own kind', () {
    for (final type in kLocationTypeCatalog) {
      expect(
        kAdminPalette.category(type.category),
        isNot(kAdminPalette.inactive),
      );
    }
  });

  testWidgets('the legend names the lengths and the categories', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: MapLegend()),
      ),
    );
    expect(find.text('Hasta 5 m'), findsOneWidget);
    expect(find.text('Más de 30 m: demasiado larga'), findsOneWidget);
    expect(find.text('Académico'), findsOneWidget);
  });
}
