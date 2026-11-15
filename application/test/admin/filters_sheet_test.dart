import 'package:eyes4u/admin/sheets/filters.dart';
import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/services/anchor_filters.dart';
import 'package:eyes4u/services/connection_filters.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<(BuildContext, AppLocalizations)> _pump(WidgetTester tester) async {
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
  return (context, AppLocalizations.of(context)!);
}

void main() {
  testWidgets('points: counts per status, floors, and each change applied', (
    tester,
  ) async {
    final (context, l10n) = await _pump(tester);
    var filters = AnchorFilters.none;
    showAnchorFiltersSheet(
      context,
      current: () => filters,
      onChanged: (next) => filters = next,
      count: (status) => status == 'verified' ? 4 : 9,
      maxFloors: 2,
    );
    await tester.pumpAndSettle();
    final verified = l10n.adminStatusChipLabel(l10n.commonStatusVerified, 4);
    expect(find.text(verified), findsOneWidget);
    expect(find.text(l10n.commonFloorOption(2)), findsOneWidget);
    expect(find.text(l10n.commonFloorOption(3)), findsNothing);

    await tester.tap(find.text(verified));
    await tester.pumpAndSettle();
    expect(filters.status, 'verified');
    // On: "Clear" appears, and clears.
    await tester.tap(find.text(l10n.adminFiltersClear));
    await tester.pumpAndSettle();
    expect(filters.isEmpty, isTrue);
  });

  testWidgets('connections: yes, no or any for each', (tester) async {
    final (context, l10n) = await _pump(tester);
    var filters = ConnectionFilters.none;
    showConnectionFiltersSheet(
      context,
      current: () => filters,
      onChanged: (next) => filters = next,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.adminFilterYes).first);
    await tester.pumpAndSettle();
    expect(filters.long, isTrue);
    expect(filters.hasWarning, isNull);
  });
}
