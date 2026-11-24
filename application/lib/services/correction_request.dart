import 'package:geolocator/geolocator.dart';

import 'api_service.dart';

/// One photo and the GPS fix it was taken at, to backend-positioning's
/// `POST /correct_position` (Phase C). The trip and the start check both
/// send it; the answer is the endpoint's own map (`corrected_lat`,
/// `corrected_long`, `anchor_match_id`, `server_busy`...).
///
/// [sessionId] keys the backend's in-memory filter, so photos under one key
/// refine each other. [heading] is the direction the camera faces
/// (magnetic, like the anchor photos'): none skips the heading gate.
/// [walkHeading] is the trusted walking direction (true north, from the
/// gyroscope), with which the filter learns which way the user moves (#120).
/// [storeFrame] keeps the frame, for test walks. Throws [ApiException].
Future<Map<String, dynamic>> postCorrection(
  PositioningApi api, {
  required List<int> bytes,
  required String filename,
  required String sessionId,
  required Position fix,
  double? heading,
  double? walkHeading,
  bool storeFrame = false,
  Duration? timeout,
}) async =>
    await api.postMultipart(
          '/correct_position',
          timeout: timeout,
          fieldName: 'photo',
          bytes: bytes,
          filename: filename,
          fields: {
            'session_id': sessionId,
            'latitude': fix.latitude.toString(),
            'longitude': fix.longitude.toString(),
            'accuracy': fix.accuracy.toString(),
            'heading': ?heading?.toString(),
            // Lets the backend skip re-fusing the same fix.
            'gps_time': fix.timestamp.toUtc().toIso8601String(),
            // The same fix's speed, so the backend can tell standing still
            // from a late fix while walking (#310).
            'gps_speed': fix.speed.toString(),
            'walk_heading': ?walkHeading?.toString(),
            if (storeFrame) 'store_frame': 'true',
          },
        )
        as Map<String, dynamic>;
