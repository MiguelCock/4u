import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/services/app_preferences.dart';
import 'package:eyes4u/services/location_service.dart';
import 'package:eyes4u/services/route_points.dart';
import 'package:eyes4u/user/navigation_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/api_fakes.dart';
import '../support/sensor_fakes.dart';
import '../support/voice_fakes.dart';

/// Pins how the trip screen behaves today, before it's split up (Phase C):
/// starting, a walk to arrival, ending early, resuming, and no account.
/// Everything is a fake: no server, no plugin, no camera.

// An L: 33 m north to a corner, then 33 m east to the library.
const _entrance = {
  'id': 'a1',
  'building_id': 'b1',
  'location_type_id': 1,
  'location_description': 'Entrada',
  'floor': 0,
  'latitude': 6.2000,
  'longitude': -75.5800,
};
const _corner = {
  'id': 'a2',
  'building_id': 'b1',
  'location_type_id': 2,
  'location_description': '',
  'floor': 0,
  'latitude': 6.2003,
  'longitude': -75.5800,
};
const _library = {
  'id': 'a3',
  'building_id': 'b1',
  'location_type_id': 23,
  'location_description': 'Biblioteca',
  'floor': 0,
  'latitude': 6.2003,
  'longitude': -75.5797,
};
const _route = {
  'id': 'r1',
  'building_id': 'b1',
  'start_anchor_id': 'a1',
  'waypoint_anchor_ids': ['a2'],
  'end_anchor_id': 'a3',
};

// Up a floor: 33 m north to the elevator, up it, then 33 m east upstairs.
const _liftDown = {
  'id': 'f2',
  'building_id': 'b1',
  'location_type_id': 3,
  'location_description': '',
  'floor': 0,
  'latitude': 6.2003,
  'longitude': -75.5800,
};
final _liftUp = {..._liftDown}
  ..['id'] = 'f3'
  ..['floor'] = 1;
final _libraryUp = {..._library}
  ..['id'] = 'f4'
  ..['floor'] = 1;
const _floorRoute = {
  'id': 'r2',
  'building_id': 'b1',
  'start_anchor_id': 'a1',
  'waypoint_anchor_ids': ['f2', 'f3'],
  'end_anchor_id': 'f4',
};

List<Map<String, dynamic>> _chain(List<String> ids) => [
  for (var i = 0; i + 1 < ids.length; i++)
    {'id': 'c$i', 'anchor_point_a_id': ids[i], 'anchor_point_b_id': ids[i + 1]},
];

class _Trip {
  _Trip({
    this.signedIn = true,
    this.resumeSessionId,
    this.route = _route,
    List<Map<String, dynamic>> anchors = const [_entrance, _corner, _library],
    this.hPa,
  }) : map = FakeMapApi(
         anchors: anchors,
         connections: _chain(routeAnchorIds(route)),
       );

  final bool signedIn;
  final String? resumeSessionId;
  final Map<String, dynamic> route;

  /// The barometer's reading, sent every 100 ms; null: no barometer.
  double? hPa;
  final navigation = FakeNavigationApi();
  final FakeMapApi map;
  final gps = FixedLocation(fix(6.2000, -75.5800));
  late final location = LocationService.forTesting(gps);
  final sensors = FakeTripSensors();
  final voice = FakeVoice();
  late AppLocalizations l10n;

  Iterable<String> get posted => navigation.posts.map((p) => p.$1);

  Future<void> start(WidgetTester tester) async {
    await location.initialize();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            l10n = AppLocalizations.of(context)!;
            return TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => NavigationScreen(
                    route: route,
                    destinationName: 'Biblioteca',
                    resumeSessionId: resumeSessionId,
                    navigationApi: navigation,
                    positioningApi: FakePositioningApi(),
                    mapApi: map,
                    locationService: location,
                    voice: voice.voice,
                    sensors: sensors,
                    userId: () => signedIn ? 'u1' : null,
                  ),
                ),
              ),
              child: const Text('go'),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await run(tester);
  }

  /// Lets the trip run: timers, ticks, speech.
  Future<void> run(WidgetTester tester, {int seconds = 3}) async {
    for (var i = 0; i < seconds * 10; i++) {
      if (hPa case final p?) sensors.pressureIs(p);
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Walks to [lat]/[lng], facing [heading], in steps a second apart.
  Future<void> walkTo(
    WidgetTester tester,
    double lat,
    double lng, {
    required double heading,
    int steps = 6,
  }) async {
    final from = gps.here;
    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      gps.moveTo(
        fix(
          from.latitude + (lat - from.latitude) * t,
          from.longitude + (lng - from.longitude) * t,
        ),
      );
      sensors.face(heading);
      await run(tester, seconds: 1);
    }
  }

  /// Every guidance event logged so far, by type.
  List<Map<dynamic, dynamic>> events(String type) => [
    for (final (path, body) in navigation.posts)
      if (path == '/logs')
        for (final e in (body['debug']?['events'] as List? ?? const []))
          if ((e as Map)['type'] == type) e,
  ];

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }
}

