import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/widgets/review_list.dart';

Future<List<String>> _pump(
  WidgetTester tester, {
  String? guideSection,
  bool showGuideLink = true,
}) async {
  final tapped = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            builder: (_) => ReviewList(
              title: '1 connections over 30 m',
              hint: "Routes don't use them.",
              guideSection: guideSection,
              showGuideLink: showGuideLink,
              items: [
                (
                  title: 'Entrada ↔ Patio',
                  subtitle: '36 m',
                  onTap: () => tapped.add('line'),
                ),
              ],
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return tapped;
}

void main() {
  testWidgets('a notice with a guide section links to its pitfall', (
    tester,
  ) async {
    await _pump(tester, guideSection: 'pitfall-gap');
    expect(find.text('How to fix'), findsOneWidget);
  });

  testWidgets('no link without a section, or where there is no guide', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('How to fix'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, guideSection: 'pitfall-gap', showGuideLink: false);
    expect(find.text('How to fix'), findsNothing);
  });

  testWidgets('a row closes the list and opens its item', (tester) async {
    final tapped = await _pump(tester, guideSection: 'pitfall-gap');
    await tester.tap(find.text('Entrada ↔ Patio'));
    await tester.pumpAndSettle();
    expect(tapped, ['line']);
    expect(find.text('Entrada ↔ Patio'), findsNothing);
  });
}
