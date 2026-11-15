import 'package:eyes4u/admin/tabs/users_tab.dart';
import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/api_fakes.dart';

void main() {
  setUpAll(() => dotenv.testLoad(fileInput: ''));

  Future<(FakeUserApi, AppLocalizations)> open(WidgetTester tester) async {
    final api = FakeUserApi(
      profiles: [
        {'id': 'u2', 'full_name': 'Ana', 'role_id': 2},
      ],
      orphaned: [
        {'id': 'o1', 'email': 'nadie@test'},
      ],
    );
    final controller = UsersController(api);
    await controller.load();
    late AppLocalizations l10n;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            l10n = AppLocalizations.of(context)!;
            return Scaffold(
              body: UsersTab(controller: controller, currentUserId: 'me'),
            );
          },
        ),
      ),
    );
    return (api, l10n);
  }

  testWidgets('demoting an admin asks first', (tester) async {
    final (api, l10n) = await open(tester);
    await tester.tap(find.byTooltip(l10n.adminUsersDemote));
    await tester.pumpAndSettle();
    expect(find.text(l10n.adminUsersDemoteConfirmTitle), findsOneWidget);
    await tester.tap(find.text(l10n.commonCancel));
    await tester.pumpAndSettle();
    expect(api.writes, isEmpty);

    await tester.tap(find.byTooltip(l10n.adminUsersDemote));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.commonDelete));
    await tester.pumpAndSettle();
    final (_, path, body) = api.writes.single;
    expect(path, '/profiles/u2');
    expect(body, {'role_id': 1});
  });

  testWidgets('deactivating asks first; repairing an account says so', (
    tester,
  ) async {
    final (api, l10n) = await open(tester);
    await tester.tap(find.byTooltip(l10n.adminUserDeactivateTooltip));
    await tester.pumpAndSettle();
    expect(find.text(l10n.adminUserDeactivateConfirm('Ana')), findsOneWidget);
    await tester.tap(find.text(l10n.commonDelete));
    await tester.pumpAndSettle();
    expect(api.writes.single.$3, {'is_active': false});

    await tester.tap(find.byTooltip(l10n.adminOrphanedCreateProfileTooltip));
    await tester.pumpAndSettle();
    expect(api.paths('POST'), ['/profiles/o1/repair']);
    expect(
      find.text(l10n.adminOrphanedRepairedSnackbar('nadie@test')),
      findsOneWidget,
    );
  });
}
