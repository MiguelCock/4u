import 'package:clock/clock.dart';
import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/services/location_service.dart';
import 'package:eyes4u/user/home_tutorial.dart';
import 'package:eyes4u/user/unfinished_trip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/api_fakes.dart';

/// A trip left open last time, and the first-run tutorial (#268).

Map<String, dynamic> _session(String id, {String? route}) => {
  'id': id,
  'route_id': route,
  'start_time': '2026-11-15T14:30:00Z',
};

class _Setup {
  _Setup({
    List<Map<String, dynamic>> sessions = const [],
    bool routeExists = true,
  }) : navigation = FakeNavigationApi(sessions: sessions),
       route = FakeRouteApi(
         routes: routeExists
             ? {
                 'r1': {'id': 'r1', 'end_anchor_id': 'a9'},
               }
             : {},
       );

  final FakeNavigationApi navigation;
  final FakeRouteApi route;
  final location = LocationService.forTesting(NoLocation());
  late final trips = UnfinishedTrips(
    navigationApi: navigation,
    routeApi: route,
    locationService: location,
  );
}

void main() {
  setUpAll(() => dotenv.testLoad(fileInput: ''));

  group('UnfinishedTrips.find', () {
    test('none open: nothing', () async {
      expect(await _Setup().trips.find(), isNull);
    });

    test('the newest is offered, and older ones are closed', () async {
      final s = _Setup(
        sessions: [
          _session('s2', route: 'r1'),
          _session('s1', route: 'r1'),
        ],
      );
      final trip = await s.trips.find();
      expect(trip?.session['id'], 's2');
      expect(trip?.route['id'], 'r1');
      await Future<void>.delayed(Duration.zero);
      expect(s.navigation.patches.keys, ['/sessions/s1']);
      expect(s.navigation.patches['/sessions/s1']!['status'], 'abandoned');
    });

    test('a trip whose route is gone is closed, not offered', () async {
      final s = _Setup(
        sessions: [_session('s1', route: 'r1')],
        routeExists: false,
      );
      expect(await s.trips.find(), isNull);
      expect(s.navigation.patches.keys, ['/sessions/s1']);
    });

    test('a trip with no route at all is closed too', () async {
      final s = _Setup(sessions: [_session('s1')]);
      expect(await s.trips.find(), isNull);
      expect(s.navigation.patches.keys, ['/sessions/s1']);
    });
  });

  test('abandon: when and where it ended', () async {
    final s = _Setup()..location.lastPosition = fix(6.2, -75.58);
    await withClock(
      Clock.fixed(DateTime.utc(2026, 11, 15, 15)),
      () => s.trips.abandon(_session('s1')),
    );
    expect(s.navigation.patches['/sessions/s1'], {
      'status': 'abandoned',
      'end_time': '2026-11-15T15:00:00.000Z',
      'end_position': {'latitude': 6.2, 'longitude': -75.58},
    });
  });

  testWidgets('askResumeTrip names the destination and answers', (
    tester,
  ) async {
    bool? answer;
    late AppLocalizations l10n;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            l10n = AppLocalizations.of(context)!;
            return TextButton(
              onPressed: () async => answer = await askResumeTrip(
                context,
                trip: (
                  session: _session('s1', route: 'r1'),
                  route: const {'id': 'r1'},
                ),
                destination: 'Biblioteca',
              ),
              child: const Text('ask'),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Biblioteca'), findsOneWidget);

    await tester.tap(find.text(l10n.homeUnfinishedTripResume));
    await tester.pumpAndSettle();
    expect(answer, isTrue);

    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.homeUnfinishedTripFinish));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
  });

  test('the tutorial is due once per install', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await firstRunTutorialDue(), isTrue);
    expect(await firstRunTutorialDue(), isFalse);
    SharedPreferences.setMockInitialValues({kTutorialSeenKey: true});
    expect(await firstRunTutorialDue(), isFalse);
  });
}
