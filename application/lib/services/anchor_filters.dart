import 'location_types.dart';

/// Metadata filters for the admin Anchor points list and map. Every field
/// null means "any"; filters combine (all must match). Pure, so the
/// matching rules are unit-tested.
class AnchorFilters {
  final LocationCategory? category;
  final int? locationTypeId;
  final int? floor;

  /// 'indoor', 'outdoor' or 'unset' (no indoor value recorded).
  final String? indoor;

  /// 'bright', 'moderate', 'dim' or 'unset'.
  final String? lighting;
  final bool? hasPhotos;
  final bool? hasConnections;

  const AnchorFilters({
    this.category,
    this.locationTypeId,
    this.floor,
    this.indoor,
    this.lighting,
    this.hasPhotos,
    this.hasConnections,
  });

  static const none = AnchorFilters();

  /// How many filters are set, for the badge on the Filters button.
  int get activeCount => [
    category,
    locationTypeId,
    floor,
    indoor,
    lighting,
    hasPhotos,
    hasConnections,
  ].where((value) => value != null).length;

  bool get isEmpty => activeCount == 0;

  /// [withPhotos] / [connected]: ids of anchor points that have at least one
  /// photo / connection, computed once from the loaded lists.
  bool matches(
    Map<String, dynamic> point, {
    required Set<String> withPhotos,
    required Set<String> connected,
  }) {
    final typeId = point['location_type_id'] as int?;
    if (locationTypeId != null && typeId != locationTypeId) return false;
    if (category != null && locationTypeById(typeId)?.category != category) {
      return false;
    }
    if (floor != null && (point['floor'] as int? ?? 0) != floor) return false;

    final metadata = (point['metadata'] as Map?) ?? const {};
    if (indoor != null) {
      final value = metadata['indoor'];
      final actual = value == true
          ? 'indoor'
          : value == false
          ? 'outdoor'
          : 'unset';
      if (actual != indoor) return false;
    }
    if (lighting != null &&
        (metadata['lighting'] as String? ?? 'unset') != lighting) {
      return false;
    }

    final id = point['id'] as String?;
    if (hasPhotos != null && withPhotos.contains(id) != hasPhotos) {
      return false;
    }
    if (hasConnections != null && connected.contains(id) != hasConnections) {
      return false;
    }
    return true;
  }

  AnchorFilters copyWith({
    Object? category = _keep,
    Object? locationTypeId = _keep,
    Object? floor = _keep,
    Object? indoor = _keep,
    Object? lighting = _keep,
    Object? hasPhotos = _keep,
    Object? hasConnections = _keep,
  }) {
    T? pick<T>(Object? value, T? current) =>
        identical(value, _keep) ? current : value as T?;
    return AnchorFilters(
      category: pick(category, this.category),
      locationTypeId: pick(locationTypeId, this.locationTypeId),
      floor: pick(floor, this.floor),
      indoor: pick(indoor, this.indoor),
      lighting: pick(lighting, this.lighting),
      hasPhotos: pick(hasPhotos, this.hasPhotos),
      hasConnections: pick(hasConnections, this.hasConnections),
    );
  }
}

const Object _keep = Object();