void main() {
  setUpAll(() => dotenv.testLoad(fileInput: ''));

  setUp(() {
    voiceGuidanceNotifier.value = true;
    showMapNotifier.value = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('vibration'),
      (_) async => false,
    );
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
  });

  testWidgets('starting: a session, the destination, the camera notice', (
    tester,
  ) async {
    final t = _Trip();
    await t.start(tester);

    final session = t.navigation.posts.firstWhere((p) => p.$1 == '/sessions');
    expect(session.$2['user_id'], 'u1');
    expect(session.$2['route_id'], 'r1');
    expect(session.$2['start_position'], {
      'latitude': 6.2,
      'longitude': -75.58,
    });
    expect(t.voice.said, contains(t.l10n.navStartingTo('Biblioteca')));
    expect(t.voice.said, contains(t.l10n.navAnnouncementCameraDisclosure));
    expect(t.sensors.awake, [true]);
    await t.close(tester);
  });

  testWidgets('no account: says so, and starts nothing', (tester) async {
    final t = _Trip(signedIn: false);
    await t.start(tester);
    expect(find.text(t.l10n.commonNotSignedIn), findsOneWidget);
    expect(t.posted, isNot(contains('/sessions')));
    await t.close(tester);
  });

  testWidgets('resuming: no new session, and it says it\'s resuming', (
    tester,
  ) async {
    final t = _Trip(resumeSessionId: 's9');
    await t.start(tester);
    expect(t.posted, isNot(contains('/sessions')));
    expect(t.voice.said, contains(t.l10n.navResumingTo('Biblioteca')));
    await t.close(tester);
  });

  testWidgets('ending early: the session is closed, then feedback', (
    tester,
  ) async {
    final t = _Trip();
    await t.start(tester);

    // The camera notice's SnackBar covers the button for its 4 s.
    await t.run(tester, seconds: 5);
    await tester.tap(find.text(t.l10n.navEndButton));
    await t.run(tester);
    expect(t.navigation.patches['/sessions/s1']?['status'], 'completed');
    expect(find.text(t.l10n.navFeedbackSkip), findsOneWidget);

    await tester.tap(find.text(t.l10n.navFeedbackSkip));
    await t.run(tester);
    expect(find.text('go'), findsOneWidget); // back home
    expect(t.sensors.awake, [true, false]);
    await t.close(tester);
  });

  testWidgets('walking the route: arrival ends the trip by itself', (
    tester,
  ) async {
    final t = _Trip();
    await t.start(tester);
    t.sensors.face(0);
    await t.run(tester, seconds: 4);

    await t.walkTo(tester, 6.2003, -75.5800, heading: 0);
    await t.walkTo(tester, 6.2003, -75.5797, heading: 90);
    await t.run(tester, seconds: 4);

    // Everything said, in order: today's guidance for this L.
    expect(t.voice.said, [
      t.l10n.navStartingTo('Biblioteca'),
      t.l10n.navAnnouncementCameraDisclosure,
      'Camina hacia adelante unos 50 pasos. Te avisaré si vas en otra '
          'dirección.',
      'En unos 8 pasos, gira a la derecha.',
      'Gira a la derecha y camina unos 45 pasos.',
      t.l10n.navArrivedFinished('Biblioteca'),
      '¿Cómo te fue?',
    ]);
    expect(t.navigation.patches['/sessions/s1']?['status'], 'completed');
    expect(t.posted, contains('/logs'));
    await t.close(tester);
  });

  testWidgets('no new GPS fix for 25 s: said once, and a gps_stale event', (
    tester,
  ) async {
    final t = _Trip();
    await t.start(tester);
    t.sensors.face(0);
    await t.run(tester, seconds: 30); // standing still: no new fixes

    final searching = t.l10n.homeSearchingLocation;
    expect(t.voice.said.where((s) => s == searching), hasLength(1));
    final events = [
      for (final (path, body) in t.navigation.posts)
        if (path == '/logs')
          for (final e in (body['debug']?['events'] as List? ?? const []))
            (e as Map)['type'],
    ];
    expect(events, contains('gps_stale'));
    await t.close(tester);
  });

  testWidgets('a comment after the trip is sent with the session', (
    tester,
  ) async {
    final t = _Trip();
    await t.start(tester);
    await t.run(tester, seconds: 5); // the camera notice goes
    await tester.tap(find.text(t.l10n.navEndButton));
    await t.run(tester);

    await tester.enterText(find.byType(TextField), 'Muy bien');
    await tester.tap(find.text(t.l10n.navFeedbackSubmit));
    await t.run(tester);
    final feedback = t.navigation.posts.lastWhere((p) => p.$1 == '/feedback');
    expect(feedback.$2, {
      'user_id': 'u1',
      'session_id': 's1',
      'comment': 'Muy bien',
    });
    expect(find.text('go'), findsOneWidget);
    await t.close(tester);
  });

  testWidgets('up a floor: the elevator, the barometer hears it, then on', (
    tester,
  ) async {
    final t = _Trip(
      route: _floorRoute,
      anchors: [_entrance, _liftDown, _liftUp, _libraryUp],
      hPa: 1000,
    );
    await t.start(tester);
    t.sensors.face(0);
    await t.run(tester, seconds: 4);
    await t.walkTo(tester, 6.2003, -75.5800, heading: 0);
    await t.run(tester, seconds: 6);
    t.hPa = 999.6; // a floor up
    await t.run(tester, seconds: 8);
    await t.walkTo(tester, 6.2003, -75.5797, heading: 90);
    await t.run(tester, seconds: 4);

    expect(t.voice.said, [
      t.l10n.navStartingTo('Biblioteca'),
      t.l10n.navAnnouncementCameraDisclosure,
      'Camina hacia adelante unos 50 pasos. Te avisaré si vas en otra '
          'dirección.',
      'Atención: ascensor en unos 8 pasos.',
      'Toma el ascensor hasta el piso 2. Te avisaré cuando llegues.',
      t.l10n.navFloorReached(2),
      'Gira a la derecha y camina unos 45 pasos.',
      t.l10n.navArrivedFinished('Biblioteca'),
      '¿Cómo te fue?',
    ]);
    expect(t.events('floor_wait'), hasLength(1));
    expect(t.events('floor_detected'), hasLength(1));
    expect(t.navigation.patches['/sessions/s1']?['status'], 'completed');
    await t.close(tester);
  });

  testWidgets('up a floor with no barometer: carries on after 60 s', (
    tester,
  ) async {
    final t = _Trip(
      route: _floorRoute,
      anchors: [_entrance, _liftDown, _liftUp, _libraryUp],
    );
    await t.start(tester);
    t.sensors.face(0);
    await t.run(tester, seconds: 4);
    await t.walkTo(tester, 6.2003, -75.5800, heading: 0);
    await t.run(tester, seconds: 62);

    expect(t.voice.said, [
      t.l10n.navStartingTo('Biblioteca'),
      t.l10n.navAnnouncementCameraDisclosure,
      'Camina hacia adelante unos 50 pasos. Te avisaré si vas en otra '
          'dirección.',
      'Atención: ascensor en unos 8 pasos.',
      'Toma el ascensor hasta el piso 2. ${t.l10n.navFloorNoSensor}',
      t.l10n.navFloorTimeout(2),
      t.l10n.homeSearchingLocation, // standing still all along
      'Gira a la derecha y camina unos 45 pasos.',
    ]);
    expect(t.events('floor_timeout'), hasLength(1));
    await t.close(tester);
  });

  testWidgets('a fix past the corner, at the library: arrives, skipping it', (
    tester,
  ) async {
    final t = _Trip();
    await t.start(tester);
    t.sensors.face(0);
    await t.run(tester, seconds: 4);
    t.gps.moveTo(fix(6.2003, -75.5797));
    await t.run(tester, seconds: 4);

    expect(t.voice.said, [
      t.l10n.navStartingTo('Biblioteca'),
      t.l10n.navAnnouncementCameraDisclosure,
      'Camina hacia adelante unos 50 pasos. Te avisaré si vas en otra '
          'dirección.',
      t.l10n.navArrivedFinished('Biblioteca'),
      '¿Cómo te fue?',
    ]);
    expect(t.events('arrival').single['skipped'], 1);
    await t.close(tester);
  });

  testWidgets('walking away from the path: said, after the periodic wait', (
    tester,
  ) async {
    final t = _Trip();
    await t.start(tester);
    t.sensors.face(0);
    await t.run(tester, seconds: 4);
    // Some progress (so it isn't a stall), then back past the start.
    await t.walkTo(tester, 6.20010, -75.5800, heading: 0, steps: 5);
    await t.walkTo(tester, 6.19995, -75.5800, heading: 180, steps: 8);
    await t.run(tester, seconds: 10);

    expect(t.voice.said, [
      t.l10n.navStartingTo('Biblioteca'),
      t.l10n.navAnnouncementCameraDisclosure,
      'Camina hacia adelante unos 50 pasos. Te avisaré si vas en otra '
          'dirección.',
      t.l10n.navMovingAway,
    ]);
    await t.close(tester);
  });
}
