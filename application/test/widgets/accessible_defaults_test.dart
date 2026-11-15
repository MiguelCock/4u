import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/auth/login_screen.dart';
import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/services/app_preferences.dart';
import 'package:eyes4u/services/app_version.dart';
import 'package:eyes4u/widgets/app_update.dart';

/// [screen] the way a new account sees it (D10): Spanish, high contrast,
/// bold, the largest text, on a small phone.
Future<void> _pumpAtDefaults(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      locale: kDefaultLocale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(colorScheme: const ColorScheme.highContrastLight()),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: const TextScaler.linear(kDefaultTextScale),
          boldText: kDefaultBoldText,
          highContrast: kDefaultHighContrast,
        ),
        child: child!,
      ),
      home: screen,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('sign-in fits a small phone at the defaults, in Spanish', (
    tester,
  ) async {
    await _pumpAtDefaults(tester, const LoginScreen());
    // An overflow would be reported as an exception here.
    expect(tester.takeException(), isNull);
    expect(find.text('Iniciar sesión'), findsWidgets);
  });

  testWidgets('"update required" fits a small phone at the defaults', (
    tester,
  ) async {
    await _pumpAtDefaults(
      tester,
      const UpdateRequiredScreen(
        policy: AppVersionPolicy(
          latest: '0.6.0',
          minSupported: '0.5.6',
          downloadUrl: 'https://example.com',
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
