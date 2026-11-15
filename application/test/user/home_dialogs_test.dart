import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/user/home_dialogs.dart';
import 'package:eyes4u/voice/home_voice_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/voice_fakes.dart';

/// The home screen's three questions on their own (#268): read out, then
/// answered by voice or by tapping.

const _options = [
  {'id': 'a1', 'name': 'Baño · Biblioteca'},
  {'id': 'a2', 'name': 'Baño · Edificio C'},
];

class _Setup {
  final speech = FakeSpeech();
  final voice = FakeVoice();
  late final HomeVoiceController ctl = HomeVoiceController(
    speech: speech,
    voice: voice.voice,
    marks: () async {},
  );
  late AppLocalizations l10n;

  /// Opens [ask] from a button, and keeps its result in [result].
  Object? result;
  bool done = false;

  Future<void> open(
    WidgetTester tester,
    Future<Object?> Function(BuildContext context) ask,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            l10n = AppLocalizations.of(context)!;
            return TextButton(
              onPressed: () async {
                result = await ask(context);
                done = true;
              },
              child: const Text('ask'),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('ask'));
    await run(tester);
  }

  Future<void> run(WidgetTester tester, {int seconds = 2}) async {
    for (var i = 0; i < seconds * 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> close(WidgetTester tester) async {
    ctl.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }
}

Future<Object?> Function(BuildContext) _choose(
  _Setup s, {
  bool listen = true,
}) =>
    (context) => chooseDestination(
      context,
      voice: s.ctl,
      language: 'es',
      options: _options,
      label: (o) => o['name'] as String,
      spoken: (o) => (o['name'] as String).replaceAll(' · ', ', '),
      listen: listen,
    );

Future<Object?> Function(BuildContext) _confirm(
  _Setup s, {
  bool listen = true,
}) =>
    (context) => confirmDestination(
      context,
      voice: s.ctl,
      language: 'es',
      label: 'Biblioteca · Edificio C',
      spoken: 'Biblioteca, Edificio C',
      listen: listen,
    );

void main() {
  group('chooseDestination', () {
    testWidgets('reads the options numbered, then a number picks one', (
      tester,
    ) async {
      final s = _Setup();
      await s.open(tester, _choose(s));
      expect(
        s.voice.said.single,
        s.l10n.homeVoiceSeveralMatches(
          '1, Baño, Biblioteca; 2, Baño, Edificio C',
        ),
      );
      expect(find.text('Baño · Edificio C'), findsOneWidget);
      expect(s.speech.listens, 1);

      s.speech.hear('el dos');
      await s.run(tester);
      expect(s.done, isTrue);
      expect(s.result, (picked: _options[1], noneOfThem: false));
      await s.close(tester);
    });

    testWidgets('"ninguno" is none of them', (tester) async {
      final s = _Setup();
      await s.open(tester, _choose(s));
      s.speech.hear('ninguno');
      await s.run(tester);
      expect(s.result, (picked: null, noneOfThem: true));
      await s.close(tester);
    });

    testWidgets('not understood: asked twice more, then the list stays', (
      tester,
    ) async {
      final s = _Setup();
      await s.open(tester, _choose(s));
      for (var i = 0; i < 2; i++) {
        s.speech.hear('mmm');
        await s.run(tester);
        expect(s.voice.said.last, s.l10n.homeVoiceOptionNotUnderstood);
      }
      s.speech.hear('mmm');
      await s.run(tester);
      expect(s.voice.said.last, s.l10n.homeOptionsGiveUp);
      expect(s.speech.listens, 3);
      expect(s.done, isFalse);

      await tester.tap(find.text('Baño · Biblioteca'));
      await s.run(tester);
      expect(s.result, (picked: _options[0], noneOfThem: false));
      await s.close(tester);
    });

    testWidgets('without listening, only read out', (tester) async {
      final s = _Setup();
      await s.open(tester, _choose(s, listen: false));
      expect(s.voice.said, hasLength(1));
      expect(s.speech.listens, 0);
      await s.close(tester);
    });
  });

  group('confirmDestination', () {
    testWidgets('asks, says "di sí", and "sí" starts', (tester) async {
      final s = _Setup();
      await s.open(tester, _confirm(s));
      expect(
        s.voice.said.single,
        '${s.l10n.homeGoToTitle('Biblioteca, Edificio C')} '
        '${s.l10n.homeSayYesToStart}',
      );
      expect(
        find.text(s.l10n.homeGoToTitle('Biblioteca · Edificio C')),
        findsOneWidget,
      );
      expect(s.speech.listens, 1);

      s.speech.hear('sí');
      await s.run(tester);
      expect(s.result, isTrue);
      expect(s.ctl.isListening, isFalse);
      await s.close(tester);
    });

    testWidgets('"no" changes it', (tester) async {
      final s = _Setup();
      await s.open(tester, _confirm(s));
      s.speech.hear('no');
      await s.run(tester);
      expect(s.result, isFalse);
      await s.close(tester);
    });

    testWidgets('not understood: "di sí o no", twice, then the buttons', (
      tester,
    ) async {
      final s = _Setup();
      await s.open(tester, _confirm(s));
      for (var i = 0; i < 2; i++) {
        s.speech.hear('la biblioteca');
        await s.run(tester);
        expect(s.voice.said.last, s.l10n.homeSayYesOrNo);
      }
      s.speech.hear('la biblioteca');
      await s.run(tester);
      expect(s.voice.said.last, s.l10n.homeConfirmGiveUp);
      expect(s.speech.listens, 3);

      await tester.tap(find.text(s.l10n.homeStartRouteButton));
      await s.run(tester);
      expect(s.result, isTrue);
      await s.close(tester);
    });

    testWidgets('without listening: no "di sí" and no microphone', (
      tester,
    ) async {
      final s = _Setup();
      await s.open(tester, _confirm(s, listen: false));
      expect(
        s.voice.said.single,
        s.l10n.homeGoToTitle('Biblioteca, Edificio C'),
      );
      expect(s.speech.listens, 0);
      await tester.tap(find.text(s.l10n.homeChangeDestinationButton));
      await s.run(tester);
      expect(s.result, isFalse);
      await s.close(tester);
    });
  });

  testWidgets('askStartFloor reads the floors and a tap answers', (
    tester,
  ) async {
    final s = _Setup();
    await s.open(
      tester,
      (context) => askStartFloor(context, voice: s.ctl, floors: [0, 2]),
    );
    expect(
      s.voice.said.single,
      '${s.l10n.homeWhichFloorTitle} '
      '${s.l10n.commonFloorOption(1)}, ${s.l10n.commonFloorOption(3)}.',
    );
    await tester.tap(find.text(s.l10n.commonFloorOption(3)));
    await s.run(tester);
    expect(s.result, 2);
    await s.close(tester);
  });
}
