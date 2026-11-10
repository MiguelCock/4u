import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/widgets/connection_warning_dialog.dart';

/// Opens the dialog; [results] gets what it returned.
Future<List<String?>> _open(WidgetTester tester) async {
  final results = <String?>[];
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              results.add(await showConnectionWarningDialog(context, 'Old')),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

void main() {
  testWidgets('saving returns the text, and closing draws no error', (
    tester,
  ) async {
    final results = await _open(tester);
    expect(find.text('Old'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Three steps down');
    await tester.tap(find.text('Save'));
    // Every frame of the closing animation.
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(results, ['Three steps down']);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('cancelling returns null', (tester) async {
    final results = await _open(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(results, [null]);
  });
}
