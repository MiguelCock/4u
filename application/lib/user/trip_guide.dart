import 'package:clock/clock.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../l10n/app_localizations.dart';
import '../services/buzz.dart';
import '../services/geo_utils.dart';
import '../services/heading_tracker.dart';
import '../services/trip_plan.dart';
import '../services/trip_words.dart';
import '../services/turn_guidance.dart';
import '../voice/trip_announcer.dart';
import 'drift_watch.dart';
import 'leg_progress.dart';
import 'route_progress.dart';
import 'trip_log.dart';

/// Location type of a hallway: a trip starting anywhere else gets the
/// compass direction at once (see _checkStall).
const int _kHallwayType = 10;

/// With no progress, "keep walking" at most this often.
const Duration _kQuietBeforeKeepWalking = Duration(seconds: 30);

/// The periodic "N meters ahead" update is skipped if anything else was
/// said this recently, so it never piles onto a turn instruction.
const Duration _kQuietBeforePeriodic = Duration(seconds: 10);

/// A GPS fix this old advances nothing; this old, it's announced and the
/// stream restarted. A trip ran on a 4-minute-old fix (Icesi, 2026-11-04).
const Duration _kStaleFix = Duration(seconds: 15);
const Duration _kStaleFixAnnounce = Duration(seconds: 25);

/// Below this GPS speed (m/s), GPS heading is meaningless (standing still),
/// so it's only used as a fallback for a missing compass when walking.
const double _kMinSpeedForGpsHeading = 0.7;

/// Drift isn't checked this close to either end of a leg: the corner's own
/// cues speak there, and a leg's line is least certain at its ends.
const double _kDriftEndMeters = 6;

/// A drift cue waits if anything was said this recently.
const Duration _kQuietBeforeDrift = Duration(seconds: 4);

/// A trusted heading this close to the leg's bearing faces the leg, for
/// the movement-based drift (B8, #300).
const double _kFacingLegDeg = 20;

/// A GPS course counts for drift only with accuracy this good (metres),
/// like HeadingTracker's.
const double _kDriftCourseAccuracy = 12;

/// A place beside the route is no longer said this far past it (#227).
const double _kPlaceDropMeters = 10;

/// Nor this close to the next stop, whose own words come first.
const double _kPlaceAwayFromStop = 8;

/// Turn-by-turn guidance for one trip (#269): reaching corners, floor
/// changes and arrival, face-then-walk cues, the stall check, stale GPS and
/// the periodic distance update. Plain Dart: what it needs from the screen
/// comes in as functions, so it runs in unit tests without widgets.
///
/// It came out of `NavigationScreen`, whose State held all of it.
class TripGuide {
  TripGuide({
    required this._route,
    required this._leg,
    required this._tracker,
    required this._compass,
    required this._announcer,
    required this._log,
    required this._l10n,
    required this._position,
    required this._raw,
    required this._lastFix,
    required this._barometerSeen,
    required this._startTypeId,
    required this._pathLoaded,
    required this._destinationName,
    required this._onArrived,
    required this._onChanged,
    required this._restartGps,
    this.declination = -7.5,
    this._adminPreview = false,
    TurnGuidance? guidance,
  }) : _guidance = guidance ?? TurnGuidance();

  final RouteProgress _route;
  final LegProgress _leg;
  final HeadingTracker _tracker;
  final HeadingSmoother _compass;
  final TripAnnouncer _announcer;
  final TripLog _log;
  final AppLocalizations Function() _l10n;

  /// Where guidance thinks the user is (the screen's PositionSource).
  final LatLng? Function() _position;
  final LatLng? Function() _raw;
  final Position? Function() _lastFix;
  final bool Function() _barometerSeen;
  final int? Function() _startTypeId;
  final bool Function() _pathLoaded;
  final String Function() _destinationName;

  /// Arrival on a user's trip (not an admin's test walk): the trip ends.
  final void Function() _onArrived;

