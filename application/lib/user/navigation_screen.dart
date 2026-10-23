import 'dart:async';
import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as path;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../location.dart';
import '../map.dart';
import '../services/api_service.dart';
import '../services/app_preferences.dart';
import '../services/camera_helper.dart';
import '../services/destinations.dart';
import '../services/geo_utils.dart';
import '../services/image_utils.dart';
import '../services/location_service.dart';
import '../services/speech_voice.dart';
import '../services/turn_guidance.dart';
import '../services/api_error_messages.dart';

/// A resolved checkpoint along the planned route: an anchor point's
/// coordinates, plus its name only when it's a named destination-type
/// point. Unnamed in-between points (hallways...) are never spoken, so
/// guidance is just directions: "turn left about 45 degrees, then walk 12
/// meters".
class _Waypoint {
  final LatLng point;
  final String? name;

  const _Waypoint({required this.point, this.name});
}

/// A corrected position older than this is ignored in favour of raw GPS,
/// e.g. when the camera loop has stalled.
const Duration _kCorrectionFreshness = Duration(seconds: 5);

/// Below this GPS speed (m/s), GPS heading is meaningless (standing still),
/// so it's only used as a fallback for a missing compass when walking.
const double _kMinSpeedForGpsHeading = 0.7;

/// How often turn guidance re-evaluates heading vs bearing. Independent of
/// the ~1s camera-correction loop, which can run slower.
const Duration _kGuidanceInterval = Duration(milliseconds: 500);

/// Raw GPS has to be this close (meters) to a waypoint before guidance
/// may skip ahead to it - roughly GPS's own typical accuracy.
const double _kProximityThresholdMeters = 20.0;

/// A corner counts as reached this close (meters), or once the user has
/// walked to within this of its end along the straight leading to it. It
/// used to be 20 m like the skip check, which announced every turn
/// ~15 m early (a field test, with GPS at 3 m accuracy).
const double _kCornerMeters = 8.0;

/// ...but not if they're this far (meters) to the side of that straight.
const double _kCornerCrossTrackMeters = 15.0;

/// Arriving needs the corrected position this close to the destination
/// *and* raw GPS within [_kArrivalRawGpsMeters], on
/// [_kArrivalConfirmTicks] guidance ticks in a row. A field test ended the
/// trip ~40 m early: photo matches on the destination pulled the corrected
/// position inside 20 m while the user was still far away.
const double _kArrivalMeters = 15.0;
const double _kArrivalRawGpsMeters = 25.0;
const int _kArrivalConfirmTicks = 2;

/// When the correction goes stale, guidance blends from the last corrected
/// position to raw GPS over this long instead of jumping between them.
const Duration _kSourceBlend = Duration(seconds: 2);

/// The periodic "N meters ahead" update is skipped if anything else was
/// said this recently, so it never piles onto a turn instruction.
const Duration _kQuietBeforePeriodic = Duration(seconds: 10);

/// How often (while still outside `_kProximityThresholdMeters` of the next
/// waypoint) to speak an ongoing distance update - real on-device testing
/// of the arrival-only announcements found long silent gaps between them
/// uncomfortable for a user who can't see the screen's corrected-position
/// marker either, so this fills them in without going back to "every ~1s
/// tick" (that was the original, deliberately rejected design - still too
/// frequent to be useful signal rather than noise).
const Duration _kPeriodicAnnouncementInterval = Duration(seconds: 25);

/// How many consecutive ticks must read as blocked (see
/// `services/image_utils.dart`'s `isFrameBlocked`) before the camera is
/// treated as actually covered - debounced so one dim hallway or a brief
/// motion blur doesn't trigger a false alarm.
const int _kCameraBlockedDebounceTicks = 3;

class NavigationScreen extends StatefulWidget {
  final Map<String, dynamic> route;

  /// Continue an existing session (a trip left open by closing the app,
  /// offered on the next launch by UserHomeScreen) instead of starting a
  /// new one.
  final String? resumeSessionId;

  /// The admin's "Test as user" flow: shows the "Wrong instruction" button
  /// that records the last cue for tuning (backend guidance_reports).
  final bool adminPreview;

  const NavigationScreen({
    super.key,
    required this.route,
    this.resumeSessionId,
    this.adminPreview = false,
  });

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  final _navigationApi = NavigationManagementApi();
  final _positioningApi = PositioningApi();
  final _locationService = LocationService();
  final _tts = FlutterTts();
  String? _sessionId;
  CameraController? _cameraController;

