import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/services/api_service.dart';
import 'package:eyes4u/services/location_service.dart';
import 'package:flutter/widgets.dart';
import 'package:eyes4u/user/trip_starter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import '../support/api_fakes.dart';

/// Where a trip starts, on its own (#268): what the map offers, the start
/// from GPS and from the camera check, the floor, and the route request.

Map<String, dynamic> _point(
  String id, {
  required double lat,
  String building = 'b1',
  String status = 'verified',
  int floor = 0,
}) => {
  'id': id,
  'building_id': building,
  'location_type_id': 8,
  'location_description': 'Punto $id',
  'status': status,
  'floor': floor,
  'latitude': lat,
  'longitude': -75.58,
};

// About 11 m per 0.0001° of latitude.
final _anchors = [
  _point('a1', lat: 6.2000),
  _point('a2', lat: 6.2010), // ~110 m north
  _point('a3', lat: 6.2000, floor: 1), // right above a1
  _point('pending', lat: 6.2000, status: 'pending'),
  _point('closed', lat: 6.2000, building: 'b2'),
  _point('alone', lat: 6.2000), // no connection
];

FakeMapApi _map({bool failConnections = false}) => FakeMapApi(
  places: [
    {'id': 'p1', 'is_active': true},
  ],
  buildings: [
    {'id': 'b1', 'place_id': 'p1', 'name': 'Edificio C', 'is_active': true},
    {'id': 'b2', 'place_id': 'p1', 'name': 'Cerrado', 'is_active': false},
  ],
  anchors: _anchors,
  connections: [
    {'anchor_point_a_id': 'a1', 'anchor_point_b_id': 'a2'},
    {'anchor_point_a_id': 'a3', 'anchor_point_b_id': 'a1'},
    {'anchor_point_a_id': 'pending', 'anchor_point_b_id': 'closed'},
  ],
  failConnections: failConnections,
);

class _Setup {
  _Setup({FakeMapApi? map}) : map = map ?? _map();

  final FakeMapApi map;
  final route = FakeRouteApi(answer: {'id': 'r1'});
  var location = LocationService.forTesting(NoLocation());
  var now = DateTime(2026, 11, 15, 10);
  late final trip = TripStarter(
    mapApi: map,
    routeApi: route,
    positioningApi: FakePositioningApi(),
    locationService: location,
    camera: () async => null, // no camera: the check falls back to GPS
    now: () => now,
  );
}

