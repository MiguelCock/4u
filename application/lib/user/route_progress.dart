import 'package:latlong2/latlong.dart';

import '../services/floor_detector.dart';
import '../services/floor_steps.dart';
import '../services/geo_utils.dart';
import '../services/trip_plan.dart';
import '../services/turn_guidance.dart';

/// Where the trip is along its route (Phase C): which stop is next, which
/// floor guidance believes the user is on, and the floor change being
/// waited for. It decides what was reached; the trip screen says it.
///
/// GPS can't tell floors apart, so a stop on another floor than [floor] is
/// never reached: a floor change gets the user there, heard by the
/// barometer ([detector]) or given up on after a while.
class RouteProgress {
  /// Raw GPS has to be this close (meters) to a waypoint before guidance
  /// may skip ahead to it - roughly GPS's own typical accuracy.
  static const proximityMeters = 20.0;

  /// A corner counts as reached this close (meters), or once the user has
  /// walked to within this of its end along the straight leading to it, or
  /// has already turned onto the next leg near it (see cornerProgress). It
  /// was 20 m, then 8 m: with the position good to ~1 m, 8 m still spoke
  /// every turn 5-8 s before the corner (third test walk).
  static const cornerMeters = 3.0;

  /// This far (meters) before a corner: "In 8 meters, turn left", once.
  static const turnWarningMeters = 8.0;

  /// No heads-up on a leg shorter than this: it would follow straight on
  /// from the leg's own instruction.
  static const minLegForWarningMeters = 12.0;

  /// ...but not if they're this far (meters) to the side of that straight.
  static const cornerCrossTrackMeters = 15.0;

  /// Arriving needs the corrected position within [arrivalRadius] of the
  /// destination *and* raw GPS within that plus [arrivalRawGpsSlackMeters],
  /// on [arrivalConfirmTicks] guidance ticks in a row. A field test ended
  /// the trip ~40 m early: photo matches on the destination pulled the
  /// corrected position inside 20 m while the user was still far away.
  static const arrivalRawGpsSlackMeters = 10.0;
  static const arrivalConfirmTicks = 2;

  /// A floor change comes from the barometer. If nothing is heard by this
  /// long after the instruction, or this long per floor on a phone without
  /// one, the trip carries on rather than going silent for good.
  static const floorWaitLimit = Duration(minutes: 3);
  static const noBarometerWaitPerFloor = Duration(seconds: 60);

  List<Waypoint> _waypoints = const [];
  LatLng? _startPoint;
  int _startFloor = 0;
  int? _startHazard;

  int _next = 0;
  int _floor = 0;
  int _arrivalStreak = 0;
  int? _warnedFor;
  FloorChange? _floorChange;
  DateTime? _floorWaitSince;
  bool _startFloorChecked = false;

  /// Hears the floor change; the trip feeds it every barometer reading.
  final detector = FloorChangeDetector();

  /// The first instruction (or the first after a floor change, when
  /// nothing says which way the user faces) is still to be said.
  bool needsStartCue = false;

  List<Waypoint> get waypoints => _waypoints;
  LatLng? get startPoint => _startPoint;

  /// The next stop's index in [waypoints].
  int get next => _next;

  /// The floor guidance believes the user is on (0-based).
  int get floor => _floor;

  /// The floor change being waited for, if any. Guidance is paused meanwhile.
  FloorChange? get floorChange => _floorChange;
  bool get waitingForFloor => _floorChange != null;

  /// Every stop reached: nothing left to guide to.
  bool get done => _next >= _waypoints.length;

  /// The stop being walked to.
  Waypoint get target => _waypoints[_next];

  /// Where the segment being walked starts: the previous waypoint, or the
  /// route's start for the first one.
  LatLng? get segmentStart =>
      _next == 0 ? _startPoint : _waypoints[_next - 1].point;

  /// The route, once its points are loaded.
  void load(TripPlan plan) {
    _startPoint = plan.startPoint;
    if (plan.floors.isNotEmpty) {
      _startFloor = plan.startFloor!;
      _floor = plan.startFloor!;
      _startHazard = plan.startHazard;
    }
    _waypoints = plan.waypoints;
  }

  /// A resumed trip: aimed at the stop nearest [here], on that stop's floor
  /// (GPS can't tell). The skip-ahead in [reach] takes it from there.
  void resumeNear(LatLng here) {
    if (_waypoints.isEmpty) return;
    final nearest = resumeWaypointIndex(here, _waypoints);
    _next = nearest;
    _floor = _waypoints[nearest].floor;
    _startFloorChecked = true;
  }

  /// Once, as guidance starts: a route starting at the foot of the stairs
  /// begins with that floor change.
  FloorWait? checkStartFloor(DateTime now) {
    if (_startFloorChecked) return null;
    _startFloorChecked = true;
    final change = _floorChangeAfter(-1);
    return change == null ? null : _beginFloorChange(-1, change, now);
  }

