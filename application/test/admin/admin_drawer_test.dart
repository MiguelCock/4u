import 'package:eyes4u/admin/admin_drawer.dart';
import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/services/admin_lists.dart';
import 'package:eyes4u/widgets/admin_map/admin_map.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A verified point with no connection, and a hallway with a name.
  const lists = AdminLists(
    buildings: [
      {'id': 'b1', 'name': 'Bloque A'},
    ],
    anchorPoints: [
      {
        'id': 'a1',
        'building_id': 'b1',
        'status': 'verified',
        'location_type_id': 23,
        'location_description': 'Biblioteca',
        'latitude': 3.34,
        'longitude': -76.53,
      },
      {
        'id': 'a2',
        'building_id': 'b1',
        'status': 'pending',
        'location_type_id': 10,
        'location_description': 'Pasillo norte',
        'latitude': 3.34,
        'longitude': -76.53,
      },
    ],
  );

  testWidgets('sections, the photo notice, and the mapping notices', (
    tester,
  ) async {
    final sections = <int>[];
    final shown = <AdminMapHit>[];
    var closed = 0;
    var reindexed = 0;
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
              body: AdminDrawer(
                permanent: true,
                selected: AdminSection.map,
                email: 'admin@test',
                lists: lists,
                loading: false,
                reindexing: false,
                unsearchablePhotos: 2,
                pointLabel: (p) => '${p?['location_description']}',
                buildingName: (_) => 'Bloque A',
                onSection: sections.add,
                onClose: () => closed++,
                onReindex: () => reindexed++,
                onShowOnMap: shown.add,
              ),
            );
          },
        ),
      ),
    );
    expect(find.text('admin@test'), findsOneWidget);

    await tester.tap(find.text(l10n.adminSectionConnections));
    expect(sections, [AdminSection.connections]);
    expect(closed, 1);

    // Further down the menu.
    await tester.ensureVisible(find.text(l10n.adminReindexUnsearchable(2)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.adminReindexUnsearchable(2)));
    expect(reindexed, 1);

    expect(find.text(l10n.adminHealthHiddenNamed(1)), findsOneWidget);
    await tester.ensureVisible(find.text(l10n.adminHealthUnconnected(1)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.adminHealthUnconnected(1)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Biblioteca').last);
    await tester.pumpAndSettle();
    expect((shown.single as PointHit).point['id'], 'a1');
  });
}