  /// Something shown changed (the floor).
  final void Function() _onChanged;
  final void Function() _restartGps;
  final bool _adminPreview;
  final TurnGuidance _guidance;

  /// Magnetic declination (degrees, east positive) - see trueHeading().
  final double declination;

  /// Set once the session has started, cleared when it ends.
  bool guiding = false;
  bool arrived = false;

  /// "Loading the route" was said (the path is slow to arrive).
  bool loadingAnnounced = false;
  bool _gpsStaleAnnounced = false;

  /// The last step's numbers, for the diagnostics.
  double? lastTurn;
  double? lastTargetDistance;
  double? lastTargetBearing;

  /// The trip has started: the first instruction comes with the next step
  /// once the route is loaded ([_speakStartCue]).
  void start() {
    _guidance.reset(now: clock.now());
    guiding = true;
  }

  final _drift = DriftWatch();

  /// A new leg (or the same one, measured again): progress and drift start
  /// over.
  void _newLeg(double? meters) {
    _leg.reset(meters);
    _drift.reset();
  }

  /// Sideways off the leg while walking it, for a while: says which side
  /// (B4, #180). Not near either end, where the corner's own cues speak,
  /// and not over something just said.
  void _checkDrift(LatLng here) {
    if (!_guidance.walking || _route.waitingForFloor) return;
    final from = _segmentStart();
    if (from == null) return;
    final to = _waypoints[_route.next].point;
    final projection = projectOntoSegment(here, from, to);
    if (projection.length < _kDriftEndMeters * 2 ||
        projection.along < _kDriftEndMeters ||
        projection.length - projection.along < _kDriftEndMeters) {
      _drift.reset();
      return;
    }
    final now = clock.now();
    final spoken = _announcer.lastSpokenAt;
    // Not now: the drift's start is kept, so it's said once this is over.
    if (spoken != null && now.difference(spoken) < _kQuietBeforeDrift) return;
    final leg = bearingDegrees(from, to);
    final fix = _lastFix();
    final course =
        fix != null &&
            fix.speed >= _kMinSpeedForGpsHeading &&
            fix.accuracy <= _kDriftCourseAccuracy
        ? fix.heading
        : null;
    final heading = reliableHeading();
    final side = _drift.update(
      projection.crossTrack,
      now,
      courseOff: course == null ? null : signedTurn(leg, course),
      facingLeg:
          heading != null && signedTurn(leg, heading).abs() <= _kFacingLegDeg,
    );
    if (side == null) return;
    final l10n = _l10n();
    _log.event(
      'drift',
      fields: {
        'side': side.name,
        'cross_track_m': projection.crossTrack,
        'gps_course_off': course == null ? null : signedTurn(leg, course),
      },
    );
    _speak(
      side == DriftSide.left ? l10n.navDriftLeft : l10n.navDriftRight,
      cueType: 'drift',
    );
  }

  /// Named places beside the route (#227), nearest the start first; set
  /// once the path has loaded. Each is said once, or dropped once passed.
  List<PlaceBeside> _places = const [];
  List<LatLng> _path = const [];
  int _nextPlace = 0;

  /// The route's whole path and the places beside it (#227).
  void setPlacesBeside(List<LatLng> path, List<PlaceBeside> places) {
    _path = path;
    _places = places;
    _nextPlace = 0;
  }

  /// Says "Pasaste por X" once the user's position along the route is past
  /// a place beside it, while walking (#227). Not over another sentence,
  /// not near a stop, where the stop's own words come; a place left 10 m
  /// behind before there was a moment is dropped.
  void _checkPlacesPassed(LatLng here) {
    if (!_guidance.walking || _nextPlace >= _places.length) return;
    if (_path.length < 2) return;
    final at = alongRoute(_path, here);
    final place = _places[_nextPlace];
    if (at.along < place.along) return;
    if (at.along > place.along + _kPlaceDropMeters) {
      _nextPlace++;
      return;
    }
    final now = clock.now();
    final spoken = _announcer.lastSpokenAt;
    if (spoken != null && now.difference(spoken) < _kQuietBeforeDrift) return;
    final next = _waypoints[_route.next].point;
    if (haversineMeters(here, next) < _kPlaceAwayFromStop) return;
    _nextPlace++;
    _log.event('passed_place', fields: {'name': place.name});
    _speak(_l10n().navPassedPlace(place.name), cueType: 'passed_place');
  }

