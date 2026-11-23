import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/services/heading_tracker.dart';
import 'package:eyes4u/services/trip_plan.dart';
import 'package:eyes4u/services/turn_guidance.dart';
import 'package:eyes4u/user/leg_progress.dart';
import 'package:eyes4u/user/route_progress.dart';
import 'package:eyes4u/user/trip_guide.dart';
import 'package:eyes4u/user/trip_log.dart';
import 'package:eyes4u/voice/app_voice.dart';
import 'package:eyes4u/voice/trip_announcer.dart';
import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../support/api_fakes.dart';

/// A point [n] meters north and [e] meters east of the route's start.
LatLng _at(double n, [double e = 0]) =>
    LatLng(6.2 + n / 111195, -75.58 + e / 110545);

/// Guidance for an L, with no heading at all (a phone without compass or
/// gyroscope): 40 m north to a corner, then 40 m east to the library.
class _Trip {
  _Trip({bool adminPreview = false}) {
    voice = AppVoice(
      speak: (text) async {
        said.add(text);
        voice.onStarted();
        Future.delayed(const Duration(milliseconds: 500), voice.onEnded);
      },
      stop: () async {},
      configure: (_) async => true,
    );
    final announcer = TripAnnouncer(
      owner: voice.claim(),
      logCue: log.cue,
      buzzer: (_) async {},
      voiceOn: ValueNotifier(true),
    );
    route.load(
      TripPlan(
        points: [_at(0), _at(40), _at(40, 40)],
        floors: const [0, 0, 0],
        waypoints: [
          Waypoint(point: _at(40)),
          Waypoint(point: _at(40, 40), name: 'Biblioteca'),
        ],
        cornerCount: 1,
        startPoint: _at(0),
        startFloor: 0,
      ),
    );
    guide = TripGuide(
      route: route,
      leg: LegProgress(),
      tracker: HeadingTracker(),
      compass: HeadingSmoother(),
      announcer: announcer,
      log: log,
      l10n: () => lookupAppLocalizations(const Locale('es')),
      position: () => here,
      raw: () => here,
      lastFix: () => _fix(here),
      barometerSeen: () => false,
      startTypeId: () => null,
      pathLoaded: () => true,
      destinationName: () => 'Biblioteca',
      onArrived: () => arrivals++,
      onChanged: () {},
      restartGps: () {},
      adminPreview: adminPreview,
    );
    route.needsStartCue = true;
    guide.start();
  }

  late final AppVoice voice;
  final route = RouteProgress();
  final log = TripLog(FakeNavigationApi());
  late final TripGuide guide;
  final said = <String>[];
  LatLng here = _at(0);
  int arrivals = 0;

  /// Walks to [to] in steps of about a metre a second, guiding every half
  /// second, the way the screen's timers do.
  void walk(FakeAsync async, LatLng to, {int seconds = 1}) {
    final from = here;
    for (var i = 1; i <= seconds * 2; i++) {
      final t = i / (seconds * 2);
      here = LatLng(
        from.latitude + (to.latitude - from.latitude) * t,
        from.longitude + (to.longitude - from.longitude) * t,
      );
      guide.step();
      async.elapse(const Duration(milliseconds: 500));
    }
  }

  void stand(FakeAsync async, int seconds) =>
      walk(async, here, seconds: seconds);
}

Position _fix(LatLng p) => Position(
  latitude: p.latitude,
  longitude: p.longitude,
  timestamp: clock.now(),
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

void main() {
  setUpAll(() => dotenv.testLoad(fileInput: ''));

  test('a whole trip: start, the corner, arrival', () {
    fakeAsync((async) {
      final trip = _Trip();
      trip.stand(async, 1);
      expect(trip.said.first, startsWith('Camina hacia adelante unos'));
      trip.walk(async, _at(39), seconds: 30);
      expect(
        trip.said.where((s) => s.contains('derecha')),
        isNotEmpty,
        reason: 'the corner turns right',
      );
      trip.walk(async, _at(40, 39), seconds: 30);
      expect(trip.said.last, 'Llegaste a Biblioteca. Navegación terminada.');
      expect(trip.arrivals, 1);
      expect(trip.guide.arrived, isTrue);
      final said = trip.said.length;
      trip.stand(async, 5);
      expect(trip.said.length, said, reason: 'nothing after arriving');
    });
  });

  test("an admin's test walk arrives without ending", () {
    fakeAsync((async) {
      final trip = _Trip(adminPreview: true);
      trip.walk(async, _at(39), seconds: 30);
      trip.walk(async, _at(40, 39), seconds: 30);
      expect(trip.said.last, 'Has llegado a Biblioteca.');
      expect(trip.arrivals, 0);
    });
  });

  test('drifting sideways says which side (B4)', () {
    fakeAsync((async) {
      final trip = _Trip();
      trip.stand(async, 1);
      // 10 m to the left of the line north, half way along.
      trip.walk(async, _at(15, -10), seconds: 15);
      trip.stand(async, 8);
      expect(
        trip.said,
        contains('Te estás desviando a la izquierda, ve un poco a la derecha.'),
      );
      final drifts = trip.said.where((s) => s.contains('desviando')).length;
      trip.stand(async, 20);
      expect(
        trip.said.where((s) => s.contains('desviando')).length,
        drifts,
        reason: 'not again within the cooldown',
      );
    });
  });

  test('a wobble within GPS noise says nothing about drifting', () {
    fakeAsync((async) {
      final trip = _Trip();
      trip.stand(async, 1);
      for (var n = 8.0; n < 32; n += 4) {
        trip.walk(async, _at(n, n % 8 == 0 ? 4 : -4), seconds: 4);
      }
      expect(trip.said.where((s) => s.contains('desviando')), isEmpty);
    });
  });

  test('on the line, the periodic update says "vas bien" (B4)', () {
    fakeAsync((async) {
      final trip = _Trip();
      trip.stand(async, 1);
      trip.walk(async, _at(15), seconds: 15);
      async.elapse(const Duration(seconds: 15));
      trip.guide.periodic();
      async.elapse(const Duration(seconds: 1));
      expect(trip.said.last, startsWith('Vas bien, faltan unos'));
    });
  });

  test('off the line, the periodic update is the plain one', () {
    fakeAsync((async) {
      final trip = _Trip();
      trip.stand(async, 1);
      trip.walk(async, _at(15, 7), seconds: 15);
      async.elapse(const Duration(seconds: 15));
      trip.guide.periodic();
      async.elapse(const Duration(seconds: 1));
      expect(trip.said.last, startsWith('Sigue recto, faltan unos'));
    });
  });

  test('nothing while not guiding', () {
    fakeAsync((async) {
      final trip = _Trip();
      trip.guide.guiding = false;
      trip.stand(async, 3);
      trip.guide.periodic();
      expect(trip.said, isEmpty);
    });
  });
}