void main() {
  setUpAll(() => dotenv.testLoad(fileInput: ''));

  test(
    'the map offers verified, connected points in active buildings',
    () async {
      final s = _Setup();
      await s.trip.load();
      expect(s.trip.anchors.map((a) => a['id']), ['a1', 'a2', 'a3']);
      expect(s.trip.buildingNames['b1'], 'Edificio C');
      expect(s.trip.activeBuildings, {'b1'});
    },
  );

  test('without the connections, nothing is filtered out for them', () async {
    final s = _Setup(map: _map(failConnections: true));
    await s.trip.load();
    expect(s.trip.anchors.map((a) => a['id']), ['a1', 'a2', 'a3', 'alone']);
  });

  test('the start follows GPS to the nearest point', () async {
    final s = _Setup();
    await s.trip.load();
    var changes = 0;
    s.trip.addListener(() => changes++);

    s.trip.onPosition(fix(6.2009, -75.58));
    expect(s.trip.start?['id'], 'a2');
    s.trip.onPosition(fix(6.2001, -75.58));
    expect(s.trip.start?['id'], 'a1');
    expect(changes, 2);

    // Not while a route is being found.
    s.trip.onPosition(fix(6.2009, -75.58), busy: true);
    expect(s.trip.start?['id'], 'a1');
  });

  group('the camera check', () {
    test('runs after what the screen says, and picks the nearest', () async {
      final s = _Setup();
      s.location.lastPosition = fix(6.2009, -75.58);
      var locatingDuringPrompt = false;
      final check = await s.trip.locateStart(
        beforePhotos: () async => locatingDuringPrompt = s.trip.locating,
      );
      expect(locatingDuringPrompt, isTrue);
      expect(s.trip.locating, isFalse);
      expect(check.start?['id'], 'a2');
      expect(check.matched, 0);
      expect(s.trip.start?['id'], 'a2');
      expect(s.trip.checkIsFresh, isTrue);
    });

    test('a checked start stays until the user moves 15 m', () async {
      final s = _Setup();
      s.location.lastPosition = fix(6.2009, -75.58);
      await s.trip.locateStart();

      // GPS wanders 5 m toward a1: still the checked a2.
      s.trip.onPosition(fix(6.20085, -75.58));
      expect(s.trip.start?['id'], 'a2');

      // 90 m away: the checked start is let go.
      s.trip.onPosition(fix(6.2001, -75.58));
      expect(s.trip.start?['id'], 'a1');
      expect(s.trip.checkIsFresh, isFalse);
    });

    test('is reused for 60 s, and only where it was taken', () async {
      final s = _Setup();
      s.location.lastPosition = fix(6.2009, -75.58);
      await s.trip.locateStart();

      s.now = s.now.add(const Duration(seconds: 59));
      expect(s.trip.checkIsFresh, isTrue);
      s.location.lastPosition = fix(6.2011, -75.58); // 22 m
      expect(s.trip.checkIsFresh, isFalse);
      s.location.lastPosition = fix(6.2009, -75.58);
      s.now = s.now.add(const Duration(seconds: 2));
      expect(s.trip.checkIsFresh, isFalse);
    });

    test('with no position at all, there is no start', () async {
      final s = _Setup();
      final check = await s.trip.locateStart();
      expect(check.start, isNull);
      expect(s.trip.checkIsFresh, isFalse);
    });
  });

  test('a floor answer is kept until the user moves 15 m', () async {
    final s = _Setup();
    await s.trip.load();
    final here = const LatLng(6.2, -75.58);
    expect(s.trip.rememberedFloor([0, 1], here), isNull);

    s.trip.rememberFloor(1, here);
    expect(s.trip.rememberedFloor([0, 1], here), 1);
    expect(s.trip.rememberedFloor([0, 2], here), isNull); // not offered now
    expect(
      s.trip.rememberedFloor([0, 1], const LatLng(6.2002, -75.58)),
      isNull,
    );

    expect(s.trip.startOnFloor(1, here)?['id'], 'a3');
    expect(s.trip.start?['id'], 'a3');
    expect(s.trip.startOnFloor(0, here)?['id'], 'a1');
  });

  test('a route to a point, and to a whole building', () async {
    final s = _Setup();
    final start = _anchors.first;
    expect(await s.trip.findRoute(start, _anchors[1]), {'id': 'r1'});
    await s.trip.findRoute(start, {
      'id': 'building:b9',
      'building_id': 'b9',
      'whole_building': true,
    });
    expect(s.route.posts, [
      {'start_anchor_id': 'a1', 'end_anchor_id': 'a2'},
      {'start_anchor_id': 'a1', 'end_building_id': 'b9'},
    ]);
  });

  test('alreadyAt: the same point, or inside the building chosen', () {
    final a1 = _anchors.first;
    expect(alreadyAt(a1, a1), isTrue);
    expect(alreadyAt(a1, _anchors[1]), isFalse);
    expect(
      alreadyAt(a1, {'building_id': 'b1', 'whole_building': true}),
      isTrue,
    );
    expect(
      alreadyAt(a1, {'building_id': 'b2', 'whole_building': true}),
      isFalse,
    );
  });

  test('noPathEnd reads which end the server says is cut off', () {
    expect(noPathEnd('Your starting point is not connected'), NoPathEnd.start);
    expect(
      noPathEnd("The destination isn't connected to the others"),
      NoPathEnd.destination,
    );
    expect(noPathEnd('No walkable path found'), NoPathEnd.unknown);
    expect(noPathEnd(null), NoPathEnd.unknown);
  });

  group('planTrip', () {
    _Setup at(double lat) {
      final s = _Setup();
      s.location = LocationService.forTesting(FixedLocation(fix(lat, -75.58)));
      return s;
    }

    Future<TripOutcome> plan(
      _Setup s,
      Map<String, dynamic> end, {
      int? floor,
      List<List<int>>? asked,
      List<String>? located,
    }) => s.trip.planTrip(
      end,
      locate: () async {
        located?.add('check');
        return (await s.trip.locateStart()).start;
      },
      askFloor: (floors, here) async {
        asked?.add(floors);
        return floor;
      },
    );

    test('no GPS: says why', () async {
      final s = _Setup();
      final outcome = await plan(s, _anchors[1]);
      expect(outcome, isA<TripNoGps>());
      expect((outcome as TripNoGps).error, LocationError.serviceDisabled);
    });

    test('checks the start, then finds the route', () async {
      final s = at(6.2009);
      final located = <String>[];
      final outcome = await plan(s, _anchors.first, located: located);
      expect(outcome, isA<TripFound>());
      expect((outcome as TripFound).route, {'id': 'r1'});
      expect(located, ['check']);
      expect(s.route.posts.single, {
        'start_anchor_id': 'a2',
        'end_anchor_id': 'a1',
      });

      // A second try right after reuses the check.
      await plan(s, _anchors.first, located: located);
      expect(located, ['check']);
    });

    test('several floors near: asks, and starts on the one said', () async {
      final s = at(6.2000);
      final asked = <List<int>>[];
      final outcome = await plan(s, _anchors[1], floor: 1, asked: asked);
      expect(asked, [
        [0, 1],
      ]);
      expect(outcome, isA<TripFound>());
      expect(s.route.posts.single['start_anchor_id'], 'a3');
    });

    test('backing out of the floor question cancels', () async {
      final s = at(6.2000);
      expect(await plan(s, _anchors[1]), isA<TripCancelled>());
      expect(s.route.posts, isEmpty);
    });

    test('already at the destination', () async {
      final s = at(6.2009);
      expect(await plan(s, _anchors[1]), isA<TripAlreadyThere>());
    });

    test('no walkable path: which end, from the server', () async {
      final s = at(6.2009)..route.answer = null;
      final outcome = await plan(s, _anchors.first);
      expect(outcome, isA<TripNoPath>());
      expect((outcome as TripNoPath).end, NoPathEnd.unknown);
    });
  });

  group('tripOutcomeMessage', () {
    final l10n = lookupAppLocalizations(const Locale('es'));
    String? say(TripOutcome outcome) => tripOutcomeMessage(
      l10n,
      outcome,
      destination: const {'id': 'a1', 'location_description': 'Biblioteca'},
      apiError: (_) => 'sin conexión',
    );

    test('nothing to say for a found route or a cancel', () {
      expect(say(const TripFound({})), isNull);
      expect(say(const TripCancelled()), isNull);
    });

    test('why there is no GPS', () {
      expect(
        say(const TripNoGps(LocationError.serviceDisabled)),
        l10n.locationServiceDisabledError,
      );
      expect(
        say(const TripNoGps(LocationError.permissionDenied)),
        l10n.locationPermissionDeniedError,
      );
      expect(say(const TripNoGps(null)), l10n.homeErrorNoGpsFix);
    });

    test('the rest', () {
      expect(say(const TripNoStart()), l10n.homeErrorNoVerifiedAnchors);
      expect(
        say(const TripAlreadyThere()),
        l10n.homeErrorAlreadyAtDestination('Biblioteca'),
      );
      expect(say(const TripNoPath(NoPathEnd.start)), l10n.homeErrorNoPathStart);
      expect(
        say(const TripNoPath(NoPathEnd.destination)),
        l10n.homeErrorNoPathDestination,
      );
      expect(say(const TripNoPath(NoPathEnd.unknown)), l10n.homeErrorNoPath);
      expect(
        say(TripFailed(ApiException(503, ''))),
        l10n.homeErrorFailedToFindRoute('sin conexión'),
      );
    });
  });
}