  /// Whether the user has turned and is walking the leg.
  bool get walking => _guidance.walking;

  List<Waypoint> get _waypoints => _route.waypoints;

  /// Where the segment being walked starts: the previous waypoint, or the
  /// route's start for the first one.
  LatLng? _segmentStart() => _route.segmentStart;

  Future<void> _speak(
    String text, {
    bool assertive = false,
    String cueType = 'info',
    bool repeatable = true,
  }) => _announcer.speak(
    text,
    assertive: assertive,
    cueType: cueType,
    repeatable: repeatable,
  );

  /// Which way the user faces (true north): HeadingTracker's gyro heading
  /// anchored to walking, else the compass, else the GPS direction of
  /// travel while actually moving. Null when none is usable.
  double? currentHeading() {
    final tracked = _tracker.value;
    if (tracked != null) return tracked;
    final compass = _compass.value;
    // The compass is magnetic; route bearings are true north.
    if (compass != null) return trueHeading(compass, declination);
    final position = _lastFix();
    if (position != null && position.speed >= _kMinSpeedForGpsHeading) {
      return position.heading;
    }
    return null;
  }

  /// One guidance step, every half second while guiding: waypoint progress, then face-then-walk cues toward
  /// the next waypoint (see TurnGuidance).
  void step() {
    if (!guiding || arrived) return;
    if (_waypoints.isEmpty && !_pathLoaded()) {
      if (!loadingAnnounced) {
        loadingAnnounced = true;
        _speak(_l10n().navLoadingRoute, repeatable: false);
      }
      return;
    }
    if (_route.done) return;
    if (_route.waitingForFloor) {
      _checkFloorChange();
      return;
    }
    // The route starts at the foot of the stairs.
    if (_route.checkStartFloor(clock.now()) case final wait?) {
      _sayFloorChange(wait);
      return;
    }
    final here = _position();
    if (here == null) return;
    final fix = _lastFix();
    final fixAge = fix == null
        ? Duration.zero
        : clock.now().difference(fix.timestamp);
    if (fixAge >= _kStaleFix) {
      // The position is old news: nothing can be reached on its strength.
      _sayGpsStale(fixAge);
    } else {
      _gpsStaleAnnounced = false;
      if (_checkProximity(here)) return;
      _warnTurnAhead(here);
    }

    if (_route.needsStartCue) _speakStartCue(here);
    _checkStall(here);
    _checkDrift(here);
    _checkPlacesPassed(here);

    final heading = currentHeading();
    if (heading == null) return;
    final target = _waypoints[_route.next].point;
    final segmentStart = _segmentStart();
    // Follow the segment's direction, not the straight line to the
    // waypoint (see guidanceBearing).
    lastTargetBearing = segmentStart == null
        ? bearingDegrees(here, target)
        : guidanceBearing(here, segmentStart, target);
    lastTargetDistance = haversineMeters(here, target);
    lastTurn = signedTurn(heading, lastTargetBearing!);
    final now = clock.now();
    final cue = _guidance.update(
      turn: lastTurn!,
      metersToTarget: lastTargetDistance!,
      now: now,
      reliable: _tracker.reliable(now),
    );
    final l10n = _l10n();
    switch (cue) {
      case TurnCue():
        _speak(turnWords(l10n, cue), cueType: 'turn');
      case StartWalkingCue(:final steps):
        _newLeg(lastTargetDistance);
        _speak(l10n.navGoStraightSteps(steps), cueType: 'start_walking');
      case SlowTurnCue():
        _speak(l10n.navSlowTurn, cueType: 'slow_turn');
      case null:
        break;
    }
  }

