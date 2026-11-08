import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import 'app_version.dart';

/// Which phone a trip ran on (B2), stored in `navigation_sessions.device_info`
/// for the trip report (`loadtest/trip_report.py`). Phones differed: one had no
/// barometer, another a compass about 85° off, and no log said which was which.
/// Never throws: whatever can't be read is left out.
Future<Map<String, dynamic>> deviceDetails({DeviceInfoPlugin? plugin}) async {
  final details = <String, dynamic>{
    'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
    'app_version': ?runningAppVersion,
  };
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return details;
  try {
    final info = await (plugin ?? DeviceInfoPlugin()).androidInfo;
    details.addAll(androidDetails(info.data));
  } catch (_) {
    // A trip without the phone's name is still a trip.
  }
  return details;
}

/// The fields the trip report shows, from `AndroidDeviceInfo.data`.
Map<String, dynamic> androidDetails(Map<String, dynamic> data) {
  final version = data['version'];
  return {
    'manufacturer': ?data['manufacturer'],
    'model': ?data['model'],
    if (version is Map) ...{
      'os_version': ?version['release'],
      'sdk': ?version['sdkInt'],
    },
  };
}