  // Self-rescheduling loop, not Timer.periodic: each tick schedules the
  // next one 1s after it *finishes*, not 1s after it started - a
  // POST /correct_position round-trip (camera shutter + CNN embedding +
  // Qdrant search, ~600ms-1s per #122's benchmark) can exceed 1s, and a
  // blind periodic timer would let ticks for the same session_id overlap
  // and queue up behind backend-positioning's per-session lock instead of
  // just running slightly slower.
  Timer? _pendingTickTimer;
  Timer? _periodicAnnouncementTimer;
  Timer? _guidanceTimer;
  StreamSubscription<CompassEvent>? _compassSub;
  final _heading = HeadingSmoother();
  final _guidance = TurnGuidance();
  final _pathLoaded = Completer<void>();
  bool _guiding = false;
  bool _arrived = false;
  DateTime? _correctedAt;
  DateTime? _lastSpokenAt;
  bool _stopped = false;

  /// The route's own start point, where the first segment begins.
  LatLng? _startPoint;
  int _arrivalStreak = 0;
  DateTime? _staleSince;
  LatLng? _staleFrom;

  /// Magnetic declination (degrees, east positive) - see trueHeading().
  final double _declination =
      double.tryParse(dotenv.env['MAGNETIC_DECLINATION'] ?? '') ?? -7.5;

  bool _starting = true;
  bool _ending = false;
  String? _error;

  double? _correctedLat;
  double? _correctedLong;
  double? _correctionError;
  List<LatLng> _plannedPath = [];
  List<_Waypoint> _waypoints = [];
  int _nextWaypointIndex = 0;
  String? _lastHapticAnchorId;
  int _consecutiveBlockedTicks = 0;
  bool _blockedAnnounced = false;
  String? _lastAnnouncement;

  /// What kind of cue [_lastAnnouncement] was (turn, start_walking, leg,
  /// meters_ahead, arrival, start...), for the diagnostics and the admin's
  /// "wrong instruction" reports.
  String? _lastCueType;

  /// Cues spoken and guidance events since the last log, sent with the next
  /// tick's `debug` so the session view can show what was said where.
  final List<Map<String, dynamic>> _pendingCues = [];
  final List<Map<String, dynamic>> _pendingEvents = [];

  /// Latest guidance inputs, kept for the per-tick diagnostics.
  double? _lastRawCompass;
  double? _lastCompassAccuracy;
  double? _lastTurn;
  double? _lastTargetDistance;
  double? _lastTargetBearing;
  bool _lastUsedCorrected = false;

