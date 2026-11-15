import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/api_error_messages.dart';
import '../../services/api_service.dart';
import '../../widgets/admin_dialogs.dart';
import '../../widgets/scrollable_message.dart';

/// The admin's Users list (#95): profiles, and accounts left without one
/// by a failed signup. Loaded the first time the tab opens.
class UsersController extends ChangeNotifier {
  UsersController(this.api);

  final UserManagementApi api;

  List<Map<String, dynamic>> users = [];
  List<Map<String, dynamic>> orphaned = [];
  bool loaded = false;

  /// Why the last load failed, or null.
  Object? error;
  bool _disposed = false;

  Future<void> load() async {
    try {
      final results = await Future.wait([
        api.get('/profiles'),
        // Best-effort: a failure here shouldn't hide the real users list.
        api.get('/profiles/orphaned').catchError((_) => const []),
      ]);
      if (_disposed) return;
      users = (results[0] as List? ?? []).cast<Map<String, dynamic>>();
      orphaned = (results[1] as List? ?? []).cast<Map<String, dynamic>>();
      loaded = true;
      error = null;
    } on ApiException catch (e) {
      if (_disposed) return;
      error = e;
      loaded = true;
    }
    notifyListeners();
  }

  /// [body] saved on profile [id] (`PATCH /profiles/{id}`), then reloaded.
  Future<void> update(String id, Map<String, dynamic> body) async {
    await api.patch('/profiles/$id', body);
    await load();
  }

  /// A profile made for an account without one, then reloaded.
  Future<void> repair(String id) async {
    await api.post('/profiles/$id/repair', {});
    await load();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The Users tab: promote or demote, activate or deactivate (never your
/// own row, [currentUserId]), and repair accounts without a profile.
class UsersTab extends StatelessWidget {
  const UsersTab({super.key, required this.controller, this.currentUserId});

  final UsersController controller;
  final String? currentUserId;

  static const _adminRoleId = 2;
  static const _userRoleId = 1;

  Future<void> _save(
    BuildContext context,
    Map<String, dynamic> user,
    Map<String, dynamic> body,
  ) async {
    try {
      await controller.update(user['id'] as String, body);
    } on ApiException catch (e) {
      if (!context.mounted) return;
      showApiError(
        context,
        e,
        AppLocalizations.of(context)!.adminUsersErrorUpdateFailed,
      );
    }
  }

  Future<void> _repair(
    BuildContext context,
    Map<String, dynamic> orphan,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final label = orphan['email'] as String? ?? orphan['id'] as String;
    try {
      await controller.repair(orphan['id'] as String);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.adminOrphanedRepairedSnackbar(label))),
      );
    } on ApiException catch (e) {
      if (!context.mounted) return;
      showApiError(context, e, l10n.adminOrphanedErrorRepairFailed);
    }
  }

  /// Deactivated accounts are refused by every service (packages'
  /// get_caller_id answers 403) until an admin activates them again.
  Future<void> _setActive(
    BuildContext context,
    Map<String, dynamic> user,
    bool active,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    if (!active) {
      final confirmed = await confirmAction(
        context,
        title: l10n.adminUserDeactivateTooltip,
        content: l10n.adminUserDeactivateConfirm(
          user['full_name'] as String? ?? user['id'] as String,
        ),
      );
      if (!confirmed || !context.mounted) return;
    }
    await _save(context, user, {'is_active': active});
  }

  Future<void> _promoteOrDemote(
    BuildContext context,
    Map<String, dynamic> user,
  ) async {
    if (user['role_id'] != _adminRoleId) {
      await _save(context, user, {'role_id': _adminRoleId});
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await confirmAction(
      context,
      title: l10n.adminUsersDemoteConfirmTitle,
      content: l10n.adminUsersDemoteConfirmContent(
        user['full_name'] as String? ?? user['id'] as String,
      ),
    );
    if (!confirmed || !context.mounted) return;
    await _save(context, user, {'role_id': _userRoleId});
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final c = controller;
    if (!c.loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = c.error;
    if (error != null) {
      return ScrollableMessage(
        l10n.adminUsersErrorLoadFailed(friendlyApiErrorMessage(context, error)),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12.0),
          child: Text(
            l10n.adminUsersBootstrapNote,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (c.orphaned.isNotEmpty)
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            color: Theme.of(context).colorScheme.errorContainer,
            child: ExpansionTile(
              initiallyExpanded: true,
              leading: Icon(
                Icons.warning_amber_rounded,
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
              title: Text(
                l10n.adminOrphanedSectionTitle(c.orphaned.length),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
              subtitle: Text(
                l10n.adminOrphanedSectionHint,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
              children: [
                for (final orphan in c.orphaned)
                  ListTile(
                    title: Text(
                      orphan['email'] as String? ?? orphan['id'] as String,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.person_add_alt_1),
                      color: Theme.of(context).colorScheme.onErrorContainer,
                      tooltip: l10n.adminOrphanedCreateProfileTooltip,
                      onPressed: () => _repair(context, orphan),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: c.users.isEmpty
              ? ScrollableMessage(l10n.adminUsersEmpty)
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: c.users.length,
                  itemBuilder: (context, index) {
                    final user = c.users[index];
                    final isAdmin = user['role_id'] == 2;
                    final isSelf = user['id'] == currentUserId;
                    final active = user['is_active'] as bool? ?? true;
                    return ListTile(
                      leading: Icon(
                        isAdmin
                            ? Icons.admin_panel_settings
                            : Icons.person_outline,
                        color: isAdmin ? Colors.indigo : Colors.grey,
                      ),
                      title: Text(
                        user['full_name'] as String? ?? user['id'] as String,
                      ),
                      subtitle: Text(
                        [
                          isAdmin
                              ? l10n.adminUsersRoleAdmin
                              : l10n.adminUsersRoleUser,
                          if (!active) l10n.adminUserInactive,
                        ].join(' · '),
                        style: active
                            ? null
                            : const TextStyle(color: Colors.red),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(
                              isAdmin
                                  ? Icons.remove_moderator_outlined
                                  : Icons.admin_panel_settings_outlined,
                            ),
                            tooltip: isAdmin
                                ? l10n.adminUsersDemote
                                : l10n.adminUsersPromote,
                            onPressed: isSelf
                                ? null
                                : () => _promoteOrDemote(context, user),
                          ),
                          IconButton(
                            icon: Icon(
                              active
                                  ? Icons.person_off_outlined
                                  : Icons.person_add_alt_outlined,
                            ),
                            tooltip: active
                                ? l10n.adminUserDeactivateTooltip
                                : l10n.adminUserActivateTooltip,
                            // Not on your own row: no locking yourself out.
                            onPressed: isSelf
                                ? null
                                : () => _setActive(context, user, !active),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
