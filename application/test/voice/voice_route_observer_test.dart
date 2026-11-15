import 'package:eyes4u/voice/app_voice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A screen that gives the voice up while a page covers it, as the home
/// screen does.
class _Speaker extends StatefulWidget {
  const _Speaker({required this.events});
  final List<String> events;

  @override
  State<_Speaker> createState() => _SpeakerState();
}

class _SpeakerState extends State<_Speaker> with RouteAware {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    voiceRouteObserver.subscribe(this, ModalRoute.of(context)! as PageRoute);
  }

  @override
  void didPushNext() => widget.events.add('covered');

  @override
  void didPopNext() => widget.events.add('back');

  @override
  void dispose() {
    voiceRouteObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

void main() {
  testWidgets('a page covers the screen; a dialog over it does not', (
    tester,
  ) async {
    final events = <String>[];
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [voiceRouteObserver],
        home: _Speaker(events: events),
      ),
    );

    // "Go to X?" is asked by the home screen itself: it keeps the voice.
    showDialog<void>(
      context: navigator.currentContext!,
      builder: (_) => const AlertDialog(title: Text('¿Ir a Biblioteca?')),
    );
    await tester.pumpAndSettle();
    expect(events, isEmpty);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();

    // The trip covers it.
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await tester.pumpAndSettle();
    expect(events, ['covered']);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(events, ['covered', 'back']);
  });
}
