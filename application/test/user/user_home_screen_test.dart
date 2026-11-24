import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/services/app_preferences.dart';
import 'package:eyes4u/services/location_service.dart';
import 'package:eyes4u/user/user_home_screen.dart';
import 'package:eyes4u/voice/app_voice.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:eyes4u/voice/voice_attempts.dart';
import 'package:eyes4u/voice/home_voice_controller.dart';
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

/// Five places to go to, for "¿qué lugares hay?" (D9).
final List<Map<String, dynamic>> _fivePlaces = [
  for (final (i, (name, type)) in [
    ('Biblioteca', 23),
    ('Cafetería', 8),
    ('Baño', 7),
    ('Enfermería', 27),
    ('Auditorio', 15),
  ].indexed)
    {
      'id': 'd$i',
      'building_id': 'b1',
      'location_type_id': type,
      'location_description': name,
      'status': 'verified',
      'floor': 0,
      'latitude': 6.2001 + i / 10000,
      'longitude': -75.5801,
    },
  _anchors[1],
];

final List<Map<String, dynamic>> _fiveConnections = [
  for (var i = 0; i < 5; i++)
    {'id': 'c$i', 'anchor_point_a_id': 'd$i', 'anchor_point_b_id': 'a2'},
];

class _Harness {
  _Harness({this.anchors = _anchors, this.connections = _connections});

  final List<Map<String, dynamic>> anchors;
  final List<Map<String, dynamic>> connections;
  final speech = FakeSpeech();
  final voice = FakeVoice();
  final users = FakeUserApi(
    profiles: [
      {
        'id': 'u1',
        'preferences': {'verbosity': 'high', 'language': 'es'},
      },
    ],
  );