  /// Waypoint progress from [here] (the position guidance uses) and [raw]
  /// GPS. Reaching any upcoming waypoint counts, not only the next one, so a
  /// noisy fix that skips past a point doesn't leave guidance stuck waiting
  /// for it. Null when nothing was reached.
  ///
  /// [heading] is the trusted heading, or null: only it may say "already
  /// turned" at a corner.
  Reach? reach({
    required LatLng here,
    required LatLng? raw,
    required double gpsAccuracy,
    required double? heading,
    required DateTime now,
  }) {
    final last = _waypoints.length - 1;
    final lastLegFrom = last > 0 ? _waypoints[last - 1].point : _startPoint;
    final arrivalMeters = arrivalRadius(
      gpsAccuracy: gpsAccuracy,
      lastLegMeters: lastLegFrom == null
          ? null
          : haversineMeters(lastLegFrom, _waypoints[last].point),
    );
    var reached = -1;
    for (var i = _next; i < _waypoints.length; i++) {
      // GPS can't tell floors apart: the point above can't be reached,
      // skipped to or arrived at from here.
      if (_waypoints[i].floor != _floor) break;
      final point = _waypoints[i].point;
      if (i < last && !_cornerReached(here, i, heading)) continue;
      if (i == last && haversineMeters(here, point) > proximityMeters) {
        continue;
      }
      // Skipping past the next waypoint (or arriving) on the strength of
      // the corrected position alone let one bad photo match jump the trip
      // forward: raw GPS has to agree too.
      final skips = i > _next || i == last;
      if (i > _next &&
          i < last &&
          (raw == null ||
              !maySkipTo(
                metersToNext: haversineMeters(raw, _waypoints[_next].point),
                metersToLater: haversineMeters(raw, point),
                maxMeters: proximityMeters,
              ))) {
        continue;
      }
      if (skips &&
          (raw == null ||
              haversineMeters(raw, point) >
                  (i == last
                      ? arrivalMeters + arrivalRawGpsSlackMeters
                      : proximityMeters))) {
        continue;
      }
      if (i == last && haversineMeters(here, point) > arrivalMeters) {
        continue;
      }
      reached = i;
    }
    if (reached == last) {
      _arrivalStreak++;
      if (_arrivalStreak < arrivalConfirmTicks) return null;
    } else {
      _arrivalStreak = 0;
    }
    if (reached == -1) return null;
    final skipped = reached - _next;
    if (reached == last) return ReachedEnd(index: reached, skipped: skipped);
    _next = reached + 1;
    final change = _floorChangeAfter(reached);
    if (change != null) {
      return ReachedFloorChange(
        index: reached,
        skipped: skipped,
        wait: _beginFloorChange(reached, change, now),
      );
    }
    return ReachedCorner(
      index: reached,
      skipped: skipped,
      previous: reached == 0 ? _startPoint : _waypoints[reached - 1].point,
      from: _waypoints[reached],
      to: _waypoints[_next],
    );
  }

  /// While waiting at a floor change: has the barometer heard it, or has
  /// the wait run out? Then guidance picks up from the far end. Null while
  /// still waiting.
  FloorDone? checkFloorChange({
    required bool barometerSeen,
    required DateTime now,
  }) {
    final change = _floorChange!;
    final waited = now.difference(_floorWaitSince!);
    final detected = detector.reached;
    final limit = barometerSeen
        ? floorWaitLimit
        : noBarometerWaitPerFloor * (change.floor - _floor).abs();
    if (!detected && waited < limit) return null;
    final delta = detector.delta;
    _floorChange = null;
    detector.stop();
    _floor = change.floor;
    final arrived = change.lastIndex == _waypoints.length - 1;
    if (!arrived) {
      _next = change.lastIndex + 1;
      _arrivalStreak = 0;
      // Off the stairs, nothing says which way the user faces.
      needsStartCue = true;
    }
    return (
      detected: detected,
      floor: change.floor,
      waited: waited,
      deltaHpa: delta,
      arrived: arrived,
    );
  }

