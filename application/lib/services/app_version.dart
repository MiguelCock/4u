import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Which app versions the backend serves (packages/app_versions.py): the
/// newest release, and the one before it, which is deprecated - it works,
/// and its user is told to update. Older ones get 426 from every service.
class AppVersionPolicy {
  final String latest;
  final String minSupported;
  final String downloadUrl;

  const AppVersionPolicy({
    required this.latest,
    required this.minSupported,
    required this.downloadUrl,
  });

  static AppVersionPolicy? fromJson(Object? json) {
    if (json is! Map) return null;
    final latest = json['latest'];
    final minSupported = json['min_supported'];
    final downloadUrl = json['download_url'];
    if (latest is! String ||
        minSupported is! String ||
        downloadUrl is! String) {
      return null;
    }
    return AppVersionPolicy(
      latest: latest,
      minSupported: minSupported,
      downloadUrl: downloadUrl,
    );
  }

  /// From a response body (a 426's, or GET /user/app-version's).
  static AppVersionPolicy? tryParse(String body) {
    try {
      return fromJson(jsonDecode(body));
    } on FormatException {
      return null;
    }
  }
}

enum AppVersionStatus { current, deprecated, unsupported }

/// The running app's version (pubspec's, e.g. "0.5.2"), set by main() from
/// the platform. Sent as X-App-Version on every request; null in tests.
String? runningAppVersion;

/// Set when the backend refused this version (426), or the version check
/// found it unsupported: MainApp then shows only UpdateRequiredScreen.
final updateRequiredNotifier = ValueNotifier<AppVersionPolicy?>(null);

/// Negative if [a] is older than [b], zero if equal, positive if newer.
/// "0.5.2+502" compares as 0.5.2; a part that isn't a number counts as 0.
int compareVersions(String a, String b) {
  List<int> parts(String v) => v
      .split('+')
      .first
      .split('-')
      .first
      .split('.')
      .map((p) => int.tryParse(p.trim()) ?? 0)
      .toList();
  final x = parts(a);
  final y = parts(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

AppVersionStatus appVersionStatus(String running, AppVersionPolicy policy) {
  if (compareVersions(running, policy.minSupported) < 0) {
    return AppVersionStatus.unsupported;
  }
  if (compareVersions(running, policy.latest) < 0) {
    return AppVersionStatus.deprecated;
  }
  return AppVersionStatus.current;
}
