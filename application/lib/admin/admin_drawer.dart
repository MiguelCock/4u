import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/admin_lists.dart';
import '../services/capture_checks.dart';
import '../services/location_types.dart';
import '../theme/admin_palette.dart';
import '../user/user_home_screen.dart';
import '../widgets/admin_guide.dart';
import '../widgets/admin_map/admin_map.dart';
import '../widgets/drawer_list.dart';
import '../widgets/review_list.dart';
import 'feedback_screen.dart';
import 'sessions_screen.dart';

/// The admin home's sections, in drawer order. The map is first and opens
/// the app (C2).
abstract final class AdminSection {
  static const map = 0;
  static const universities = 1;
  static const buildings = 2;
  static const points = 3;
  static const connections = 4;
  static const users = 5;
}

/// The admin home's menu: the signed-in admin, the sections, sessions,
/// feedback, re-indexing, and the notices for mapping mistakes that break
/// navigation (each opening what needs fixing). A side panel when
/// [permanent] (wide screens).
class AdminDrawer extends StatelessWidget {
  const AdminDrawer({
    super.key,
    required this.permanent,
    required this.selected,
    required this.email,
    required this.lists,
    required this.loading,
    required this.reindexing,
    required this.unsearchablePhotos,
    required this.pointLabel,
    required this.buildingName,
    required this.onSection,
    required this.onClose,
    required this.onReindex,
    required this.onShowOnMap,
  });

  final bool permanent;

  /// The section shown ([AdminSection]).
  final int selected;
  final String? email;
  final AdminLists lists;
  final bool loading;
  final bool reindexing;
  final int? unsearchablePhotos;
  final String Function(Map<String, dynamic>? point) pointLabel;
  final String Function(String? buildingId) buildingName;
  final void Function(int section) onSection;

  /// Closes the menu (nothing to close when it's [permanent]).
  final VoidCallback onClose;
  final VoidCallback onReindex;
  final void Function(AdminMapHit item) onShowOnMap;

  /// Mapping mistakes that break navigation, from the loaded lists (see
  /// `capture_checks.dart`). Each opens what needs fixing; nothing shows
  /// when the data is clean.
  List<Widget> _dataHealthTiles(BuildContext context, AppLocalizations l10n) {
    if (loading) return const [];
    final unconnected = verifiedUnconnectedPoints(
      lists.anchorPoints,
      lists.connections,
    );
    final hidden = namedHiddenPoints(lists.anchorPoints);
    final long = longConnections(lists.anchorPoints, lists.connections);
    final floorChange = floorChangeConnections(
      lists.anchorPoints,
      lists.connections,
    );
    Widget tile(String text, IconData icon, VoidCallback onTap) => ListTile(
      leading: Icon(icon, color: kAdminPalette.notice),
      title: Text(text, style: TextStyle(color: kAdminPalette.notice)),
      onTap: () {
        onClose();
        onTap();
      },
    );
    return [
      if (unconnected.isNotEmpty)
        tile(
          l10n.adminHealthUnconnected(unconnected.length),
          Icons.link_off,
          () => _showUnconnectedVerified(context),
        ),
      if (hidden.isNotEmpty)
        tile(
          l10n.adminHealthHiddenNamed(hidden.length),
          Icons.visibility_off_outlined,
          () => _showReviewList(
            context,
            title: l10n.adminHealthHiddenNamed(hidden.length),
            guideSection: 'pitfall-type',
            hint: l10n.adminHealthHiddenNamedHint,
            items: [
              for (final point in hidden)
                (
                  title: anchorDisplayName(l10n, point),
                  subtitle: [
                    locationTypeLabel(
                      l10n,
                      kLocationTypes[point['location_type_id']] ?? 'other',
                    ),
                    buildingName(point['building_id'] as String?),
                  ].join(' · '),
                  onTap: () => onShowOnMap(PointHit(point)),
                ),
            ],
          ),
        ),
      if (long.isNotEmpty)
        tile(
          l10n.adminHealthLongConnections(long.length),
          Icons.straighten,
          () {
            final byId = {for (final p in lists.anchorPoints) p['id']: p};
            _showReviewList(
              context,
              title: l10n.adminHealthLongConnections(long.length),
              guideSection: 'pitfall-gap',
              hint: l10n.adminHealthLongConnectionsHint,
              items: [
                for (final c in long)
                  (
                    title:
                        '${pointLabel(byId[c['anchor_point_a_id']])}'
                        ' ↔ '
                        '${pointLabel(byId[c['anchor_point_b_id']])}',
                    subtitle: l10n.adminHealthConnectionSubtitle(
                      anchorDistance(
                        byId[c['anchor_point_a_id']]!,
                        byId[c['anchor_point_b_id']]!,
                      )!.toStringAsFixed(0),
                    ),
                    onTap: () => onShowOnMap(ConnectionHit(c)),
                  ),
              ],
            );
          },
        ),
      if (floorChange.isNotEmpty)
        tile(l10n.adminHealthFloorChange(floorChange.length), Icons.stairs, () {
          final byId = {for (final p in lists.anchorPoints) p['id']: p};
          _showReviewList(
            context,
            title: l10n.adminHealthFloorChange(floorChange.length),
            guideSection: 'pitfall-floor',
            hint: l10n.adminHealthFloorChangeHint,
            items: [
              for (final c in floorChange)
                (
                  title:
                      '${pointLabel(byId[c['anchor_point_a_id']])}'
                      ' ↔ '
                      '${pointLabel(byId[c['anchor_point_b_id']])}',
                  subtitle: l10n.adminHealthConnectionSubtitle(
                    (anchorDistance(
                              byId[c['anchor_point_a_id']]!,
                              byId[c['anchor_point_b_id']]!,
                            ) ??
                            0)
                        .toStringAsFixed(0),
                  ),
                  onTap: () => onShowOnMap(ConnectionHit(c)),
                ),
            ],
          );
        }),
    ];
  }

