import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/widgets/fab_row.dart';
import 'package:eyes4u/widgets/scope_dropdowns.dart';

final _places = [
  {'id': 'eafit', 'name': 'EAFIT'},
  {'id': 'icesi', 'name': 'Icesi'},
];
final _buildings = [
  {'id': 'bib', 'place_id': 'eafit', 'name': 'Biblioteca'},
  {'id': 'b38', 'place_id': 'eafit', 'name': 'Bloque 38'},
  {'id': 'ice', 'place_id': 'icesi', 'name': 'Edificio L'},
];

Widget _app(Widget body, {Widget? fab}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: body,
    floatingActionButton: fab,
    floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
  ),
);

void main() {
  testWidgets('a university narrows the buildings and resets the building', (
    tester,
  ) async {
    String? place = 'eafit';
    String? building = 'bib';
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) => ScopeDropdowns(
            places: _places,
            buildings: _buildings,
            placeId: place,
            buildingId: building,
            onChanged: (p, b) => setState(() {
              place = p;
              building = b;
            }),
          ),
        ),
      ),
    );

    // EAFIT's buildings only.
    await tester.tap(find.text('Biblioteca'));
    await tester.pumpAndSettle();
    expect(find.text('Bloque 38'), findsWidgets);
    expect(find.text('Edificio L'), findsNothing);
    await tester.tap(find.text('Bloque 38').last);
    await tester.pumpAndSettle();
    expect((place, building), ('eafit', 'b38'));

    await tester.tap(find.text('EAFIT'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Icesi').last);
    await tester.pumpAndSettle();
    expect((place, building), ('icesi', null));
  });

  testWidgets('the last row\'s buttons clear both floating buttons', (
    tester,
  ) async {
    final tapped = <int>[];
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => ListView.builder(
            padding: EdgeInsets.only(bottom: fabClearance(context)),
            itemCount: 30,
            itemBuilder: (context, i) => ListTile(
              title: Text('row $i'),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => tapped.add(i),
              ),
            ),
          ),
        ),
        fab: FabRow(
          left: FloatingActionButton(
            heroTag: 'left',
            onPressed: () {},
            child: const Icon(Icons.filter_list),
          ),
          right: FloatingActionButton(
            heroTag: 'right',
            onPressed: () {},
            child: const Icon(Icons.add),
          ),
        ),
      ),
    );

    await tester.scrollUntilVisible(find.text('row 29'), 300);
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    final button = find.descendant(
      of: find.widgetWithText(ListTile, 'row 29'),
      matching: find.byType(IconButton),
    );
    // Hit-testable where it's drawn: nothing floats over it.
    await tester.tap(button);
    expect(tapped, [29]);
  });
}
