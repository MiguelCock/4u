import 'package:eyes4u/admin/admin_actions.dart';
import 'package:eyes4u/admin/admin_map_data.dart';
import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/api_fakes.dart';

void main() {
  setUpAll(() => dotenv.testLoad(fileInput: ''));

  late FakeMapApi map;
  late FakeAiTrainingApi ai;
  late AdminActions actions;
  late BuildContext context;
  late AppLocalizations l10n;
  var reloads = 0;
  final running = <bool>[];

  Future<void> setUpActions(WidgetTester tester) async {
    map = FakeMapApi(
      anchors: [
        {
          'id': 'a1',
          'status': 'verified',
          'location_description': 'Biblioteca',
          'latitude': 3.34,
          'longitude': -76.53,
          'building_id': 'b1',
        },
      ],
      photos: [
        {'id': 'ph1', 'anchor_point_id': 'a1', 'image_url': null},
      ],
    );
    ai = FakeAiTrainingApi(indexedPhotoIds: {});
    final data = AdminMapData(mapApi: map, aiTrainingApi: ai);
    reloads = 0;
    running.clear();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (c) {
              context = c;
              l10n = AppLocalizations.of(c)!;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.runAsync(data.loadAll);
    actions = AdminActions(
      mapApi: map,
      aiTrainingApi: ai,
      data: data,
      reload: () async => reloads++,
      pointLabel: (p) => '${p?['location_description']}',
      onReindexing: running.add,
    );
  }

  testWidgets('re-indexing: tidy the index, send what\'s missing, report', (
    tester,
  ) async {
    await setUpActions(tester);
    actions.reindexVerified(context);
    await tester.pumpAndSettle();
    expect(ai.paths('POST'), ['/reconcile', '/index_anchor']);
    expect(running, [true, false]);
    expect(find.text(l10n.adminReindexResultTitle), findsOneWidget);
    expect(find.text(l10n.adminReindexDone(1, 1)), findsOneWidget);
  });

  testWidgets('a connection\'s delete asks, then deletes and reloads', (
    tester,
  ) async {
    await setUpActions(tester);
    actions.deleteConnection(context, {'id': 'c9'});
    await tester.pumpAndSettle();
    expect(find.text(l10n.adminDeleteConnectionTitle), findsOneWidget);
    await tester.tap(find.text(l10n.commonDelete));
    await tester.pumpAndSettle();
    expect(map.paths('DELETE'), ['/anchor-point-connections/c9']);
    expect(reloads, 1);
  });

  testWidgets('unverifying: pending, and out of photo search', (tester) async {
    await setUpActions(tester);
    actions.setAnchorStatus(context, map.anchors.single, 'pending');
    await tester.pumpAndSettle();
    expect(map.writes.single.$3!['status'], 'pending');
    expect(ai.paths('DELETE'), ['/index_anchor/a1']);
    expect(reloads, 1);
  });
}
