import 'package:clock/clock.dart';
import 'package:geolocator/geolocator.dart';

import 'api_service.dart';

/// Closes navigation session [id] as [status] (`completed` when the user
/// ended it or arrived, `abandoned` when a trip left open is finished from
/// the home screen), now, where the user is ([at], when known). Throws
/// [ApiException]; callers treat it as best effort.
Future<void> closeSession(
  NavigationManagementApi api,
  String id, {
  required String status,
  Position? at,
}) => api.patch('/sessions/$id', {
  'status': status,
  'end_time': clock.now().toUtc().toIso8601String(),
  if (at != null)
    'end_position': {'latitude': at.latitude, 'longitude': at.longitude},
});
