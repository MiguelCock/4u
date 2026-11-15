import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/widgets/location_type_field.dart';

Future<void> _open(WidgetTester tester, Locale locale) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: LocationTypeField(value: null, onChanged: (_) {})),
    ),
  );
  await tester.tap(find.byType(LocationTypeField));
  await tester.pumpAndSettle();
}

void main() {
  for (final (locale, other) in [
    (const Locale('es'), 'Otro'),
    (const Locale('en'), 'Other'),
  ]) {
    testWidgets('"$other" shows once: the category has its own name (#242)', (
      tester,
    ) async {
      await _open(tester, locale);
      final list = find.byType(Scrollable).last;
      // "Other" is the last category: scroll to its end.
      await tester.scrollUntilVisible(find.text(other), 300, scrollable: list);
      await tester.drag(list, const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(find.text(other), findsOneWidget);
    });
  }
}