  /// Verified points with no connection, each opening on the map to fix.
  void _showUnconnectedVerified(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final points = verifiedUnconnectedPoints(
      lists.anchorPoints,
      lists.connections,
    );
    _showReviewList(
      context,
      title: l10n.adminHealthUnconnected(points.length),
      guideSection: 'pitfall-unconnected',
      hint: l10n.adminHealthUnconnectedHint,
      items: [
        for (final point in points)
          (
            title: anchorDisplayName(l10n, point),
            subtitle: buildingName(point['building_id'] as String?),
            onTap: () => onShowOnMap(PointHit(point)),
          ),
      ],
    );
  }

  Future<void> _showReviewList(
    BuildContext context, {
    required String title,
    required String hint,
    required List<ReviewItem> items,
    String? guideSection,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (context, controller) => ReviewList(
        controller: controller,
        title: title,
        hint: hint,
        items: items,
        guideSection: guideSection,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget item(int index, IconData icon, Color color, String label) {
      return ListTile(
        leading: Icon(icon, color: color),
        title: Text(label),
        selected: selected == index,
        onTap: () {
          onSection(index);
          onClose();
        },
      );
    }

    return Drawer(
      // Part of the page on a wide screen (see _scaffold).
      elevation: permanent ? 0 : null,
      shape: permanent ? const RoundedRectangleBorder() : null,
      child: DrawerList(
        children: [
          // A compact header: DrawerHeader's fixed height left a band of
          // empty space under the email.
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.adminUsersRoleAdmin,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  Text(
                    email ?? '',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          // The tutorial is a page next to the web app, for reading beside it.
          if (kIsWeb)
            ListTile(
              leading: const Icon(Icons.menu_book, color: Colors.blue),
              title: Text(l10n.adminGuide),
              onTap: () {
                onClose();
                openAdminGuide(context);
              },
            ),
          item(
            AdminSection.map,
            Icons.map_outlined,
            Colors.blue,
            l10n.adminSectionMap,
          ),
          item(
            AdminSection.universities,
            Icons.flag,
            kAdminPalette.university,
            l10n.adminSectionUniversities,
          ),
          item(
            AdminSection.buildings,
            Icons.apartment,
            kAdminPalette.building,
            l10n.adminSectionBuildings,
          ),
          item(
            AdminSection.points,
            Icons.location_pin,
            kAdminPalette.verified,
            l10n.adminSectionAnchorPoints,
          ),
          item(
            AdminSection.connections,
            Icons.timeline,
            kAdminPalette.connectionActive,
            l10n.adminSectionConnections,
          ),
          item(
            AdminSection.users,
            Icons.people,
            Colors.indigo,
            l10n.adminUsersTabLabel,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.my_location, color: Colors.teal),
            title: Text(l10n.adminSessions),
            onTap: () {
              onClose();
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SessionsScreen()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.comment_outlined, color: Colors.teal),
            title: Text(l10n.feedbackScreenTitle),
            onTap: () {
              onClose();
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const FeedbackScreen()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.manage_search, color: Colors.teal),
            title: Text(l10n.adminReindexMenu),
            subtitle: (unsearchablePhotos ?? 0) > 0
                ? Text(
                    l10n.adminReindexUnsearchable(unsearchablePhotos!),
                    style: const TextStyle(color: Colors.red),
                  )
                : null,
            enabled: !reindexing && !loading,
            onTap: () {
              onClose();
              onReindex();
            },
          ),
          ..._dataHealthTiles(context, l10n),
          // Trips need the phone's camera and sensors.
          if (!kIsWeb)
            ListTile(
              leading: const Icon(
                Icons.visibility_outlined,
                color: Colors.teal,
              ),
              title: Text(l10n.adminTestAsUser),
              onTap: () {
                onClose();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const UserHomeScreen(adminPreview: true),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
