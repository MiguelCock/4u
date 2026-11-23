import 'package:eyes4u/admin/sheets/details.dart';
import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<AppLocalizations> _pump(WidgetTester tester, Widget child) async {
  late AppLocalizations l10n;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) {
          l10n = AppLocalizations.of(context)!;
          return Scaffold(body: child);
        },
      ),
    ),
  );
  return l10n;
}

void main() {
  testWidgets('an action closes the sheet first, then acts', (tester) async {
    final done = <String>[];
    await _pump(
      tester,
      DetailsActions(
        close: () => done.add('close'),
        actions: [
          (icon: Icons.edit, label: 'Editar', onTap: () => done.add('edit')),
        ],
      ),
    );
    await tester.tap(find.text('Editar'));
    expect(done, ['close', 'edit']);
  });

  testWidgets('a connection: typed distance, floor change, warning', (
    tester,
  ) async {
    final l10n = await _pump(
      tester,
      ConnectionDetails(
        connection: const {
          'distance_meters': 12.34,
          'distance_manual': true,
          'notes': ' tres escalones ',
        },
        title: 'A ↔ B',
        a: const {'floor': 0},
        b: const {'floor': 1},
        actions: const [],
        close: () {},
      ),
    );
    expect(
      find.text(
        [
          l10n.adminConnectionDistanceTyped('12.3'),
          l10n.adminConnectionChangesFloor,
          l10n.adminConnectionWarning('tres escalones'),
        ].join('\n'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a building: its university, floors and points', (tester) async {
    final l10n = await _pump(
      tester,
      BuildingDetails(
        building: const {'name': 'Bloque A', 'floors': 3, 'is_active': false},
        place: null,
        pointCount: 7,
        actions: const [],
        close: () {},
      ),
    );
    expect(
      find.text(
        [
          l10n.commonUnknownUniversity,
          l10n.adminMapFloorsLabel(3),
          l10n.adminAnchorCountLabel(7),
          l10n.adminMapInactive,
        ].join(' · '),
      ),
      findsOneWidget,
    );
  });
}
