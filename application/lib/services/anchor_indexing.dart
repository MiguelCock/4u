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
