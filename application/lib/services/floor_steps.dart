/// A floor change on a route: guidance sends the user from one floor to
/// [floor], and picks up again at waypoint [lastIndex].
typedef FloorChange = ({int lastIndex, int floor});

/// The floor change right after waypoint [index] of a route whose waypoints
/// are on [floors], or null if the next waypoint is on the same floor.
/// Consecutive hops are one step: an elevator stopping at floors 1, 2 and 3 on
/// the map is one ride to floor 3.
FloorChange? floorChangeAfter(List<int> floors, int index) {
  if (index < 0 || index + 1 >= floors.length) return null;
  if (floors[index + 1] == floors[index]) return null;
  var last = index + 1;
  while (last + 1 < floors.length && floors[last + 1] != floors[last]) {
    last++;
  }
  return (lastIndex: last, floor: floors[last]);
}
