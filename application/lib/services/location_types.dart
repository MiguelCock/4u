import '../l10n/app_localizations.dart';
import 'destination_matcher.dart' show normalizeForMatch;

/// Groups for the type picker, shown in this order. App-only: nothing about
/// a category is stored, each type keeps its own id in `location_type`.
enum LocationCategory {
  paths,
  gettingAround,
  academic,
  services,
  wellbeing,
  other,
}

class LocationType {
  /// `db_schema/location_type.sql` id, stored in `anchor_points`.
  final int id;

  /// The table's stable `name`, mapped to a localized label for display.
  final String key;
  final LocationCategory category;

  const LocationType(this.id, this.key, this.category);
}

/// Every location type, in picker order: in-between points first (hallway
/// and outdoor path are the ones admins use most while filling in routes),
/// then the kinds of places people go to. Must list exactly the rows of
/// `db_schema/location_type.sql` (a test checks).
const List<LocationType> kLocationTypeCatalog = [
  LocationType(10, 'hallway', LocationCategory.paths),
  LocationType(12, 'outdoor_path', LocationCategory.paths),
  LocationType(2, 'intersection', LocationCategory.paths),
  LocationType(4, 'stairwell', LocationCategory.paths),
  LocationType(3, 'elevator', LocationCategory.paths),
  LocationType(11, 'ramp', LocationCategory.paths),
  LocationType(17, 'crosswalk', LocationCategory.paths),
  LocationType(16, 'courtyard', LocationCategory.paths),
  LocationType(1, 'entrance', LocationCategory.gettingAround),
  LocationType(30, 'exit', LocationCategory.gettingAround),
  LocationType(14, 'lobby', LocationCategory.gettingAround),
  LocationType(13, 'parking', LocationCategory.gettingAround),
  LocationType(31, 'bike_parking', LocationCategory.gettingAround),
  LocationType(18, 'bus_stop', LocationCategory.gettingAround),
  LocationType(32, 'waiting_area', LocationCategory.gettingAround),
  LocationType(5, 'classroom', LocationCategory.academic),
  LocationType(24, 'laboratory', LocationCategory.academic),
  LocationType(23, 'library', LocationCategory.academic),
  LocationType(25, 'computer_room', LocationCategory.academic),
  LocationType(26, 'study_area', LocationCategory.academic),
  LocationType(15, 'auditorium', LocationCategory.academic),
  LocationType(6, 'office', LocationCategory.academic),
  LocationType(8, 'cafeteria', LocationCategory.services),
  LocationType(19, 'stationery_shop', LocationCategory.services),
  LocationType(20, 'copy_center', LocationCategory.services),
  LocationType(21, 'store', LocationCategory.services),
  LocationType(22, 'atm', LocationCategory.services),
  LocationType(7, 'restroom', LocationCategory.services),
  LocationType(33, 'drinking_fountain', LocationCategory.services),
  LocationType(27, 'infirmary', LocationCategory.wellbeing),
  LocationType(28, 'sports_area', LocationCategory.wellbeing),
  LocationType(29, 'chapel', LocationCategory.wellbeing),
  LocationType(9, 'other', LocationCategory.other),
];

/// Id → storage key, in picker order.
final Map<int, String> kLocationTypes = {
  for (final type in kLocationTypeCatalog) type.id: type.key,
};

LocationType? locationTypeById(int? id) {
  for (final type in kLocationTypeCatalog) {
    if (type.id == id) return type;
  }
  return null;
}

/// The localized label for a storage key, without changing what's stored.
String locationTypeLabel(AppLocalizations l10n, String type) {
  return switch (type) {
    'entrance' => l10n.locationTypeEntrance,
    'intersection' => l10n.locationTypeIntersection,
    'elevator' => l10n.locationTypeElevator,
    'stairwell' => l10n.locationTypeStairwell,
    'classroom' => l10n.locationTypeClassroom,
    'office' => l10n.locationTypeOffice,
    'restroom' => l10n.locationTypeRestroom,
    'cafeteria' => l10n.locationTypeCafeteria,
    'hallway' => l10n.locationTypeHallway,
    'ramp' => l10n.locationTypeRamp,
    'outdoor_path' => l10n.locationTypeOutdoorPath,
    'parking' => l10n.locationTypeParking,
    'lobby' => l10n.locationTypeLobby,
    'auditorium' => l10n.locationTypeAuditorium,
    'courtyard' => l10n.locationTypeCourtyard,
    'crosswalk' => l10n.locationTypeCrosswalk,
    'bus_stop' => l10n.locationTypeBusStop,
    'stationery_shop' => l10n.locationTypeStationeryShop,
    'copy_center' => l10n.locationTypeCopyCenter,
    'store' => l10n.locationTypeStore,
    'atm' => l10n.locationTypeAtm,
    'library' => l10n.locationTypeLibrary,
    'laboratory' => l10n.locationTypeLaboratory,
    'computer_room' => l10n.locationTypeComputerRoom,
    'study_area' => l10n.locationTypeStudyArea,
    'infirmary' => l10n.locationTypeInfirmary,
    'sports_area' => l10n.locationTypeSportsArea,
    'chapel' => l10n.locationTypeChapel,
    'exit' => l10n.locationTypeExit,
    'bike_parking' => l10n.locationTypeBikeParking,
    'waiting_area' => l10n.locationTypeWaitingArea,
    'drinking_fountain' => l10n.locationTypeDrinkingFountain,
    'other' => l10n.locationTypeOther,
    _ => type,
  };
}

String locationCategoryLabel(AppLocalizations l10n, LocationCategory category) {
  return switch (category) {
    LocationCategory.paths => l10n.locationCategoryPaths,
    LocationCategory.gettingAround => l10n.locationCategoryGettingAround,
    LocationCategory.academic => l10n.locationCategoryAcademic,
    LocationCategory.services => l10n.locationCategoryServices,
    LocationCategory.wellbeing => l10n.locationCategoryWellbeing,
    LocationCategory.other => l10n.locationCategoryOther,
  };
}

/// Types whose label or category matches [query], accent- and
/// case-insensitive ("pape" finds Papelería), in catalog order. An empty
/// query returns every type.
List<LocationType> searchLocationTypes(AppLocalizations l10n, String query) {
  final needle = normalizeForMatch(query);
  if (needle.isEmpty) return kLocationTypeCatalog;
  return [
    for (final type in kLocationTypeCatalog)
      if (normalizeForMatch(
        '${locationTypeLabel(l10n, type.key)} '
        '${locationCategoryLabel(l10n, type.category)} ${type.key}',
      ).contains(needle))
        type,
  ];
}

/// What admin screens call an anchor point: its description, or, for an
/// unnamed in-between point, its location type plus a short id so several
/// "Hallway" points can still be told apart.
String anchorDisplayName(AppLocalizations l10n, Map<String, dynamic>? point) {
  final description = (point?['location_description'] as String? ?? '').trim();
  if (description.isNotEmpty) return description;
  final id = point?['id'] as String? ?? '?';
  final type = kLocationTypes[point?['location_type_id'] as int?];
  final shortId = id.length > 4 ? id.substring(0, 4) : id;
  return type == null ? shortId : '${locationTypeLabel(l10n, type)} · $shortId';
}