  /// The heading, only when it can be trusted (see HeadingTracker.reliable).
  double? reliableHeading() =>
      _tracker.reliable(clock.now()) ? _tracker.value : null;

  /// The first instruction, once the route is loaded. With a heading that
  /// can be trusted it's face-then-walk (TurnGuidance); without one there's
  /// no knowing which way the user faces, so they're told to walk and the
  /// walking direction takes it from there.
  void _speakStartCue(LatLng here) {
    _route.needsStartCue = false;
    _speakLegNotes(_waypoints[_route.next]);
    _newLeg(haversineMeters(here, _waypoints[_route.next].point));
    if (reliableHeading() != null) {
      _guidance.reset(now: clock.now());
      return;
    }
    // A hallway leads the way; a plaza doesn't, and "walk forward" there left
    // people standing at the start (Icesi, 2026-11-05).
    if (_startTypeId() != _kHallwayType && _speakCompassDirection(here)) {
      _guidance.reset(now: clock.now(), walking: true);
      return;
    }
    _speak(
      _l10n().navWalkForward(
        roundSteps(haversineMeters(here, _waypoints[_route.next].point)),
      ),
      cueType: 'start_walking',
    );
    _guidance.reset(now: clock.now(), walking: true);
  }

  /// "Turn left and walk about N steps", from the compass to this stretch's
  /// own direction (the position is too noisy to aim from). The last resort
  /// when there's no trusted heading and nothing else says which way: a
  /// compass can be far off, so it's never used for corners. Returns false
  /// without a compass reading.
  bool _speakCompassDirection(LatLng here) {
    final compass = _compass.value;
    if (compass == null) return false;
    final target = _waypoints[_route.next].point;
    final from = _segmentStart();
    final bearing = from == null || haversineMeters(from, target) < 1
        ? bearingDegrees(here, target)
        : bearingDegrees(from, target);
    final turn = signedTurn(trueHeading(compass, declination), bearing);
    final steps = roundSteps(haversineMeters(here, target));
    final l10n = _l10n();
    _log.event(
      'stall',
      fields: {'compass': compass, 'bearing': bearing, 'turn': turn},
    );
    final String text;
    if (turn.abs() <= TurnGuidance.alignedDegrees) {
      text = l10n.navContinueStraightSteps(steps);
    } else {
      text = legWords(l10n, TurnCue.from(turn), steps);
    }
    _speak(text, cueType: 'turn');
    return true;
  }

  /// Tracks real progress to the next stop. With none for a while and no
  /// trusted heading, nothing else would speak: says which way to go by the
  /// compass, or else to keep walking.
  void _checkStall(LatLng here) {
    final meters = haversineMeters(here, _waypoints[_route.next].point);
    if (!_leg.stalled(meters, trustedHeading: reliableHeading() != null)) {
      return;
    }
    if (!_speakCompassDirection(here)) _sayKeepWalking(meters);
  }

  void _sayKeepWalking(double meters) {
    _speak(_l10n().navKeepWalking(roundSteps(meters)), cueType: 'stall');
  }

  /// GPS has stopped answering: said once, and its stream is started again.
  void _sayGpsStale(Duration age) {
    if (_gpsStaleAnnounced || age < _kStaleFixAnnounce) return;
    _gpsStaleAnnounced = true;
    _log.event('gps_stale', fields: {'age_s': age.inSeconds});
    _speak(_l10n().homeSearchingLocation, repeatable: false);
    _restartGps();
  }

  /// Waypoint progress ([RouteProgress.reach]), said. Returns true when
  /// something was announced.
  bool _checkProximity(LatLng here) {
    final reach = _route.reach(
      here: here,
      raw: _raw(),
      gpsAccuracy: _lastFix()?.accuracy ?? 10,
      heading: reliableHeading(),
      now: clock.now(),
    );
    if (reach == null) return false;
    _log.event(
      reach is ReachedEnd ? 'arrival' : 'waypoint',
      fields: {'index': reach.index, 'skipped': reach.skipped},
    );
    switch (reach) {
      case ReachedEnd():
        _arrive();
      case ReachedFloorChange(:final wait):
        _sayFloorChange(wait);
      case ReachedCorner(:final previous, :final from, :final to):
        _announceNextLeg(previous, from, to);
    }
    return true;
  }