  /// About [turnWarningMeters] before a corner, once per corner: the hazard
  /// there, and the turn, so the instruction at the corner itself doesn't
  /// come as a surprise. Null when there's nothing to warn of yet.
  AheadWarning? warnAhead(LatLng here, {required double? heading}) {
    final i = _next;
    if (_warnedFor == i ||
        cornerProgressAt(here, heading: heading) != CornerProgress.warn) {
      return null;
    }
    _warnedFor = i;
    final from = segmentStart!;
    final corner = _waypoints[i].point;
    final meters = haversineMeters(here, corner);
    final hazard = _waypoints[i].hazardType;
    double? turn;
    if (_waypoints[i + 1].floor == _waypoints[i].floor) {
      final bend = signedTurn(
        bearingDegrees(from, corner),
        bearingDegrees(corner, _waypoints[i + 1].point),
      );
      if (haversineMeters(from, corner) >= minLegForWarningMeters &&
          bend.abs() > TurnGuidance.alignedDegrees) {
        turn = bend;
      }
    }
    if (hazard == null && turn == null) return null;
    return (hazardType: hazard, metersToCorner: meters, turn: turn);
  }

  /// Progress toward the next waypoint when it's a corner (not the
  /// destination), or null.
  CornerProgress? cornerProgressAt(LatLng here, {required double? heading}) {
    final i = _next;
    final from = segmentStart;
    if (from == null || i >= _waypoints.length - 1) return null;
    final corner = _waypoints[i].point;
    final projection = projectOntoSegment(here, from, corner);
    if (projection.length <= 0) return null;
    return cornerProgress(
      metersToCorner: haversineMeters(here, corner),
      alongRemaining: projection.length - projection.along,
      crossTrack: projection.crossTrack,
      // Only a heading that can be trusted may say "already turned": the
      // raw compass made corners come early in a user test.
      heading: heading,
      legBearing: bearingDegrees(from, corner),
      // The next waypoint is on another floor, nearly overhead: no bearing.
      nextLegBearing: _waypoints[i + 1].floor != _waypoints[i].floor
          ? null
          : bearingDegrees(corner, _waypoints[i + 1].point),
      reachedMeters: cornerMeters,
      warnMeters: turnWarningMeters,
      maxCrossTrackMeters: cornerCrossTrackMeters,
    );
  }

  /// Whether intermediate waypoint [i] counts as reached from [here]: close
  /// to it, or - for the next one - walked up to along its straight.
  bool _cornerReached(LatLng here, int i, double? heading) {
    if (haversineMeters(here, _waypoints[i].point) <= cornerMeters) {
      return true;
    }
    return i == _next &&
        cornerProgressAt(here, heading: heading) == CornerProgress.reached;
  }

  /// The floor change right after waypoint [index] (-1: the route's start),
  /// with [FloorChange.lastIndex] as a waypoint index.
  FloorChange? _floorChangeAfter(int index) {
    final change = floorChangeAfter([
      _startFloor,
      for (final waypoint in _waypoints) waypoint.floor,
    ], index + 1);
    return change == null
        ? null
        : (lastIndex: change.lastIndex - 1, floor: change.floor);
  }

  /// At the foot of the stairs (waypoint [from], -1: the route's start):
  /// guidance now waits for the barometer ([checkFloorChange]).
  FloorWait _beginFloorChange(int from, FloorChange change, DateTime now) {
    final floors = change.floor - _floor;
    _floorChange = change;
    _floorWaitSince = now;
    detector.start(floors, now: now);
    return (
      fromFloor: _floor,
      toFloor: change.floor,
      hazardTypes: {
        from < 0 ? _startHazard : _waypoints[from].hazardType,
        _waypoints[change.lastIndex].hazardType,
      },
    );
  }
}

/// A floor change begun: from and to which floor (0-based), and the
/// stairwell, elevator or ramp at either end (null where there's none).
typedef FloorWait = ({int fromFloor, int toFloor, Set<int?> hazardTypes});

/// A floor change over: heard by the barometer or given up on after
/// [waited]; [arrived] when its far end is the destination.
typedef FloorDone = ({
  bool detected,
  int floor,
  Duration waited,
  double? deltaHpa,
  bool arrived,
});

/// What to warn of before a corner: the hazard there and the turn (signed
/// degrees, right positive), each null when there's none to say.
typedef AheadWarning = ({int? hazardType, double metersToCorner, double? turn});

/// A stop reached: waypoint [index], [skipped] stops past the one aimed at.
sealed class Reach {
  const Reach({required this.index, required this.skipped});
  final int index;
  final int skipped;
}

/// The destination.
final class ReachedEnd extends Reach {
  const ReachedEnd({required super.index, required super.skipped});
}

/// The foot of a floor change, which has begun ([wait]).
final class ReachedFloorChange extends Reach {
  const ReachedFloorChange({
    required super.index,
    required super.skipped,
    required this.wait,
  });
  final FloorWait wait;
}

/// A corner or named place: the next leg goes [from] it [to] the next stop,
/// after arriving from [previous].
final class ReachedCorner extends Reach {
  const ReachedCorner({
    required super.index,
    required super.skipped,
    required this.previous,
    required this.from,
    required this.to,
  });
  final LatLng? previous;
  final Waypoint from;
  final Waypoint to;
}
