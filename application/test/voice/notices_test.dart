import 'package:eyes4u/services/app_preferences.dart';
import 'package:eyes4u/voice/notices.dart';
import 'package:eyes4u/widgets/speak_circle.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<BuildContext> _pump(
  WidgetTester tester, {
  required bool talkback,
}) async {
  late BuildContext context;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(accessibleNavigation: talkback),
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      ),
    ),
  );
  return context;
}

void main() {
  tearDown(() => voiceGuidanceNotifier.value = true);

  testWidgets('without TalkBack, what was said is also shown', (tester) async {
    final context = await _pump(tester, talkback: false);
    showSpokenNotice(context, 'Tu cámara se usará');
    await tester.pump();
    expect(find.text('Tu cámara se usará'), findsOneWidget);
  });

  testWidgets('with TalkBack, it is said once: no SnackBar', (tester) async {
    final context = await _pump(tester, talkback: true);
    showSpokenNotice(context, 'Tu cámara se usará');
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('with TalkBack and the voice off, TalkBack says it', (
    tester,
  ) async {
    final announced = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler(
      SystemChannels.accessibility,
      (message) async => announced.add(message),
    );
    voiceGuidanceNotifier.value = false;
    final context = await _pump(tester, talkback: true);
    showSpokenNotice(context, 'Tu cámara se usará');
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
    expect(announced.toString(), contains('Tu cámara se usará'));
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler(
      SystemChannels.accessibility,
      null,
    );
  });

  testWidgets('the Speak button reads the same while listening or busy', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    Future<void> button({required bool listening, required bool busy}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SpeakCircle(
                listening: listening,
                busy: busy,
                label: 'Di a dónde quieres ir',
                stopLabel: 'Detener',
                onPressed: () {},
              ),
            ),
          ),
        ),
      );
    }

    for (final (listening, busy) in [
      (false, false),
      (false, true),
      (true, false),
    ]) {
      await button(listening: listening, busy: busy);
      expect(
        tester.getSemantics(find.byType(SpeakCircle)),
        isSemantics(
          label: 'Di a dónde quieres ir',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
    }
    // Seen on screen while listening, never read.
    expect(find.text('Detener'), findsOneWidget);
    expect(find.bySemanticsLabel('Detener'), findsNothing);
    handle.dispose();
  });
}
