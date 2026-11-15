import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/user/home_tutorial.dart';
import 'package:eyes4u/voice/home_voice_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/voice_fakes.dart';

/// #259: the tutorial goes on by itself when each page has been said, and
/// can still be repeated, gone back through or skipped.
class _Tutorial {
  final speech = FakeSpeech();
  final voice = FakeVoice();
  late final ctl = HomeVoiceController(
    speech: speech,
    voice: voice.voice,
    marks: () async {},
  );
  late AppLocalizations l10n;
  late BuildContext context;
  bool finished = false;

  List<String> get pages => [
    l10n.homeTutorialPage1,
    l10n.homeTutorialPage2,
    l10n.homeTutorialPage3,
  ];

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (c) {
            context = c;
            l10n = AppLocalizations.of(c)!;
            return const Scaffold();
          },
        ),
      ),
    );
    showHomeTutorial(context, voice: ctl).then((_) => finished = true);
    await tester.pump();
  }

  /// Up to 10 s, until [done].
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(done(), isTrue, reason: 'waited 10 s');
  }

  /// Lets [seconds] go by.
  Future<void> run(WidgetTester tester, {double seconds = 1}) async {
    for (var i = 0; i < seconds * 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  testWidgets('with no touch: every page said, in turn, then it ends', (
    tester,
  ) async {
    final t = _Tutorial();
    await t.open(tester);
    for (final (i, page) in t.pages.indexed) {
      // Shown, then said (the voice waits 250 ms for the microphone).
      await t.until(
        tester,
        () =>
            find.text(page).evaluate().isNotEmpty &&
            t.voice.said.length == i + 1,
      );
      expect(t.voice.said.last, page, reason: 'page ${i + 1}');
      expect(t.finished, isFalse);
      // It stays while the sentence and the pause last.
      await t.run(tester, seconds: 1);
      expect(find.text(page), findsOneWidget);
    }
    await t.until(tester, () => t.finished);
    await t.run(tester, seconds: 0.5); // the last page's closing animation
    expect(find.byType(AlertDialog), findsNothing);
    expect(t.finished, isTrue);
    expect(t.voice.said, t.pages);
  });

  testWidgets('Repeat says the page again, and still moves on after', (
    tester,
  ) async {
    final t = _Tutorial();
    await t.open(tester);
    await t.run(tester, seconds: 0.5);
    await tester.tap(find.text(t.l10n.homeTutorialRepeat));
    await t.run(tester, seconds: 1);
    // The first saying's pause ends now: it mustn't move the page on.
    expect(find.text(t.pages[0]), findsOneWidget);
    expect(t.voice.said, [t.pages[0], t.pages[0]]);
    await t.run(tester, seconds: 1.5);
    expect(find.text(t.pages[1]), findsOneWidget);
    await tester.tap(find.text(t.l10n.homeTutorialSkip));
    await t.run(tester, seconds: 3);
  });

  testWidgets('Back, Next and Skip', (tester) async {
    final t = _Tutorial();
    await t.open(tester);
    expect(find.text(t.l10n.homeTutorialBack), findsNothing);
    await tester.tap(find.text(t.l10n.homeTutorialNext));
    await t.run(tester, seconds: 0.5);
    expect(find.text(t.pages[1]), findsOneWidget);

    await tester.tap(find.text(t.l10n.homeTutorialBack));
    await t.run(tester, seconds: 0.5);
    expect(find.text(t.pages[0]), findsOneWidget);

    await tester.tap(find.text(t.l10n.homeTutorialSkip));
    await t.run(tester, seconds: 0.5);
    expect(find.byType(AlertDialog), findsNothing);
    expect(t.finished, isTrue);
    await t.run(tester, seconds: 3);
    expect(t.voice.said, [t.pages[0], t.pages[1], t.pages[0]]);
  });

  testWidgets('Repeat just before it would move on: the page stays', (
    tester,
  ) async {
    final t = _Tutorial();
    await t.open(tester);
    // The first saying's pause ends at about 1.85 s, while the page that
    // Repeat closed is still animating away.
    await t.run(tester, seconds: 1.8);
    await tester.tap(find.text(t.l10n.homeTutorialRepeat));
    await t.run(tester, seconds: 0.5);
    expect(find.text(t.pages[0]), findsOneWidget);
    expect(find.text(t.pages[1]), findsNothing);
    await tester.tap(find.text(t.l10n.homeTutorialSkip));
    await t.run(tester, seconds: 3);
  });
}
