import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/location_service.dart';

/// A trip left open by closing the app mid-route (#268): offered to
/// continue or finish, instead of staying "active" forever. Came out of
/// `UserHomeScreen`.

/// The newest open trip and its route.
typedef UnfinishedTrip = ({
  Map<String, dynamic> session,
  Map<String, dynamic> route,
});

class UnfinishedTrips {
  UnfinishedTrips({
    NavigationManagementApi? navigationApi,
    RouteManagementApi? routeApi,
    LocationService? locationService,
    DateTime Function()? now,
  }) : _navigationApi = navigationApi ?? NavigationManagementApi(),
       _routeApi = routeApi ?? RouteManagementApi(),
       _location = locationService ?? LocationService(),
       _now = now ?? DateTime.now;

  final NavigationManagementApi _navigationApi;
  final RouteManagementApi _routeApi;
  final LocationService _location;
  final DateTime Function() _now;

  /// The newest open trip that can be resumed, or null. Older ones are
  /// closed, and so is the newest when its route is gone (nothing to resume
  /// onto). Best effort: a failure is no trip, and never blocks the screen.
  Future<UnfinishedTrip?> find() async {
    List<Map<String, dynamic>> sessions;
    try {
      sessions = (await _navigationApi.get('/sessions/active') as List)
          .cast<Map<String, dynamic>>();
    } on ApiException {
      return null;
    }
    if (sessions.isEmpty) return null;
    final latest = sessions.first;
    for (final old in sessions.skip(1)) {
      abandon(old);
    }
    Map<String, dynamic>? route;
    final routeId = latest['route_id'] as String?;
    if (routeId != null) {
      try {
        route = await _routeApi.get('/routes/$routeId') as Map<String, dynamic>;
      } on ApiException {
        route = null;
      }
    }
    if (route == null) {
      await abandon(latest);
      return null;
    }
    return (session: latest, route: route);
  }

  /// Closes a session the user didn't finish as `abandoned` (not
  /// `completed`: they never arrived), so admins can tell them apart. Best
  /// effort: it will be offered again next launch.
  Future<void> abandon(Map<String, dynamic> session) async {
    final position = _location.lastPosition;
    try {
      await _navigationApi.patch('/sessions/${session['id']}', {
        'status': 'abandoned',
        'end_time': _now().toUtc().toIso8601String(),
        if (position != null)
          'end_position': {
            'latitude': position.latitude,
            'longitude': position.longitude,
          },
      });
    } on ApiException {
      // Offered again next launch.
    }
  }
}

/// "You have an unfinished trip to X, started at HH:MM": true to continue,
/// false to finish it. [destination] is the end point's name, if known.
Future<bool> askResumeTrip(
  BuildContext context, {
  required UnfinishedTrip trip,
  String? destination,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final startedAt = DateTime.tryParse(
    trip.session['start_time'] as String? ?? '',
  );
  final time = startedAt == null
      ? '?'
      : TimeOfDay.fromDateTime(startedAt.toLocal()).format(context);
  final resume = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(l10n.homeUnfinishedTripTitle),
      content: Text(
        l10n.homeUnfinishedTripContent(
          destination ?? l10n.navYourDestination,
          time,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.homeUnfinishedTripFinish),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.homeUnfinishedTripResume),
        ),
      ],
    ),
  );
  return resume == true;
}
