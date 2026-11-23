import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/voice/app_voice.dart';
import 'package:eyes4u/voice/skip_speech.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

/// An engine that takes 2 s per sentence.
class FakeEngine {
  late AppVoice voice;
  final said = <String>[];
  int stops = 0;

  Future<void> speak(String text) async {
    said.add(text);
    voice.onStarted();
    Future.delayed(const Duration(seconds: 2), voice.onEnded);
  }
}

AppVoice _voice(FakeEngine engine) => engine.voice = AppVoice(
  speak: engine.speak,
  stop: () async => engine.stops++,
  configure: (_) async => true,
);

Widget _app(AppVoice voice, {Widget? child}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: SkipSpeech(
    voice: voice,
    child: Scaffold(
      body: Center(child: child ?? const SizedBox.expand(key: Key('screen'))),
    ),
  ),
);

void main() {
  test('skip drops what is said and waiting, and the says return', () {
    fakeAsync((async) {
      final engine = FakeEngine();
      final voice = _voice(engine);
      final owner = voice.claim();
      var done = 0;
      owner.say('Uno.').then((_) => done++);
      owner.say('Dos.').then((_) => done++);
      async.elapse(const Duration(milliseconds: 500));
      voice.skip();
      async.elapse(const Duration(milliseconds: 10));
      expect(done, 2, reason: 'a listen waiting on the prompt opens at once');
      async.elapse(const Duration(seconds: 6));
      expect(engine.said, ['Uno.']);
      expect(voice.skipped.value, 1);
      // The owner keeps the voice: the next sentence is heard.
      owner.say('Tres.');
      async.elapse(const Duration(seconds: 3));
      expect(engine.said, ['Uno.', 'Tres.']);
    });
  });

  testWidgets('three quick taps quiet the app', (tester) async {
    final voice = _voice(FakeEngine());
    await tester.pumpWidget(_app(voice));
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const Key('screen')));
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(voice.skipped.value, 1);
  });

  testWidgets('two taps, or slow ones, do nothing', (tester) async {
    final voice = _voice(FakeEngine());
    await tester.pumpWidget(_app(voice));
    await tester.tap(find.byKey(const Key('screen')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const Key('screen')));
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.byKey(const Key('screen')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(voice.skipped.value, 0);
  });

  testWidgets('the taps still reach the button under them', (tester) async {
    final voice = _voice(FakeEngine());
    var pressed = 0;
    await tester.pumpWidget(
      _app(
        voice,
        child: FilledButton(onPressed: () => pressed++, child: const Text('X')),
      ),
    );
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('X'));
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(pressed, 3);
    expect(voice.skipped.value, 1);
  });

  testWidgets('with TalkBack, the button offers "Callar la app"', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final voice = _voice(FakeEngine());
    await tester.pumpWidget(
      _app(
        voice,
        child: QuietAction(
          voice: voice,
          child: FilledButton(onPressed: () {}, child: const Text('Repetir')),
        ),
      ),
    );
    final node = tester.getSemantics(find.text('Repetir'));
    final data = node.getSemanticsData();
    final action = data.customSemanticsActionIds!
        .map(CustomSemanticsAction.getAction)
        .single!;
    expect(action.label, 'Callar la app');
    // The button is still one button: tapping it is its own action.
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    node.owner!.performAction(
      node.id,
      SemanticsAction.customAction,
      CustomSemanticsAction.getIdentifier(action),
    );
    expect(voice.skipped.value, 1);
    handle.dispose();
  });
}
