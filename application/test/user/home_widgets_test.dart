import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/user/home_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The home screen's layout pieces (#268).

Future<AppLocalizations> _pump(WidgetTester tester, Widget child) async {
  late AppLocalizations l10n;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) {
            l10n = AppLocalizations.of(context)!;
            return Column(children: [child]);
          },
        ),
      ),
    ),
  );
  return l10n;
}

void main() {
  testWidgets('the destination row asks, or names the destination', (
    tester,
  ) async {
    final l10n = await _pump(tester, DestinationRow(name: null, onTap: () {}));
    expect(find.text(l10n.homeChooseDestination), findsOneWidget);

    await _pump(tester, DestinationRow(name: 'Biblioteca', onTap: () {}));
    expect(find.text(l10n.homeDestinationLabel('Biblioteca')), findsOneWidget);
    expect(find.text(l10n.homeTapToChangeDestination), findsOneWidget);
  });

  testWidgets('the start row: a spinner while checking, the check icon '
      'for admins', (tester) async {
    await _pump(
      tester,
      const StartRow(subtitle: 'Foto 1 de 6', locating: true, canCheck: true),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Foto 1 de 6'), findsOneWidget);

    await _pump(
      tester,
      const StartRow(subtitle: 'Cerca', locating: false, canCheck: true),
    );
    expect(find.byIcon(Icons.my_location), findsOneWidget);

    await _pump(
      tester,
      const StartRow(subtitle: 'Cerca', locating: false, canCheck: false),
    );
    expect(find.byIcon(Icons.my_location), findsNothing);
  });

  testWidgets('find route: a spinner while finding, off without a target', (
    tester,
  ) async {
    final l10n = await _pump(
      tester,
      const FindRouteButton(finding: false, onPressed: null),
    );
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    expect(find.text(l10n.homeFindRouteButton), findsOneWidget);

    await _pump(tester, const FindRouteButton(finding: true, onPressed: null));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('the footer reports each tap', (tester) async {
    final taps = <String>[];
    final l10n = await _pump(
      tester,
      HomeFooter(
        onHelp: () => taps.add('help'),
        onSettings: () => taps.add('settings'),
        onLogOut: () => taps.add('logout'),
      ),
    );
    await tester.tap(find.text(l10n.homeTutorialButton));
    await tester.tap(find.text(l10n.homeSettingsTooltip));
    await tester.tap(find.text(l10n.commonLogOut));
    expect(taps, ['help', 'settings', 'logout']);
  });
}
