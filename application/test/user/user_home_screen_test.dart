import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/services/app_preferences.dart';
import 'package:eyes4u/services/location_service.dart';
import 'package:eyes4u/user/user_home_screen.dart';
import 'package:eyes4u/voice/app_voice.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/api_fakes.dart';
import '../support/voice_fakes.dart';

/// Pins how the home screen behaves today (#268), before it's split up:
/// asking, listening, a place heard, misses, and the tutorial. Every
/// dependency is a fake, so nothing reaches a server or a plugin.

const List<Map<String, dynamic>> _places = [
  {'id': 'p1', 'name': 'Campus', 'is_active': true},
];
const List<Map<String, dynamic>> _buildings = [
  {
    'id': 'b1',
    'place_id': 'p1',
    'name': 'Edificio C',
    'is_active': true,
    'latitude': 6.2,
    'longitude': -75.58,
  },
];
const List<Map<String, dynamic>> _anchors = [
  {
    'id': 'a1',
    'building_id': 'b1',
    'location_type_id': 23, // library
    'location_description': 'Biblioteca',
    'status': 'verified',
    'floor': 0,
    'latitude': 6.2001,
    'longitude': -75.5801,
  },
  {
    'id': 'a2',
    'building_id': 'b1',
    'location_type_id': 2, // hallway: never a destination
    'location_description': '',
    'status': 'verified',
    'floor': 0,
    'latitude': 6.2002,
    'longitude': -75.5802,
  },
];
const List<Map<String, dynamic>> _connections = [
  {'id': 'c1', 'anchor_point_a_id': 'a1', 'anchor_point_b_id': 'a2'},
];

class _Harness {
  final speech = FakeSpeech();
  final voice = FakeVoice();

  late AppLocalizations l10n;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        navigatorObservers: [voiceRouteObserver],
        home: UserHomeScreen(
          mapApi: FakeMapApi(
            places: _places,
            buildings: _buildings,
            anchors: _anchors,
            connections: _connections,
          ),
          routeApi: FakeRouteApi(),
          positioningApi: FakePositioningApi(),
          navigationApi: FakeNavigationApi(),
          locationService: LocationService.forTesting(NoLocation()),
          speech: speech,
          voice: voice.voice,
        ),
      ),
    );
    l10n = AppLocalizations.of(tester.element(find.byType(UserHomeScreen)))!;
  }

  /// Lets the screen speak and open the microphone (each sentence and
  /// pause is a timer).
  Future<void> run(WidgetTester tester, {int seconds = 3}) async {
    for (var i = 0; i < seconds * 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Unmounts the screen and lets its leftover timers run out.
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }
}

void main() {
  setUpAll(() => dotenv.testLoad(fileInput: ''));

  setUp(() {
    // No vibrator: buzz() falls back to HapticFeedback.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('vibration'),
          (_) async => false,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    showChoicesNotifier.value = false;
    SharedPreferences.setMockInitialValues({'tutorial_seen_v3': true});
  });

  testWidgets('asks where to go, then listens', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await h.run(tester);

    expect(h.voice.said, [h.l10n.homeAskDestination, h.l10n.homeListenExample]);
    expect(h.speech.listens, 1);
    expect(h.speech.isListening, isTrue);
    await h.close(tester);
  });

  testWidgets('a place heard asks "¿Ir a X?", says "di sí" and listens', (
    tester,
  ) async {
    final h = _Harness();
    await h.pump(tester);
    await h.run(tester);

    h.speech.hear('quiero ir a la biblioteca');
    await h.run(tester);

    expect(
      find.text(h.l10n.homeGoToTitle('Biblioteca · Edificio C')),
      findsOneWidget,
    );
    expect(
      h.voice.said.last,
      '${h.l10n.homeGoToTitle('Biblioteca, Edificio C')} '
      '${h.l10n.homeSayYesToStart}',
    );
    expect(h.speech.listens, 2);
    expect(h.speech.isListening, isTrue);

    // "No" with the rows hidden closes it and asks again.
    h.speech.hear('no');
    await h.run(tester);
    expect(
      find.text(h.l10n.homeGoToTitle('Biblioteca · Edificio C')),
      findsNothing,
    );
    expect(h.voice.said.last, h.l10n.homeListenExample);
    expect(h.speech.listens, 3);
    await h.close(tester);
  });

  testWidgets('silence is retried twice, then it gives up', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await h.run(tester);

    for (var retry = 1; retry <= 2; retry++) {
      h.speech.hear('');
      await h.run(tester);
      expect(h.speech.listens, 1 + retry);
      expect(h.voice.said.sublist(h.voice.said.length - 2), [
        h.l10n.homeVoiceNothingHeard,
        h.l10n.homeListenPrompt,
      ]);
    }

    h.speech.hear('');
    await h.run(tester);
    expect(
      h.voice.said.last,
      '${h.l10n.homeVoiceNothingHeard} ${h.l10n.homeVoiceGiveUp}',
    );
    expect(h.speech.listens, 3);
    expect(h.speech.isListening, isFalse);
    await h.close(tester);
  });

  testWidgets('a place it doesn\'t know is said back and retried', (
    tester,
  ) async {
    final h = _Harness();
    await h.pump(tester);
    await h.run(tester);

    h.speech.hear('el acuario');
    await h.run(tester);
    expect(h.voice.said, contains(h.l10n.homeVoiceNoMatch('el acuario')));
    expect(h.speech.listens, 2);
    await h.close(tester);
  });

  testWidgets('no recognizer: says so and shows the choices', (tester) async {
    final h = _Harness()..speech.available = false;
    await h.pump(tester);
    await h.run(tester);

    expect(h.voice.said.last, h.l10n.homeVoiceUnavailable);
    expect(h.speech.listens, 0);
    expect(find.text(h.l10n.homeChooseDestination), findsOneWidget);
    await h.close(tester);
  });

  testWidgets('first launch: the tutorial, page by page, then the question', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final h = _Harness();
    await h.pump(tester);
    await h.run(tester, seconds: 1);

    final pages = [
      h.l10n.homeTutorialPage1,
      h.l10n.homeTutorialPage2,
      h.l10n.homeTutorialPage3,
    ];
    for (final (i, page) in pages.indexed) {
      expect(find.text(page), findsOneWidget);
      expect(h.voice.said.last, page);
      // Nothing listens while the tutorial is open.
      expect(h.speech.listens, 0);
      await tester.tap(
        find.text(
          i == pages.length - 1
              ? h.l10n.homeTutorialDone
              : h.l10n.homeTutorialNext,
        ),
      );
      await h.run(tester, seconds: 1);
    }

    await h.run(tester);
    expect(h.voice.said.sublist(h.voice.said.length - 2), [
      h.l10n.homeAskDestination,
      h.l10n.homeListenExample,
    ]);
    expect(h.speech.listens, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('tutorial_seen_v3'), isTrue);
    await h.close(tester);
  });
}
