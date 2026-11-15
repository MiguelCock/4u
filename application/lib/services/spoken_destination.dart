import 'destination_matcher.dart';
import 'destinations.dart';

/// From a phrase to the destinations it may mean (#268): pure, so the
/// order of the rules can be tested without a screen. Came out of
/// `UserHomeScreen._handleSpoken`.

/// Buildings a user can be sent to: active, on the campus they're on (the
/// campus of [startBuildingId], when known). A route can't cross campuses,
/// and every campus has an "Edificio A". Without [activeIds] (not loaded
/// yet), a building's own `is_active` decides.
List<Map<String, dynamic>> campusBuildings(
  List<Map<String, dynamic>> buildings, {
  Set<String>? activeIds,
  Object? startBuildingId,
}) {
  String? campus;
  for (final building in buildings) {
    if (building['id'] == startBuildingId) {
      campus = building['place_id'] as String?;
    }
  }
  return buildings
      .where(
        (b) =>
            (activeIds?.contains(b['id']) ?? b['is_active'] != false) &&
            (campus == null || b['place_id'] == campus),
      )
      .toList();
}

/// The points a phrase can name: destinations ([isDestinationAnchor]) in
/// [buildings], other than the start. With no buildings, any building.
List<Map<String, dynamic>> destinationCandidates(
  List<Map<String, dynamic>> anchors, {
  required List<Map<String, dynamic>> buildings,
  Object? startId,
}) {
  final campus = {for (final b in buildings) b['id']};
  return anchors
      .where(
        (a) =>
            isDestinationAnchor(a) &&
            a['id'] != startId &&
            (campus.isEmpty || campus.contains(a['building_id'])),
      )
      .toList();
}

/// A building as a destination, in the shape of a point: the server picks
/// the door when the route is requested (`end_building_id`).
Map<String, dynamic> wholeBuilding(Map<String, dynamic> building) => {
  'id': 'building:${building['id']}',
  'building_id': building['id'],
  'location_description': building['name'],
  'latitude': building['latitude'],
  'longitude': building['longitude'],
  'whole_building': true,
};

/// How a destination is shown: "Baño · Piso 2 · Edificio C". The floor only
/// when it isn't the ground floor (two "Baño" on different floors have to
/// be told apart), from [floorLabel] (0-based floor in, label out). A
/// whole building is just its name.
String destinationLabel(
  Map<String, dynamic> anchor, {
  required Map<String, String> buildingNames,
  required String Function(int floor) floorLabel,
}) {
  final name = anchor['location_description'] as String? ?? '';
  if (anchor['whole_building'] == true) return name;
  final building = buildingNames[anchor['building_id']];
  final floor = (anchor['floor'] as int?) ?? 0;
  return [
    name,
    if (floor != 0) floorLabel(floor),
    if (building != null && building.isNotEmpty) building,
  ].join(' · ');
}

/// [destinationLabel] to be read aloud.
String spokenLabel(String label) => label.replaceAll(' · ', ', ');

/// What [heard] may mean, best first: one destination to confirm, several
/// to choose from, or none. In order:
/// 1. a place called exactly that (there may be a "Cafetería central" both
///    as a place and as a building), nearest first;
/// 2. a building the phrase names and only names: "Edificio C" means its
///    closest entrance, as a [wholeBuilding]. Saying more ("baño edificio
///    C") is a place in it, below;
/// 3. the places it matches, nearest first, or the clear winner alone.
List<Map<String, dynamic>> resolveSpokenDestination(
  String heard, {
  required List<Map<String, dynamic>> candidates,
  required List<Map<String, dynamic>> buildings,
  required Map<String, String> buildingNames,
  required double Function(Map<String, dynamic> anchor) distance,
}) {
  final exact = exactPlaces(heard, candidates, buildingNames: buildingNames);
  if (exact.isNotEmpty) {
    return nearestFirst([
      for (final place in exact) DestinationMatch(place, 1),
    ], distance).map((m) => m.anchor).toList();
  }
  final buildingMatches = matchBuildings(heard, buildings);
  if (buildingMatches.isNotEmpty) {
    final winner = clearWinner(buildingMatches);
    return winner != null
        ? [wholeBuilding(winner.anchor)]
        : [for (final match in buildingMatches) wholeBuilding(match.anchor)];
  }
  final matches = nearestFirst(
    matchDestinations(heard, candidates, buildingNames: buildingNames),
    distance,
  );
  if (matches.isEmpty) return const [];
  final winner = clearWinner(matches);
  return winner != null
      ? [winner.anchor]
      : matches.map((m) => m.anchor).toList();
}
