import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The values of the last anchor point an admin created on this phone, so
/// the next one starts from them: points are usually captured in a row
/// along one corridor, with the same building, type, floor and conditions.
/// The description and position are never carried over.
class CaptureDefaults {
  static const _key = 'capture_defaults_v1';

  final String? placeId;
  final String? buildingId;
  final int? locationTypeId;
  final int? floor;
  final bool? indoor;
  final String? lighting;
  final String? surface;

  const CaptureDefaults({
    this.placeId,
    this.buildingId,
    this.locationTypeId,
    this.floor,
    this.indoor,
    this.lighting,
    this.surface,
  });

  Map<String, dynamic> toJson() => {
    'place_id': placeId,
    'building_id': buildingId,
    'location_type_id': locationTypeId,
    'floor': floor,
    'indoor': indoor,
    'lighting': lighting,
    'surface': surface,
  };

  factory CaptureDefaults.fromJson(Map<String, dynamic> json) =>
      CaptureDefaults(
        placeId: json['place_id'] as String?,
        buildingId: json['building_id'] as String?,
        locationTypeId: json['location_type_id'] as int?,
        floor: json['floor'] as int?,
        indoor: json['indoor'] as bool?,
        lighting: json['lighting'] as String?,
        surface: json['surface'] as String?,
      );

  /// The saved defaults, or empty ones if none were saved or they can't be
  /// read (never throws: the form just starts blank).
  static Future<CaptureDefaults> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return const CaptureDefaults();
      return CaptureDefaults.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const CaptureDefaults();
    }
  }

  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(toJson()));
    } catch (_) {
      // Remembering is a convenience; a failure must not block creating.
    }
  }
}