  /// The preferences saved by voice, merged (#226).
  Map<String, dynamic>? get saved => users.writes.isEmpty
      ? null
      : (users.writes.last.$3!['preferences'] as Map).cast<String, dynamic>();

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
            anchors: anchors,
            connections: connections,
          ),
          routeApi: FakeRouteApi(),
          positioningApi: FakePositioningApi(),
          navigationApi: FakeNavigationApi(),
          locationService: LocationService.forTesting(NoLocation()),
          speech: speech,
          voice: voice.voice,
          userApi: users,
          userId: () => 'u1',
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

  testWidgets('noise on top, the place second: the place is used, and the '
      'attempt kept for the next trip (#262)', (tester) async {
    VoiceAttempts.instance.drain();
    final h = _Harness();
    await h.pump(tester);
    await h.run(tester);

    h.speech.hearAlternates([
      ('vamos ya pedro', 0.8),
      ('la biblioteca', 0.55),
    ], soundPeak: 9);
    await h.run(tester);

    expect(
      find.text(h.l10n.homeGoToTitle('Biblioteca · Edificio C')),
      findsOneWidget,
    );
    final attempts = VoiceAttempts.instance.drain();
    expect(attempts, hasLength(1));
    expect(attempts.single['outcome'], 'one');
    expect(attempts.single['used'], 'la biblioteca');
    expect(attempts.single['sound_peak'], 9);
    expect(attempts.single['alternates'], hasLength(2));
  });

  group('by voice alone (#226)', () {
    setUp(() {
      showChoicesNotifier.value = false;
      speechRateNotifier.value = kDefaultSpeechRate;
    });

    testWidgets('five misses offer manual search; "sí" turns it on and saves '
        'it with the rest', (tester) async {
      final h = _Harness();
      await h.pump(tester);
      await h.run(tester);
      for (var i = 0; i < 5; i++) {
        h.speech.hear('');
        await h.run(tester);
      }
      expect(h.voice.said.last, h.l10n.homeOfferManualSearch);
      h.speech.hear('sí');
      await h.run(tester);
      expect(h.voice.said.last, h.l10n.homeManualSearchOn);
      expect(h.saved, {
        'verbosity': 'high',
        'language': 'es',
        'show_choices': true,
      });
      expect(showChoicesNotifier.value, isTrue);
    });

    for (final talkBack in [false, true]) {
      testWidgets('"ajustes" reads one option at a time and changes it '
          '(TalkBack ${talkBack ? 'on' : 'off'})', (tester) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue = talkBack
            ? const FakeAccessibilityFeatures(accessibleNavigation: true)
            : const FakeAccessibilityFeatures();
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        final h = _Harness();
        await h.pump(tester);
        await h.run(tester, seconds: talkBack ? 5 : 3);
        h.speech.hear('ajustes');
        await h.run(tester);
        expect(
          h.voice.said.last,
          h.l10n.voiceSettingsSpeedPrompt(h.l10n.voiceSpeedNormal),
        );
        h.speech.hear('más rápida');
        await h.run(tester);
        expect(speechRateNotifier.value, kSpeechRates['fast']);
        expect(h.saved?['speech_rate'], kSpeechRates['fast']);
        // Next option: manual search, off.
        expect(
          h.voice.said.last,
          h.l10n.voiceSettingsTogglePrompt(
            h.l10n.voiceSettingManualSearch,
            h.l10n.voiceSettingOff,
          ),
        );
        h.speech.hear('salir');
        await h.run(tester);
        expect(h.voice.said, contains(h.l10n.voiceSettingsClosed));
        expect(
          h.speech.isListening,
          isTrue,
          reason: 'back to asking for a place',
        );
      });
    }
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

  testWidgets('"¿qué lugares hay?" reads three, "más" the next (D9)', (
    tester,
  ) async {
    final h = _Harness(anchors: _fivePlaces, connections: _fiveConnections);
    await h.pump(tester);
    await h.run(tester);

    h.speech.hear('no sé, ¿qué lugares hay?');
    await h.run(tester);
    expect(
      h.voice.said.last,
      h.l10n.homeSuggestPlaces(
        '1, Biblioteca, Edificio C; 2, Cafetería, Edificio C; '
        '3, Baño, Edificio C',
      ),
    );
    expect(find.text(h.l10n.homeMorePlacesButton), findsOneWidget);

    h.speech.hear('más');
    await h.run(tester);
    expect(
      h.voice.said.last,
      h.l10n.homeMoreOptions(
        '1, Enfermería, Edificio C; 2, Auditorio, Edificio C',
      ),
    );
    expect(
      find.text(h.l10n.homeMorePlacesButton),
      findsNothing,
      reason: 'nothing after these',
    );

    h.speech.hear('el dos');
    await h.run(tester);
    expect(
      find.text(h.l10n.homeGoToTitle('Auditorio · Edificio C')),
      findsOneWidget,
    );
    await h.close(tester);
  });

  testWidgets('"sí" with location off: says why, and shows it', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await h.run(tester);
    h.speech.hear('biblioteca');
    await h.run(tester);

    h.speech.hear('sí');
    await h.run(tester);
    expect(h.voice.said, contains(h.l10n.homeSearchingLocation));
    expect(h.voice.said.last, h.l10n.locationServiceDisabledError);
    expect(find.text(h.l10n.locationServiceDisabledError), findsOneWidget);
    await h.close(tester);
  });

  testWidgets('silence is retried four times, then manual search is '
      'offered; "no" gives up (#226)', (tester) async {
    showChoicesNotifier.value = false;
    final h = _Harness();
    await h.pump(tester);
    await h.run(tester);

    for (var retry = 1; retry <= HomeVoiceController.placeRetries; retry++) {
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
    expect(h.voice.said.sublist(h.voice.said.length - 2), [
      h.l10n.homeVoiceNothingHeard,
      h.l10n.homeOfferManualSearch,
    ]);
    h.speech.hear('no');
    await h.run(tester);
    expect(h.voice.said.last, h.l10n.homeVoiceGiveUp);
    expect(h.speech.isListening, isFalse);
    expect(h.users.writes, isEmpty);
    await h.close(tester);
  });

  testWidgets('with manual search already on, the last miss just gives up', (
    tester,
  ) async {
    showChoicesNotifier.value = true;
    addTearDown(() => showChoicesNotifier.value = false);
    final h = _Harness();
    await h.pump(tester);
    await h.run(tester);
    for (var i = 0; i <= HomeVoiceController.placeRetries; i++) {
      h.speech.hear('');
      await h.run(tester);
    }
    expect(
      h.voice.said.last,
      '${h.l10n.homeVoiceNothingHeard} ${h.l10n.homeVoiceGiveUp}',
    );
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
