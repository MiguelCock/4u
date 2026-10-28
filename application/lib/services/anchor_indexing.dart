import 'api_service.dart';

/// Builds `backend-ai-training`'s `POST /index_anchor` body for one anchor
/// point. Shared by the edit-screen verify, the add-photo flow and the
/// admin "Re-index verified points" action, so all three send the same
/// shape.
Map<String, dynamic> indexAnchorPayload({
  required String anchorPointId,
  required num latitude,
  required num longitude,
  required String? buildingId,
  required Iterable<Map<String, dynamic>> photos,
}) {
  return {
    'anchor_point_id': anchorPointId,
    'latitude': latitude,
    'longitude': longitude,
    'building_id': buildingId,
    'photos': photos
        .map(
          (p) => {
            'photo_id': p['id'],
            'image_url': p['image_url'],
            'heading': p['heading'],
          },
        )
        .toList(),
  };
}

/// Indexes [anchorPoint] (a `GET /anchor-points` row) with [photos] (its
/// `anchor_point_photos` rows). Qdrant upserts by photo id, so re-running
/// this for an already-indexed point is safe.
Future<void> indexAnchorPoint(
  AiTrainingApi api,
  Map<String, dynamic> anchorPoint,
  Iterable<Map<String, dynamic>> photos,
) {
  return api.post(
    '/index_anchor',
    indexAnchorPayload(
      anchorPointId: anchorPoint['id'] as String,
      latitude: anchorPoint['latitude'] as num,
      longitude: anchorPoint['longitude'] as num,
      buildingId: anchorPoint['building_id'] as String?,
      photos: photos,
    ),
  );
}

/// The photo ids backend-ai-training has indexed (`GET /index_status`), or
/// null if it couldn't say.
Future<Set<String>?> fetchIndexedPhotoIds(AiTrainingApi api) async {
  try {
    final status = await api.get('/index_status');
    final ids = status is Map ? status['photo_ids'] : null;
    return ids is List ? ids.map((id) => '$id').toSet() : null;
  } on ApiException {
    return null;
  }
}

/// Verified [points] with at least one photo, and of those only the ones
/// with a photo missing from [indexedPhotoIds] (all of them when it's
/// null: nothing to compare against). A re-index once left 122 of 298
/// photos out, and only a test walk found it.
List<Map<String, dynamic>> pointsMissingFromIndex(
  Iterable<Map<String, dynamic>> points,
  List<Map<String, dynamic>> Function(String pointId) photosOf,
  Set<String>? indexedPhotoIds,
) => [
  for (final point in points)
    if (point['status'] == 'verified')
      if (photosOf(point['id'] as String) case final photos
          when photos.isNotEmpty &&
              (indexedPhotoIds == null ||
                  photos.any((p) => !indexedPhotoIds.contains('${p['id']}'))))
        point,
];

/// How many photos of verified points aren't in [indexedPhotoIds].
int unsearchablePhotoCount(
  Iterable<Map<String, dynamic>> points,
  List<Map<String, dynamic>> Function(String pointId) photosOf,
  Set<String> indexedPhotoIds,
) => [
  for (final point in points)
    if (point['status'] == 'verified')
      for (final photo in photosOf(point['id'] as String))
        if (!indexedPhotoIds.contains('${photo['id']}')) photo,
].length;