  /// At the foot of the stairs: which way to go. Guidance then waits for the
  /// barometer ([_checkFloorChange]).
  void _sayFloorChange(FloorWait wait) {
    final l10n = _l10n();
    final action = floorChangeAction(
      l10n,
      types: wait.hazardTypes,
      up: wait.toFloor > wait.fromFloor,
      floor: wait.toFloor + 1,
    );
    _log.event(
      'floor_wait',
      at: clock.now(),
      fields: {
        'from': wait.fromFloor,
        'to': wait.toFloor,
        'pressure_hpa': _route.detector.pressure,
        'barometer': _barometerSeen(),
      },
    );
    _speak(
      '$action ${_barometerSeen() ? l10n.navFloorWillTell : l10n.navFloorNoSensor}',
      cueType: 'floor',
    );
  }

  /// While waiting at a floor change: once it's heard or given up on, says
  /// so, and guidance picks up from the far end.
  void _checkFloorChange() {
    final now = clock.now();
    final done = _route.checkFloorChange(
      barometerSeen: _barometerSeen(),
      now: now,
    );
    if (done == null) return;
    _log.event(
      done.detected ? 'floor_detected' : 'floor_timeout',
      at: now,
      fields: {
        'to': done.floor,
        'seconds': done.waited.inSeconds,
        'delta_hpa': done.deltaHpa,
      },
    );
    final l10n = _l10n();
    buzz(Buzz.long);
    _speak(
      done.detected
          ? l10n.navFloorReached(done.floor + 1)
          : l10n.navFloorTimeout(done.floor + 1),
      cueType: 'floor',
    );
    _onChanged();
    if (done.arrived) {
      _arrive();
      return;
    }
    _newLeg(null);
  }

  /// "In 8 meters, turn left", and the hazard there, once per corner
  /// ([RouteProgress.warnAhead]).
  void _warnTurnAhead(LatLng here) {
    final warning = _route.warnAhead(here, heading: reliableHeading());
    if (warning == null) return;
    final l10n = _l10n();
    final steps = roundSteps(warning.metersToCorner);
    if (warning.hazardType case final hazard?) {
      _speak(
        l10n.navHazardAhead(hazardLabel(l10n, hazard), steps),
        cueType: 'hazard',
      );
    }
    if (warning.turn case final turn?) {
      _speak(
        turn > 0
            ? l10n.navTurnAheadRightSteps(steps)
            : l10n.navTurnAheadLeftSteps(steps),
        cueType: 'turn_ahead',
      );
    }
  }

  /// "Attention: three steps down" - the admins' warnings on the leg that
  /// ends at [to], said as it starts.
  void _speakLegNotes(Waypoint to) {
    final l10n = _l10n();
    for (final note in to.legNotes) {
      _speak(l10n.navLegWarning(note), cueType: 'hazard');
    }
  }

  /// At a waypoint: one sentence for what to do next. "At the cafeteria,
  /// turn right and walk about 20 steps", or "go straight, about 30
  /// steps". The turn comes from the route itself (the bend between the two
  /// legs), not the phone's heading, which can be far off; the steps are the
  /// leg's length. A user who has already turned (by a trusted heading) just
  /// hears "go straight".
  void _announceNextLeg(LatLng? previous, Waypoint from, Waypoint to) {
    final l10n = _l10n();
    final steps = roundSteps(haversineMeters(from.point, to.point));
    final nextBearing = bearingDegrees(from.point, to.point);
    final routeTurn = previous == null
        ? 0.0
        : signedTurn(bearingDegrees(previous, from.point), nextBearing);
    final heading = reliableHeading();
    final alreadyTurned =
        heading != null &&
        signedTurn(heading, nextBearing).abs() <= TurnGuidance.alignedDegrees;
    final String action;
    if (routeTurn.abs() <= kCornerTurnDegrees || alreadyTurned) {
      action = l10n.navContinueStraightSteps(steps);
    } else {
      action = legWords(l10n, TurnCue.from(routeTurn), steps);
    }
    final name = from.name;
    _speak(
      name == null ? action : '${l10n.navAtPlace(name)} $action',
      cueType: 'leg',
    );
    _speakLegNotes(to);
    _newLeg(haversineMeters(from.point, to.point));
    // Walking: the user turns as told, and is corrected (once) only if a
    // trusted heading shows them going the wrong way.
    _guidance.reset(now: clock.now(), walking: true);
  }

