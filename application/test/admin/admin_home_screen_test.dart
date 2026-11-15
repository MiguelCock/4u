import 'package:eyes4u/admin/admin_home_screen.dart';
import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/api_fakes.dart';

/// Pins how the admin home behaves today, before it's split up (Phase D):
/// loading, back through tabs, a delete with its counts, verifying,
/// promoting a user and the 30 s sync. Everything is a fake.

Map<String, dynamic> _place() => {
  'id': 'p1',
  'name': 'Icesi',
  'latitude': 3.3417,
  'longitude': -76.5300,
};

Map<String, dynamic> _building() => {
  'id': 'b1',
  'place_id': 'p1',
  'name': 'Bloque A',
  'floors': 2,
  'latitude': 3.3417,
  'longitude': -76.5300,
};

Map<String, dynamic> _point(String id, String name, String status) => {
  'id': id,
  'building_id': 'b1',
  'location_type_id': 23,
  'location_description': name,
  'status': status,
  'floor': 0,
  'latitude': 3.3417,
  'longitude': -76.5300,
};

class _Admin {
  _Admin({Map<String, dynamic> Function(String since)? changes})
    : map = FakeMapApi(
        places: [_place()],
        buildings: [_building()],
        anchors: [
          _point('a1', 'Biblioteca', 'verified'),
          _point('a2', 'Cafetería', 'pending'),
        ],
        photos: [
          {
            'id': 'ph1',
            'anchor_point_id': 'a1',
            // No URL: the rows would load it over the network.
            'image_url': null,
            'heading': 0,
          },
          {
            'id': 'ph2',
            'anchor_point_id': 'a2',
            'image_url': null,
            'heading': 90,
          },
        ],
        connections: [
          {
            'id': 'c1',
            'anchor_point_a_id': 'a1',
            'anchor_point_b_id': 'a2',
            'distance_meters': 4.0,
          },
        ],
        changes: changes,
      );

  final FakeMapApi map;
  final users = FakeUserApi(
    profiles: [
      {'id': 'me', 'full_name': 'Admin', 'role_id': 2},
      {'id': 'u2', 'full_name': 'Ana', 'role_id': 1},
    ],
  );
  // ph1 (the verified point's) isn't searchable.
  final ai = FakeAiTrainingApi(indexedPhotoIds: {});
  late AppLocalizations l10n;

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            l10n = AppLocalizations.of(context)!;
            return AdminHomeScreen(
              mapApi: map,
              aiTrainingApi: ai,
              userApi: users,
              userId: () => 'me',
              userEmail: () => 'admin@test',
              signOut: () async {},
              showTiles: false,
            );
          },
        ),
      ),
    );
    await settle(tester);
  }

  /// Lets requests, animations and flutter_map's gesture timer finish.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The app bar's title: the section shown.
  String titleOf(WidgetTester tester) =>
      (tester.widget<AppBar>(find.byType(AppBar)).title! as Text).data!;

  Future<void> section(WidgetTester tester, String label) async {
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await settle(tester);
    await tester.tap(find.widgetWithText(ListTile, label));
    await settle(tester);
  }

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await settle(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }
}

void main() {
  setUpAll(() => dotenv.testLoad(fileInput: ''));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('opens on the map, with the lists loaded', (tester) async {
    final t = _Admin();
    await t.open(tester);
    expect(t.titleOf(tester), t.l10n.adminSectionMap);
    // One photo not in the index: the drawer says so.
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await t.settle(tester);
    expect(find.text(t.l10n.adminReindexUnsearchable(1)), findsOneWidget);
    await t.close(tester);
  });

  testWidgets('back: the drill-down, the tab before, the map, then exit', (
    tester,
  ) async {
    final t = _Admin();
    await t.open(tester);
    await t.section(tester, t.l10n.adminSectionUniversities);
    expect(find.text(t.l10n.adminBuildingCountLabel(1)), findsOneWidget);

    await tester.tap(find.text('Icesi'));
    await t.settle(tester);
    expect(t.titleOf(tester), t.l10n.adminSectionBuildings);
    expect(find.text('Bloque A'), findsOneWidget);

    await t.back(tester);
    expect(t.titleOf(tester), t.l10n.adminSectionUniversities);
    await t.back(tester);
    expect(t.titleOf(tester), t.l10n.adminSectionMap);
    await t.back(tester);
    expect(find.text(t.l10n.commonPressBackAgainToExit), findsOneWidget);
    await t.close(tester);
  });

  testWidgets('deleting a university: its counts, then the index too', (
    tester,
  ) async {
    final t = _Admin();
    await t.open(tester);
    await t.section(tester, t.l10n.adminSectionUniversities);
    await tester.tap(find.byTooltip(t.l10n.commonDelete));
    await t.settle(tester);
    expect(
      find.text(
        t.l10n.adminDeletePlaceContent('Icesi', 1, 2, 2, 1) +
            t.l10n.adminDeleteKeepsHistoryNote,
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(t.l10n.commonDelete),
      ),
    );
    await t.settle(tester);
    expect(t.map.paths('DELETE'), ['/places/p1']);
    expect(t.ai.paths('DELETE'), ['/index_building/b1']);
    await t.close(tester);
  });

  testWidgets('verifying a point saves it, then indexes its photos', (
    tester,
  ) async {
    final t = _Admin();
    await t.open(tester);
    await t.section(tester, t.l10n.adminSectionAnchorPoints);
    await tester.tap(find.byTooltip(t.l10n.adminAnchorVerifyTooltip));
    await t.settle(tester);

    final (_, path, body) = t.map.writes.single;
    expect(path, '/anchor-points/a2');
    expect(body!['status'], 'verified');
    expect(body['expected'], {'status': 'pending'});
    final (method, indexPath, index) = t.ai.writes.single;
    expect((method, indexPath), ('POST', '/index_anchor'));
    expect(index!['anchor_point_id'], 'a2');
    // Named with its building, as in the lists.
    final said = tester.widget<Text>(
      find.descendant(of: find.byType(SnackBar), matching: find.byType(Text)),
    );
    expect(said.data, startsWith('"Cafetería'));
    expect(said.data, contains('Bloque A'));
    await t.close(tester);
  });

  testWidgets('promoting a user; not your own row', (tester) async {
    final t = _Admin();
    await t.open(tester);
    await t.section(tester, t.l10n.adminUsersTabLabel);
    final demoteSelf = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.remove_moderator_outlined),
    );
    expect(demoteSelf.onPressed, isNull);

    await tester.tap(find.byTooltip(t.l10n.adminUsersPromote));
    await t.settle(tester);
    final (method, path, body) = t.users.writes.single;
    expect((method, path), ('PATCH', '/profiles/u2'));
    expect(body, {'role_id': 2});
    await t.close(tester);
  });

  testWidgets('every 30 s: other admins\' changes merged and counted', (
    tester,
  ) async {
    final asked = <String>[];
    final t = _Admin(
      changes: (since) {
        asked.add(since);
        return {
          'next_since': 'later',
          if (asked.length > 1)
            'places': [
              {
                'id': 'p2',
                'name': 'Javeriana',
                'latitude': 3.35,
                'longitude': -76.53,
              },
            ],
        };
      },
    );
    await t.open(tester);
    await tester.pump(const Duration(seconds: 30));
    await t.settle(tester);
    expect(asked.last, 'later');
    expect(find.text(t.l10n.mapUpdatedByOthers(1)), findsOneWidget);
    await t.section(tester, t.l10n.adminSectionUniversities);
    expect(find.text('Javeriana'), findsOneWidget);
    await t.close(tester);
  });
}