  /// Completes once [_tts] is set to the app language's voice; [_speak]
  /// waits on it so the first announcement isn't read in the phone's
  /// default voice.
  Future<bool>? _ttsReady;
  String? _ttsLanguage;
  bool _voiceMissingShown = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final language = Localizations.localeOf(context).languageCode;
    if (language != _ttsLanguage) {
      _ttsLanguage = language;
      _ttsReady = configureTts(_tts, language)..then(_onTtsConfigured);
    }
  }

  void _onTtsConfigured(bool hasVoice) {
    if (hasVoice || _voiceMissingShown || !mounted) return;
    _voiceMissingShown = true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 10),
        content: Text(AppLocalizations.of(context)!.navVoiceLanguageMissing),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _startSession();
    _initCamera();
    _loadPlannedPath();
    _periodicAnnouncementTimer = Timer.periodic(
      _kPeriodicAnnouncementInterval,
      (_) => _announcePeriodicDistance(),
    );
    _compassSub = FlutterCompass.events?.listen((event) {
      // Android only fills `heading` (see capture_photo_screen.dart).
      final heading = event.heading;
      _lastCompassAccuracy = event.accuracy;
      if (heading != null) {
        _lastRawCompass = heading;
        _heading.add(heading);
      }
    });
    _guidanceTimer = Timer.periodic(_kGuidanceInterval, (_) => _guide());
  }

  /// Speaks [text] if the user has voice guidance on (#39/#40/#85) -
  /// voiceGuidanceNotifier is the same app_preferences.dart pattern
  /// high_contrast/font_scale already use, just read directly here rather
  /// than via a ValueListenableBuilder, since this screen doesn't need to
  /// rebuild when it changes, only to check it at the moment of an
  /// announcement.
  ///
  /// [assertive] mirrors Android's own accessibility live-region model
  /// (a "polite" update waits for the current speech to finish; an
  /// "assertive" one interrupts it) - routine announcements (route start,
  /// periodic distance, approaching/arrived, session end) stay polite and
  /// just queue; safety-relevant ones (a blocked camera) are assertive,
  /// stopping whatever's queued first so they're not buried behind it.
  Future<void> _speak(
    String text, {
    bool assertive = false,
    String cueType = 'info',
  }) async {
    _lastAnnouncement = text;
    _lastCueType = cueType;
    _lastSpokenAt = DateTime.now();
    _pendingCues.add({
      'at': DateTime.now().toUtc().toIso8601String(),
      'type': cueType,
      'text': text,
    });
    if (!voiceGuidanceNotifier.value) return;
    await _ttsReady;
    if (assertive) await _tts.stop();
    await _tts.speak(text);
  }

  /// Re-speaks the most recent announcement on demand (a tap on the map) -
  /// assertive, since the user is explicitly asking to hear it right now.
  /// Also shown as a SnackBar, for anyone with voice guidance or sound off.
  void _repeatLastAnnouncement() {
    final text = _lastAnnouncement;
    if (text == null) return;
    _speak(text, assertive: true, cueType: _lastCueType ?? 'info');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Resolves the route's anchor ids (already in hand from find_or_create,
  /// no need to re-fetch the route itself) into coordinates for the
  /// guidance line (`_plannedPath`, every point including the start) and
  /// into `_waypoints` (every point *except* the start - nothing to
  /// "approach" at the point you're already standing at) for #40's
  /// proximity announcements - same per-id anchor lookup
  /// SessionTrackingScreen's admin-side route overlay already does.
  Future<void> _loadPlannedPath() async {
    final anchorIds = [
      widget.route['start_anchor_id'] as String,
      ...(widget.route['waypoint_anchor_ids'] as List? ?? const [])
          .cast<String>(),
      widget.route['end_anchor_id'] as String,
    ];
    final points = <LatLng>[];
    final names = <String?>[];
    var resolvedStart = false;
    for (var i = 0; i < anchorIds.length; i++) {
      try {
        final anchor =
            await MapManagementApi().get('/anchor-points/${anchorIds[i]}')
                as Map<String, dynamic>;
        final lat = (anchor['latitude'] as num?)?.toDouble();
        final lng = (anchor['longitude'] as num?)?.toDouble();
        if (lat == null || lng == null) continue;
        final point = LatLng(lat, lng);
        points.add(point);
        if (i == 0) {
          _startPoint = point;
          resolvedStart = true;
        }
        final description = (anchor['location_description'] as String? ?? '')
            .trim();
        // The final point is always named when spoken (falling back to
        // "your destination"); in-between ones only if they're a real
        // destination-type place.
        final named =
            i > 0 &&
            description.isNotEmpty &&
            (i == anchorIds.length - 1 || isDestinationAnchor(anchor));
        names.add(named ? description : null);
      } on ApiException {
        // The guidance line/checkpoints are a nice-to-have overlay - a
        // missing/deleted anchor shouldn't block navigation, it just means
        // no line/announcement for that point.
      }
    }
    // Guidance stops at corners (and named places), not at every anchor
    // along a straight - see routeCorners.
    final corners = routeCorners(
      points,
      keep: {
        for (var i = 0; i < names.length; i++)
          if (names[i] != null) i,
      },
    );
    final waypoints = [
      for (final i in corners)
        if (i > 0 || !resolvedStart)
          _Waypoint(point: points[i], name: names[i]),
    ];
    if (mounted) {
      setState(() {
        _plannedPath = points;
        _waypoints = waypoints;
      });
    }
    if (!_pathLoaded.isCompleted) _pathLoaded.complete();
  }

  /// On resume the user is somewhere along the route already: aim guidance
  /// at the waypoint nearest them rather than back at the first one.
  /// _checkProximity's skip-ahead takes it from there.
  void _skipToNearestWaypoint() {
    final here = _currentPosition();
    if (here == null || _waypoints.isEmpty) return;
    var nearest = 0;
    var nearestDistance = double.infinity;
    for (var i = 0; i < _waypoints.length; i++) {
      final distance = haversineMeters(here, _waypoints[i].point);
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = i;
      }
    }
    // Corners can be 40 m apart: if the user is already past the nearest
    // one along the next straight, aim at the corner after it instead of
    // sending them back.
    if (nearest + 1 < _waypoints.length &&
        projectOntoSegment(
              here,
              _waypoints[nearest].point,
              _waypoints[nearest + 1].point,
            ).along >
            0) {
      nearest++;
    }
    _nextWaypointIndex = nearest;
  }

  String _destinationName(AppLocalizations l10n) =>
      (_waypoints.isNotEmpty ? _waypoints.last.name : null) ??
      l10n.navYourDestination;

  /// Where guidance thinks the user is: the camera-corrected position when
  /// it's fresh, raw GPS otherwise.
  LatLng? _currentPosition() {
    final correctedAt = _correctedAt;
    if (_correctedLat != null &&
        _correctedLong != null &&
        correctedAt != null &&
        DateTime.now().difference(correctedAt) < _kCorrectionFreshness) {
      _lastUsedCorrected = true;
      _staleSince = null;
      return LatLng(_correctedLat!, _correctedLong!);
    }
    _lastUsedCorrected = false;
    final position = _locationService.lastPosition;
    if (position == null) return null;
    final raw = LatLng(position.latitude, position.longitude);
    // Blend from the last corrected position to raw GPS instead of jumping
    // the tens of metres that can separate them.
    if (_correctedLat != null && _correctedLong != null) {
      if (_staleSince == null) {
        _staleSince = DateTime.now();
        _staleFrom = LatLng(_correctedLat!, _correctedLong!);
      }
      final from = _staleFrom!;
      final f =
          (DateTime.now().difference(_staleSince!).inMilliseconds /
                  _kSourceBlend.inMilliseconds)
              .clamp(0.0, 1.0);
      if (f < 1) {
        return LatLng(
          from.latitude + (raw.latitude - from.latitude) * f,
          from.longitude + (raw.longitude - from.longitude) * f,
        );
      }
    }
    return raw;
  }

  LatLng? get _rawPosition {
    final position = _locationService.lastPosition;
    return position == null
        ? null
        : LatLng(position.latitude, position.longitude);
  }

  /// Where the segment being walked starts: the previous waypoint, or the
  /// route's start for the first one.
  LatLng? _segmentStart() => _nextWaypointIndex == 0
      ? _startPoint
      : _waypoints[_nextWaypointIndex - 1].point;

  /// Compass heading, or GPS direction of travel while actually moving if
  /// the phone has no compass. Null when neither is usable.
  double? _currentHeading() {
    final compass = _heading.value;
    // The compass is magnetic; route bearings are true north.
    if (compass != null) return trueHeading(compass, _declination);
    final position = _locationService.lastPosition;
    if (position != null && position.speed >= _kMinSpeedForGpsHeading) {
      return position.heading;
    }
    return null;
  }

  /// One guidance step: waypoint progress, then face-then-walk cues toward
  /// the next waypoint (see TurnGuidance).
  void _guide() {
    if (!_guiding || _stopped || _arrived || !mounted) return;
    if (_nextWaypointIndex >= _waypoints.length) return;
    final here = _currentPosition();
    if (here == null) return;
    if (_checkProximity(here)) return;

    final heading = _currentHeading();
    if (heading == null) return;
    final target = _waypoints[_nextWaypointIndex].point;
    final segmentStart = _segmentStart();
    // Follow the segment's direction, not the straight line to the
    // waypoint (see guidanceBearing).
    _lastTargetBearing = segmentStart == null
        ? bearingDegrees(here, target)
        : guidanceBearing(here, segmentStart, target);
    _lastTargetDistance = haversineMeters(here, target);
    _lastTurn = signedTurn(heading, _lastTargetBearing!);
    final cue = _guidance.update(
      turn: _lastTurn!,
      metersToTarget: _lastTargetDistance!,
      now: DateTime.now(),
    );
    final l10n = AppLocalizations.of(context)!;
    switch (cue) {
      case TurnCue(turnAround: true):
        _speak(l10n.navTurnAround, cueType: 'turn');
      case TurnCue(:final degrees, :final right):
        _speak(
          right ? l10n.navTurnRight(degrees) : l10n.navTurnLeft(degrees),
          cueType: 'turn',
        );
      case StartWalkingCue(:final meters):
        _speak(l10n.navStartWalking(meters), cueType: 'start_walking');
      case null:
        break;
    }
  }

  /// Waypoint progress. Reaching any upcoming waypoint counts, not only
  /// the next one, so a noisy fix that skips past a point doesn't leave
  /// guidance stuck waiting for it. Reaching the last one finishes the trip.
  /// Returns true when something was announced.
  bool _checkProximity(LatLng here) {
    final raw = _rawPosition;
    final last = _waypoints.length - 1;
    var reached = -1;
    for (var i = _nextWaypointIndex; i < _waypoints.length; i++) {
      final point = _waypoints[i].point;
      if (i < last && !_cornerReached(here, i)) continue;
      if (i == last &&
          haversineMeters(here, point) > _kProximityThresholdMeters) {
        continue;
      }
      // Skipping past the next waypoint (or arriving) on the strength of
      // the corrected position alone let one bad photo match jump the trip
      // forward: raw GPS has to agree too.
      final skips = i > _nextWaypointIndex || i == last;
      if (skips &&
          (raw == null ||
              haversineMeters(raw, point) >
                  (i == last
                      ? _kArrivalRawGpsMeters
                      : _kProximityThresholdMeters))) {
        continue;
      }
      if (i == last && haversineMeters(here, point) > _kArrivalMeters) {
        continue;
      }
      reached = i;
    }
    if (reached == last) {
      _arrivalStreak++;
      if (_arrivalStreak < _kArrivalConfirmTicks) return false;
    } else {
      _arrivalStreak = 0;
    }
    if (reached == -1) return false;
    _pendingEvents.add({
      'at': DateTime.now().toUtc().toIso8601String(),
      'type': reached == _waypoints.length - 1 ? 'arrival' : 'waypoint',
      'index': reached,
      'skipped': reached - _nextWaypointIndex,
    });
    if (reached == _waypoints.length - 1) {
      _arrive();
      return true;
    }
    _nextWaypointIndex = reached + 1;
    _announceNextLeg(_waypoints[reached], _waypoints[_nextWaypointIndex]);
    return true;
  }

  /// Whether intermediate waypoint [i] counts as reached from [here]: close
  /// to it, or - for the next one - walked up to along its straight.
  bool _cornerReached(LatLng here, int i) {
    final point = _waypoints[i].point;
    if (haversineMeters(here, point) <= _kCornerMeters) return true;
    final from = _segmentStart();
    if (i != _nextWaypointIndex || from == null) return false;
    final projection = projectOntoSegment(here, from, point);
    return projection.length > 0 &&
        projection.along >= projection.length - _kCornerMeters &&
        projection.crossTrack.abs() <= _kCornerCrossTrackMeters;
  }

  /// At a waypoint: one sentence for what to do next. "At the cafeteria,
  /// turn right about 90 degrees, then walk 12 meters", or "continue
  /// straight for 20 meters". The distance is the leg's length, point to
  /// point.
  void _announceNextLeg(_Waypoint from, _Waypoint to) {
    final l10n = AppLocalizations.of(context)!;
    final meters = roundMeters(haversineMeters(from.point, to.point));
    final heading = _currentHeading();
    final turn = heading == null
        ? null
        : signedTurn(heading, bearingDegrees(from.point, to.point));
    final straight = turn == null || turn.abs() <= TurnGuidance.alignedDegrees;
    final String action;
    if (straight) {
      action = l10n.navContinueStraight(meters);
    } else {
      final cue = TurnCue.from(turn);
      action = cue.turnAround
          ? l10n.navTurnAroundThenWalk(meters)
          : cue.right
          ? l10n.navTurnRightThenWalk(cue.degrees, meters)
          : l10n.navTurnLeftThenWalk(cue.degrees, meters);
    }
    final name = from.name;
    _speak(
      name == null ? action : '${l10n.navAtPlace(name)} $action',
      cueType: 'leg',
    );
    _guidance.reset(
      now: DateTime.now(),
      announcedTurn: straight ? null : turn,
      walking: straight,
    );
  }

  /// Within range of the destination: say so and finish the trip on its
  /// own - no need to find the End button.
  void _arrive() {
    if (_arrived) return;
    _arrived = true;
    _speak(
      AppLocalizations.of(
        context,
      )!.navArrivedFinished(_destinationName(AppLocalizations.of(context)!)),
      assertive: true,
      cueType: 'arrival',
    );
    _endSession(arrived: true);
  }

  /// While walking a leg, a short "N meters ahead" every
  /// `_kPeriodicAnnouncementInterval` fills long silent stretches - but
  /// only if nothing else was said recently, and never while the user is
  /// still turning.
  void _announcePeriodicDistance() {
    if (!_guiding || _stopped || _arrived || !mounted) return;
    if (!_guidance.walking || _nextWaypointIndex >= _waypoints.length) return;
    final lastSpoken = _lastSpokenAt;
    if (lastSpoken != null &&
        DateTime.now().difference(lastSpoken) < _kQuietBeforePeriodic) {
      return;
    }
    final here = _currentPosition();
    if (here == null) return;
    final distance = haversineMeters(
      here,
      _waypoints[_nextWaypointIndex].point,
    );
    if (distance <= _kProximityThresholdMeters) return;
    _speak(
      AppLocalizations.of(context)!.navMetersAhead(roundMeters(distance)),
      cueType: 'meters_ahead',
    );
  }

  Future<void> _initCamera() async {
    // Null when unavailable (no hardware, permission denied, etc.) -
    // correction ticks below then fall back to raw-GPS-only logging.
    final controller = await initCamera();
    if (controller == null) return;
    if (_stopped) {
      await controller.dispose();
      return;
    }
    _cameraController = controller;
    if (mounted) setState(() {});
  }

  Future<void> _startSession() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      setState(() {
        _error = AppLocalizations.of(context)!.commonNotSignedIn;
        _starting = false;
      });
      return;
    }
    final startPosition = _locationService.lastPosition;
    final resumeId = widget.resumeSessionId;
    try {
      final result = resumeId != null
          ? [
              {'id': resumeId},
            ]
          : await _navigationApi.post('/sessions', {
              'user_id': userId,
              'building_id': widget.route['building_id'],
              'route_id': widget.route['id'],
              if (startPosition != null)
                'start_position': {
                  'latitude': startPosition.latitude,
                  'longitude': startPosition.longitude,
                },
              'device_info': {
                'platform': Platform.isAndroid ? 'android' : 'other',
              },
            });
      // backend-navigation-management's POST /sessions returns Supabase's
      // insert result as-is, which is always a list (even for one row).
      final sessionData = (result as List).first as Map<String, dynamic>;
      setState(() {
        _sessionId = sessionData['id'] as String?;
        _starting = false;
      });
      // The destination's own name (not the backend's English "A to B"
      // route name) needs the planned path, which loads in parallel.
      await _pathLoaded.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () {},
      );
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        _speak(
          resumeId != null
              ? l10n.navResumingTo(_destinationName(l10n))
              : l10n.navStartingTo(_destinationName(l10n)),
        );
        if (resumeId != null) _skipToNearestWaypoint();
        // Camera-use transparency: said every time, not just once ever -
        // simplest way to stay always-honest about it without persisting
        // a "seen it once" flag. Spoken (politely, after the route-start
        // announcement) *and* shown as text - the same secondary-channel
        // principle this screen already follows for every other
        // announcement, for anyone who can't hear it.
        _speak(l10n.navAnnouncementCameraDisclosure);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.navAnnouncementCameraDisclosure)),
        );
      }
      // Face-then-walk guidance toward the first waypoint starts now.
      _guidance.reset(now: DateTime.now());
      _guiding = true;
      _runTick();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = AppLocalizations.of(
          context,
        )!.navFailedToStartSession(friendlyApiErrorMessage(context, e));
        _starting = false;
      });
    }
  }

  Future<void> _runTick() async {
    if (_stopped) return;
    final sessionId = _sessionId;
    final position = _locationService.lastPosition;
    try {
      if (sessionId == null || position == null) return;
      final controller = _cameraController;
      if (controller == null || !controller.value.isInitialized) {
        await _logRawTick(sessionId, position);
        return;
      }
      await _correctionTick(sessionId, position, controller);
    } finally {
      if (!_stopped) {
        _pendingTickTimer = Timer(const Duration(seconds: 1), _runTick);
      }
    }
  }

  /// Per-tick diagnostics for tuning (navigation_logs.debug): what
  /// guidance saw and decided, plus everything said since the last tick.
  /// [correction] is backend-positioning's own `debug`, when there is one.
  Map<String, dynamic> _debugSnapshot(
    Position position, {
    Map<String, dynamic>? correction,
    String? failure,
  }) {
    final correctedAt = _correctedAt;
    final snapshot = <String, dynamic>{
      'compass': _heading.value,
      'compass_raw': _lastRawCompass,
      'compass_accuracy': _lastCompassAccuracy,
      'gps_speed': position.speed,
      'gps_course': position.heading,
      'gps_time': position.timestamp.toUtc().toIso8601String(),
      'position_source': _lastUsedCorrected ? 'corrected' : 'raw',
      'correction_age_s': correctedAt == null
          ? null
          : DateTime.now().difference(correctedAt).inMilliseconds / 1000,
      'target_index': _nextWaypointIndex,
      'target_distance_m': _lastTargetDistance,
      'target_bearing': _lastTargetBearing,
      'turn': _lastTurn,
      'guidance': _guidance.walking ? 'walking' : 'orienting',
      if (_pendingCues.isNotEmpty) 'cues': List.of(_pendingCues),
      if (_pendingEvents.isNotEmpty) 'events': List.of(_pendingEvents),
      'correction': ?correction,
      'failure': ?failure,
    };
    _pendingCues.clear();
    _pendingEvents.clear();
    return snapshot;
  }

  Future<void> _logRawTick(
    String sessionId,
    Position position, {
    String? failure,
  }) async {
    try {
      await _navigationApi.post('/logs', {
        'session_id': sessionId,
        'gps_lat': position.latitude,
        'gps_long': position.longitude,
        'gps_accuracy': position.accuracy,
        'heading': position.heading,
        'debug': _debugSnapshot(position, failure: failure),
      });
    } on ApiException catch (_) {
      // Best-effort logging - a dropped tick shouldn't interrupt navigation.
    }
  }

  Future<void> _correctionTick(
    String sessionId,
    Position position,
    CameraController controller,
  ) async {
    try {
      final image = await controller.takePicture();
      final bytes = await image.readAsBytes();

      if (isFrameBlocked(bytes)) {
        _consecutiveBlockedTicks++;
        if (_consecutiveBlockedTicks >= _kCameraBlockedDebounceTicks &&
            !_blockedAnnounced) {
          _blockedAnnounced = true;
          if (mounted) {
            _speak(
              AppLocalizations.of(context)!.navAnnouncementCameraBlocked,
              assertive: true,
            );
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  AppLocalizations.of(context)!.navAnnouncementCameraBlocked,
                ),
              ),
            );
          }
        }
        await _logRawTick(sessionId, position, failure: 'camera_blocked');
        return;
      }
      _consecutiveBlockedTicks = 0;
      _blockedAnnounced = false;

      final result =
          await _positioningApi.postMultipart(
                '/correct_position',
                fieldName: 'photo',
                bytes: bytes,
                filename: path.basename(image.path),
                fields: {
                  'session_id': sessionId,
                  'latitude': position.latitude.toString(),
                  'longitude': position.longitude.toString(),
                  'accuracy': position.accuracy.toString(),
                  // The direction the phone (and camera) faces, magnetic
                  // like the anchor photos' own headings, so a match can be
                  // checked against it. Never the GPS course: meaningless
                  // while standing still, it would reject good matches.
                  if (_heading.value != null)
                    'heading': _heading.value!.toString(),
                  // Lets the backend skip re-fusing the same fix.
                  'gps_time': position.timestamp.toUtc().toIso8601String(),
                },
              )
              as Map<String, dynamic>;

      if (mounted) {
        setState(() {
          _correctedLat = (result['corrected_lat'] as num).toDouble();
          _correctedLong = (result['corrected_long'] as num).toDouble();
          _correctionError = (result['correction_error'] as num).toDouble();
          _correctedAt = DateTime.now();
        });
      }

      // A short haptic pulse once per *newly* matched anchor point, not
      // every tick re-confirming the same match (every ~1s - that would be
      // constant buzzing, noise rather than a signal) (#83).
      final anchorMatchId = result['anchor_match_id'] as String?;
      if (anchorMatchId != null && anchorMatchId != _lastHapticAnchorId) {
        _lastHapticAnchorId = anchorMatchId;
        HapticFeedback.selectionClick();
      }

      await _navigationApi.post('/logs', {
        'session_id': sessionId,
        'gps_lat': position.latitude,
        'gps_long': position.longitude,
        'gps_accuracy': position.accuracy,
        'heading': position.heading,
        'corrected_lat': result['corrected_lat'],
        'corrected_long': result['corrected_long'],
        'correction_error': result['correction_error'],
        'anchor_match_id': result['anchor_match_id'],
        'confidence_score': result['confidence_score'],
        'debug': _debugSnapshot(
          position,
          correction: (result['debug'] as Map?)?.cast<String, dynamic>(),
        ),
      });
    } catch (e) {
      // Camera capture or /correct_position failed (unreachable, slow,
      // unauthenticated, etc.) - degrade to a raw-GPS-only tick rather than
      // dropping this tick entirely.
      await _logRawTick(
        sessionId,
        position,
        failure: e is ApiException
            ? 'api_${e.statusCode}'
            : e.runtimeType.toString(),
      );
    }
  }

  /// Admin test flow: records the last instruction as wrong, with where it
  /// happened and what guidance saw, for the session view and tuning.
  Future<void> _reportWrongInstruction() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    HapticFeedback.heavyImpact();
    final position = _locationService.lastPosition;
    final instruction = _lastAnnouncement;
    try {
      await _navigationApi.post('/guidance-reports', {
        'session_id': sessionId,
        'instruction_text': instruction,
        'cue_type': _lastCueType,
        'waypoint_index': _nextWaypointIndex,
        if (position != null) ...{
          'gps_lat': position.latitude,
          'gps_long': position.longitude,
        },
        'corrected_lat': _correctedLat,
        'corrected_long': _correctedLong,
        'compass_heading': _heading.value,
        'debug': {
          'turn': _lastTurn,
          'target_distance_m': _lastTargetDistance,
          'target_bearing': _lastTargetBearing,
          'position_source': _lastUsedCorrected ? 'corrected' : 'raw',
          'guidance': _guidance.walking ? 'walking' : 'orienting',
          'gps_accuracy': position?.accuracy,
          'correction_error': _correctionError,
        },
      });
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              instruction == null
                  ? l10n.navWrongInstructionNothingYet
                  : l10n.navWrongInstructionMarked(instruction),
            ),
          ),
        );
    } on ApiException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l10n.navWrongInstructionFailed(friendlyApiErrorMessage(context, e)),
          ),
        ),
      );
    }
  }

  /// [arrived]: finished by reaching the destination (which already said
  /// so), rather than the End button.
  Future<void> _endSession({bool arrived = false}) async {
    final sessionId = _sessionId;
    _stopped = true;
    _guiding = false;
    _pendingTickTimer?.cancel();
    _guidanceTimer?.cancel();
    _periodicAnnouncementTimer?.cancel();
    _compassSub?.cancel();
    if (sessionId == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() => _ending = true);
    final position = _locationService.lastPosition;
    try {
      await _navigationApi.patch('/sessions/$sessionId', {
        'status': 'completed',
        'end_time': DateTime.now().toUtc().toIso8601String(),
        if (position != null)
          'end_position': {
            'latitude': position.latitude,
            'longitude': position.longitude,
          },
      });
    } on ApiException catch (_) {
      // Session end best-effort too - still let the user leave the screen.
    }
    if (mounted && !arrived) {
      await _speak(AppLocalizations.of(context)!.navAnnouncementEnded);
    }
    if (mounted) await _showFeedbackDialog(sessionId);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _showFeedbackDialog(String sessionId) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();
    await _speak(l10n.navFeedbackTitle);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.navFeedbackTitle),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(hintText: l10n.navFeedbackHint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.navFeedbackSkip),
          ),
          TextButton(
            onPressed: () async {
              final comment = controller.text.trim();
              final userId = Supabase.instance.client.auth.currentUser?.id;
              if (comment.isNotEmpty && userId != null) {
                try {
                  await _navigationApi.post('/feedback', {
                    'user_id': userId,
                    'session_id': sessionId,
                    'comment': comment,
                  });
                } on ApiException catch (_) {
                  // Feedback is best-effort - don't block leaving the screen.
                }
              }
              if (context.mounted) Navigator.of(context).pop();
            },
            child: Text(l10n.navFeedbackSubmit),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _stopped = true;
    _pendingTickTimer?.cancel();
    _periodicAnnouncementTimer?.cancel();
    _guidanceTimer?.cancel();
    _compassSub?.cancel();
    _cameraController?.dispose();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final correctedLat = _correctedLat;
    final correctedLong = _correctedLong;
    final showDebugPreview =
        kDebugMode &&
        _cameraController != null &&
        _cameraController!.value.isInitialized;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _waypoints.isNotEmpty && _waypoints.last.name != null
              ? _waypoints.last.name!
              : l10n.navDefaultTitle,
        ),
      ),
      body: SafeArea(
        child: _starting
            ? const Center(child: CircularProgressIndicator())
            : Stack(
                children: [
                  Column(
                    children: [
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              _error!,
                              style: const TextStyle(color: Colors.red),
                            ),
                          ),
                        ),
                      const LocationInfo(),
                      if (correctedLat != null && correctedLong != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          child: Text(
                            l10n.navCorrectedPosition(
                              correctedLat.toStringAsFixed(6),
                              correctedLong.toStringAsFixed(6),
                              _correctionError != null
                                  ? ' (±${_correctionError!.toStringAsFixed(2)}m)'
                                  : '',
                            ),
                            style: const TextStyle(color: Colors.green),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                        child: ExcludeSemantics(
                          child: Row(
                            children: [
                              const Icon(Icons.touch_app_outlined, size: 18),
                              const SizedBox(width: 6),
                              Expanded(child: Text(l10n.navTapToRepeatHint)),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        // The map itself means nothing to a screen reader -
                        // it's exposed as one large button that repeats the
                        // last instruction (TalkBack: double-tap it).
                        child: Semantics(
                          container: true,
                          button: true,
                          label: l10n.navTapToRepeatHint,
                          onTap: _repeatLastAnnouncement,
                          child: ExcludeSemantics(
                            child: SimpleMapWidget(
                              onTap: _repeatLastAnnouncement,
                              plannedPath: _plannedPath,
                              extraMarkers:
                                  correctedLat != null && correctedLong != null
                                  ? [
                                      locationPinMarker(
                                        LatLng(correctedLat, correctedLong),
                                        Colors.green,
                                      ),
                                    ]
                                  : const [],
                            ),
                          ),
                        ),
                      ),
                      if (widget.adminPreview)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.red.shade700,
                              minimumSize: const Size.fromHeight(56),
                            ),
                            onPressed: _sessionId == null || _ending
                                ? null
                                : _reportWrongInstruction,
                            icon: const Icon(Icons.close),
                            label: Text(l10n.navWrongInstructionButton),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: ElevatedButton(
                          onPressed: _ending ? null : () => _endSession(),
                          child: _ending
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(l10n.navEndButton),
                        ),
                      ),
                    ],
                  ),
                  // Debug-build-only: lets a developer confirm the background
                  // capture is actually seeing something sane. Never shown in
                  // a release build (see kDebugMode above).
                  if (showDebugPreview)
                    Positioned(
                      bottom: 8,
                      left: 8,
                      width: 100,
                      height: 140,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CameraPreview(_cameraController!),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