  /// Within range of the destination: say so and finish the trip on its
  /// own - no need to find the End button.
  void _arrive() {
    if (arrived) return;
    arrived = true;
    final l10n = _l10n();
    if (_adminPreview) {
      // Test walk: keep the session open so the destination checkpoint
      // shows where the user really was when arrival fired.
      _speak(
        l10n.navArrivedTestWalk(_destinationName()),
        assertive: true,
        cueType: 'arrival',
      );
      return;
    }
    _speak(
      l10n.navArrivedFinished(_destinationName()),
      assertive: true,
      cueType: 'arrival',
    );
    _onArrived();
  }

  /// While walking a leg, a short "N meters ahead" every
  /// `_kPeriodicAnnouncementInterval` fills long silent stretches - but
  /// only if nothing else was said recently, and never while the user is
  /// still turning.
  void periodic() {
    if (!guiding || arrived) return;
    if (!_guidance.walking || _route.next >= _waypoints.length) return;
    if (_route.waitingForFloor) return;
    final lastSpoken = _announcer.lastSpokenAt;
    if (lastSpoken != null &&
        clock.now().difference(lastSpoken) < _kQuietBeforePeriodic) {
      return;
    }
    final here = _position();
    if (here == null) return;
    final distance = haversineMeters(here, _waypoints[_route.next].point);
    if (distance <= RouteProgress.proximityMeters) return;
    final l10n = _l10n();
    switch (_leg.update(distance)) {
      case LegUpdate.keepWalking:
        // Not getting closer: "N steps to go" as if it were progress doesn't
        // help, but neither did the silence (Icesi, 2026-11-05).
        final spoken = _announcer.lastSpokenAt;
        if (spoken == null ||
            clock.now().difference(spoken) >= _kQuietBeforeKeepWalking) {
          _sayKeepWalking(distance);
        }
        return;
      case LegUpdate.quiet:
        return;
      case LegUpdate.stepsAhead:
        // On the line: say so (B4). Testers walking well heard nothing and
        // didn't know whether they were.
        _speak(
          _drift.onPath
              ? l10n.navOnTrackStepsAhead(roundSteps(distance))
              : l10n.navStepsAhead(roundSteps(distance)),
          cueType: 'meters_ahead',
        );
      case LegUpdate.away:
        _speak(l10n.navMovingAway, cueType: 'away');
        _turnBackTowardTarget(here);
    }
  }

  /// After "you're moving away": with a trusted heading, face-then-walk
  /// takes over (TurnGuidance orients again); otherwise, while walking,
  /// the GPS direction of travel says which way to turn.
  void _turnBackTowardTarget(LatLng here) {
    final now = clock.now();
    if (reliableHeading() != null) {
      _guidance.reset(now: now);
      return;
    }
    final position = _lastFix();
    final segmentStart = _segmentStart();
    if (position == null ||
        position.speed < _kMinSpeedForGpsHeading ||
        segmentStart == null) {
      return;
    }
    final turn = signedTurn(
      position.heading,
      guidanceBearing(here, segmentStart, _waypoints[_route.next].point),
    );
    if (turn.abs() <= TurnGuidance.alignedDegrees) return;
    final l10n = _l10n();
    _speak(turnWords(l10n, TurnCue.from(turn)), cueType: 'turn');
  }
}
