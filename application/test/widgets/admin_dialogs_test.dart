import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/services/api_service.dart';
import 'package:eyes4u/widgets/admin_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<BuildContext> _pump(WidgetTester tester) async {
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    ),
  );
  return context;
}

void main() {
  testWidgets('confirmAction: true only when confirmed, Delete by default', (
    tester,
  ) async {
    final context = await _pump(tester);
    final l10n = AppLocalizations.of(context)!;
    final answer = confirmAction(context, title: 'T', content: 'C');
    await tester.pumpAndSettle();
    expect(find.text(l10n.commonDelete), findsOneWidget);
    await tester.tap(find.text(l10n.commonDelete));
    await tester.pumpAndSettle();
    expect(await answer, isTrue);

    final cancelled = confirmAction(
      context,
      title: 'T',
      content: 'C',
      confirmLabel: 'Desactivar',
    );
    await tester.pumpAndSettle();
    expect(find.text('Desactivar'), findsOneWidget);
    await tester.tap(find.text(l10n.commonCancel));
    await tester.pumpAndSettle();
    expect(await cancelled, isFalse);
  });

  testWidgets('showApiError: the sentence around the error in plain words', (
    tester,
  ) async {
    final context = await _pump(tester);
    final l10n = AppLocalizations.of(context)!;
    showApiError(
      context,
      ApiException(503, 'down'),
      l10n.commonErrorDeleteFailed,
    );
    await tester.pump();
    expect(
      find.text(
        l10n.commonErrorDeleteFailed(l10n.commonErrorServerUnavailable),
      ),
      findsOneWidget,
    );
  });
}
