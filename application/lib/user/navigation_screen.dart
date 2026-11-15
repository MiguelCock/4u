import 'dart:async';

import 'package:camera/camera.dart';
import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as path;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../location.dart';
import '../map.dart';
import '../services/api_service.dart';
import '../services/app_preferences.dart';
import '../services/floor_detector.dart';
import '../services/floor_steps.dart';
import '../services/geo_utils.dart';
import '../services/heading_tracker.dart';
import '../services/location_service.dart';
import '../voice/app_voice.dart';
import '../voice/notices.dart';
import '../services/buzz.dart';
import '../services/route_points.dart';
import '../services/test_walk.dart';
import '../services/turn_guidance.dart';
import '../services/trip_plan.dart';
import '../services/trip_words.dart';
import 'correction_loop.dart';
import 'trip_log.dart';
import 'trip_sensors.dart';
import '../services/api_error_messages.dart';

/// Cues that are instructions: a short vibration comes first, so a user
/// holding the phone in front (not at the ear) knows to listen.
const Set<String> _kInstructionCues = {
  'turn',
  'leg',
  'turn_ahead',
  'hazard',
  'away',
  'slow_turn',
  'floor',
};

/// A floor change comes from the barometer. If nothing is heard by this long
/// after the instruction, or this long per floor on a phone without one, the
/// trip carries on rather than going silent for good.
const Duration _kFloorWaitLimit = Duration(minutes: 3);
const Duration _kNoBarometerWaitPerFloor = Duration(seconds: 60);

/// No barometer reading this long after opening: the phone hasn't got one.
const Duration _kBarometerProbe = Duration(seconds: 3);

/// Location type of a hallway: a trip starting anywhere else gets the
/// compass direction at once (see _checkStall).
const int _kHallwayType = 10;

/// This much nearer the next stop counts as progress (see isStalled).
const double _kStallProgressMeters = 3;

/// With no progress, "keep walking" at most this often.
const Duration _kQuietBeforeKeepWalking = Duration(seconds: 30);

/// A GPS fix this old advances nothing; this old, it's announced and the
/// stream restarted. A trip ran on a 4-minute-old fix (Icesi, 2026-11-04).
const Duration _kStaleFix = Duration(seconds: 15);
const Duration _kStaleFixAnnounce = Duration(seconds: 25);

/// No progress cue for this long after the screen opens unless something
/// else was said: "Preparing the route", then "One moment" every
/// [_kLoadingRepeat] until the first instruction. Testers didn't know
/// whether the app was working (Icesi, 2026-11-03).
const Duration _kLoadingNotice = Duration(milliseconds: 1500);
const Duration _kLoadingRepeat = Duration(seconds: 6);

/// A correction's offset from raw GPS is applied to the live fix for this
/// long, then dropped in favour of raw GPS (the camera loop has stalled).
/// The offset is the GPS's own slowly changing error (backend-positioning's
/// bias, tau 120 s), so it holds well past the next tick. Showing the
/// corrected position itself instead put it 5-11 s behind the user in a
/// field test: a tick's answer arrives ~5 s after its photo.
const Duration _kCorrectionFreshness = Duration(seconds: 20);

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
/// walked to within this of its end along the straight leading to it, or
/// has already turned onto the next leg near it (see cornerProgress). It
/// was 20 m, then 8 m: with the position good to ~1 m, 8 m still spoke
/// every turn 5-8 s before the corner (third test walk).
const double _kCornerMeters = 3.0;

/// This far (meters) before a corner: "In 8 meters, turn left", once.
const double _kTurnWarningMeters = 8.0;

/// No heads-up on a leg shorter than this: it would follow straight on
/// from the leg's own instruction.
const double _kMinLegForWarningMeters = 12.0;

/// ...but not if they're this far (meters) to the side of that straight.
const double _kCornerCrossTrackMeters = 15.0;

/// Arriving needs the corrected position within [arrivalRadius] of the
/// destination *and* raw GPS within that plus [_kArrivalRawGpsSlackMeters],
/// on [_kArrivalConfirmTicks] guidance ticks in a row. A field test ended
/// the trip ~40 m early: photo matches on the destination pulled the
/// corrected position inside 20 m while the user was still far away.
const double _kArrivalRawGpsSlackMeters = 10.0;
const int _kArrivalConfirmTicks = 2;

/// Navigation's per-tick calls: an answer later than this is useless, and
/// waiting the default 60 s stalled the whole loop (no logs, stale
/// correction) through a ~20 s connection drop in a field test.
const Duration _kTickRequestTimeout = Duration(seconds: 8);

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

class NavigationScreen extends StatefulWidget {
  final Map<String, dynamic> route;

  /// Continue an existing session (a trip left open by closing the app,
  /// offered on the next launch by UserHomeScreen) instead of starting a
  /// new one.
  final String? resumeSessionId;

  /// What to call the destination aloud: a building ("Edificio C"), when the
  /// route ends at whichever of its doors is closest, or a point with its
  /// building ("Entrada sur, Bloque 20"). Null: the end point's own name.
  final String? destinationName;

  /// The admin's "Test as user" flow: shows the "Wrong instruction" button
  /// that records the last cue for tuning (backend guidance_reports).
  final bool adminPreview;

  /// What the trip talks to, for tests. Every real caller uses the
  /// defaults: the gateway's APIs, the phone's location, sensors and voice,
  /// and the signed-in user.
  final NavigationManagementApi? navigationApi;
  final PositioningApi? positioningApi;
  final MapManagementApi? mapApi;
  final LocationService? locationService;
  final AppVoice? voice;
  final TripSensors sensors;

  /// The signed-in user's id; null when nobody is.
  final String? Function()? userId;

  const NavigationScreen({
    super.key,
    required this.route,
    this.resumeSessionId,
    this.destinationName,
    this.adminPreview = false,
    this.navigationApi,
    this.positioningApi,
    this.mapApi,
    this.locationService,
    this.voice,
    this.sensors = const TripSensors(),
    this.userId,
  });

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen>
    with WidgetsBindingObserver {
  late final _navigationApi = widget.navigationApi ?? NavigationManagementApi();
  late final _positioningApi = widget.positioningApi ?? PositioningApi();
  late final _mapApi = widget.mapApi ?? MapManagementApi();
  late final _locationService = widget.locationService ?? LocationService();
  late final AppVoice _appVoice = widget.voice ?? AppVoice.instance;

  String? get _userId => widget.userId != null
      ? widget.userId!()
      : Supabase.instance.client.auth.currentUser?.id;

  /// The trip's right to speak: claimed as the trip starts, so whatever the
  /// home screen was still saying is dropped (#258).
  late VoiceOwner _voice;
  String? _sessionId;
  CameraController? _cameraController;

  Timer? _periodicAnnouncementTimer;
  Timer? _guidanceTimer;
  Timer? _loadingTimer;
  Timer? _barometerProbeTimer;
  StreamSubscription<double>? _barometerSub;
  final _floorDetector = FloorChangeDetector();
  bool _barometerSeen = false;

  /// The floor guidance believes the user is on: waypoints on another floor
  /// can't be reached until a floor change gets them there.
  int _currentFloor = 0;
  int _startFloor = 0;
  int? _startHazard;
  int? _startTypeId;

  /// Real progress toward the next stop (see isStalled): the nearest it has
  /// been, and when.
  double? _bestMeters;
  DateTime? _lastProgressAt;

  final _recentFixes = RecentFixes();

  /// When the app was paused (the screen went off, say), and whether the
  /// current GPS silence was already announced.
  DateTime? _pausedAt;
  bool _gpsStaleAnnounced = false;
  List<int> _plannedFloors = const [];

  /// The floor change being waited for, and since when. Guidance is paused
  /// meanwhile.
  FloorChange? _floorChange;
  DateTime? _floorWaitSince;

  /// A route starting at the foot of stairs was checked for that.
  bool _startFloorChecked = false;
  StreamSubscription<CompassReading>? _compassSub;
  final _heading = HeadingSmoother();
  final _tracker = HeadingTracker();
  StreamSubscription<AxisReading>? _gyroSub;
  StreamSubscription<AxisReading>? _accelSub;
  StreamSubscription<Position>? _positionSub;
  final _guidance = TurnGuidance();
  final _pathLoaded = Completer<void>();
  bool _guiding = false;
  bool _arrived = false;
  DateTime? _correctedAt;
  DateTime? _lastSpokenAt;
  bool _stopped = false;

  /// The route's own start point, where the first segment begins.
  LatLng? _startPoint;

  /// Admin test walk: the checkpoints still to tap (see test_walk.dart),
  /// one per route corner plus the start and the destination.
  CheckpointSequence _checkpoints = CheckpointSequence(0);
  int _arrivalStreak = 0;

  /// The waypoint whose heads-up ("in 8 meters, turn left") was given.
  int? _warnedForWaypoint;

  /// The first instruction is still to be said (see _speakStartCue).
  bool _needsStartCue = false;

  /// "Loading the route" was said (the path is slow to arrive).
  bool _loadingAnnounced = false;

  /// The distance to the next waypoint at the last periodic update (or the
  /// leg's start), and the steps said then: see progressSince.
  double? _progressMeters;
  int? _progressSteps;
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

  /// The last correction minus the raw fix it corrected, metres east/north
  /// (see _kCorrectionFreshness).
  ({double x, double y})? _correctionOffset;
  double? _correctionError;
  List<LatLng> _plannedPath = [];
  List<Waypoint> _waypoints = [];
  int _nextWaypointIndex = 0;
  String? _lastAnnouncement;

  /// What kind of cue [_lastAnnouncement] was (turn, start_walking, leg,
  /// meters_ahead, arrival, start...), for the diagnostics and the admin's
  /// "wrong instruction" reports.
  String? _lastCueType;

  /// Cues spoken and guidance events since the last log, sent with the next
  /// tick's `debug` so the session view can show what was said where.
  /// The cues and events for the next tick's log.
  late final _log = TripLog(_navigationApi, timeout: _kTickRequestTimeout);

  /// The photo-and-correction tick, once a second.
  late final _loop = CorrectionLoop(
    api: _positioningApi,
    log: _log,
    sessionId: () => _sessionId,
    position: () => _locationService.lastPosition,
    camera: () {
      final controller = _cameraController;
      return controller == null ? null : _Lens(controller);
    },
    debug: _debugSnapshot,
    heading: _sentHeading,
    onCorrected: _applyCorrection,
    onCameraBlocked: _sayCameraBlocked,
    onNewMatch: HapticFeedback.selectionClick,
    storeFrame: widget.adminPreview,
    timeout: _kTickRequestTimeout,
  );

  /// Latest guidance inputs, kept for the per-tick diagnostics.
  double? _lastRawCompass;
  double? _lastCompassAccuracy;
  double? _lastTurn;
  double? _lastTargetDistance;
  double? _lastTargetBearing;
  bool _lastUsedCorrected = false;

  /// The app language whose voice was checked (see [_onTtsConfigured]).
  String? _ttsLanguage;

  /// TalkBack (or another screen reader) on, as of the last build.
  bool _screenReader = false;
  bool _voiceMissingShown = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _screenReader = screenReaderOn(context);
    final language = Localizations.localeOf(context).languageCode;
    if (language != _ttsLanguage) {
      _ttsLanguage = language;
      _appVoice.setLanguage(language).then(_onTtsConfigured);
    }
  }

  void _onTtsConfigured(bool hasVoice) {
    if (hasVoice || _voiceMissingShown || !mounted) return;
    _voiceMissingShown = true;
    showSpokenNotice(
      context,
      AppLocalizations.of(context)!.navVoiceLanguageMissing,
      spoken: false,
      duration: const Duration(seconds: 10),
    );
  }

  @override
  void initState() {
    super.initState();
    _voice = _appVoice.claim();
    _startSession();
    _initCamera();
    _loadPlannedPath();
    _periodicAnnouncementTimer = Timer.periodic(
      _kPeriodicAnnouncementInterval,
      (_) => _announcePeriodicDistance(),
    );
    _compassSub = widget.sensors.compass()?.listen((event) {
      // Android only fills `heading` (see capture_photo_screen.dart).
      final heading = event.heading;
      _lastCompassAccuracy = event.accuracy;
      if (heading != null) {
        _lastRawCompass = heading;
        _heading.add(heading);
        _tracker.compass(
          trueHeading(_heading.value!, _declination),
          clock.now(),
        );
      }
    });
    // Turns come from the gyroscope, direction from walking: the compass
    // under-counted every turn in a field test (see HeadingTracker).
    _accelSub = widget.sensors.accelerometer().listen(
      (e) => _tracker.accelerometer(e.x, e.y, e.z),
      onError: _sensorError,
    );
    _gyroSub = widget.sensors.gyroscope().listen(
      (e) => _tracker.gyro(e.x, e.y, e.z, clock.now()),
      onError: _sensorError,
    );
    WidgetsBinding.instance.addObserver(this);
    // A screen that turns off stops the camera, GPS and timers without a word.
    widget.sensors.keepAwake(true);
    _positionSub = _locationService.positionStream.listen((position) {
      _recentFixes.add(position.latLng, position.timestamp);
      _tracker.gpsCourse(
        position.heading,
        position.speed,
        position.timestamp,
        accuracy: position.accuracy,
        movedMeters: _recentFixes.movedMeters,
      );
      // The corrected marker follows the live fix (see _liveCorrected).
      if (_correctionOffset != null && mounted) setState(() {});
    });
    _guidanceTimer = Timer.periodic(_kGuidanceInterval, (_) => _guide());
    _loadingTimer = Timer(_kLoadingNotice, _sayStillLoading);
    _barometerSub = widget.sensors.pressure().listen((pressure) {
      _barometerSeen = true;
      _floorDetector.add(pressure, clock.now());
    }, onError: _sensorError);
    _barometerProbeTimer = Timer(_kBarometerProbe, () {
      if (_barometerSeen) return;
      _log.event('barometer_missing');
    });
  }

  /// Until the first real announcement: "Preparing the route", then "One
  /// moment" every [_kLoadingRepeat].
  void _sayStillLoading() {
    if (_stopped || !mounted || _lastAnnouncement != null || _error != null) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    _speak(
      _loadingAnnounced ? l10n.commonOneMoment : l10n.navLoadingRoute,
      repeatable: false,
    );
    _loadingAnnounced = true;
    _loadingTimer = Timer(_kLoadingRepeat, _sayStillLoading);
  }

  /// A sensor stream failed: logged with the next tick, so a phone whose
  /// gyroscope doesn't work shows up in the session data.
  void _sensorError(Object error) {
    _log.event('sensor_error', fields: {'error': error.toString()});
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
    bool repeatable = true,
  }) async {
    // Notices (the camera, "loading") aren't what "repeat" should replay.
    if (repeatable) {
      _lastAnnouncement = text;
      _lastCueType = cueType;
    }
    _lastSpokenAt = clock.now();
    if (_kInstructionCues.contains(cueType)) {
      buzz(Buzz.short);
    } else if (cueType == 'start_walking') {
      // The "I'll vibrate when you face the right way" of SlowTurnCue.
      buzz(Buzz.long);
    }
    _log.cue(cueType, text);
    if (!voiceGuidanceNotifier.value) return;
    await _voice.say(text, interrupt: assertive);
  }

  /// Re-speaks the most recent announcement on demand (a tap on the map) -
  /// assertive, since the user is explicitly asking to hear it right now.
  /// Also shown as a SnackBar, for anyone with voice guidance or sound off.
  void _repeatLastAnnouncement() {
    final text = _lastAnnouncement;
    if (text == null) return;
    _speak(text, assertive: true, cueType: _lastCueType ?? 'info');
    showSpokenNotice(context, text, replace: true);
  }

  /// Resolves the route's anchor ids (already in hand from find_or_create,
  /// no need to re-fetch the route itself) into coordinates for the
  /// guidance line (`_plannedPath`, every point including the start) and
  /// into `_waypoints` (every point *except* the start - nothing to
  /// "approach" at the point you're already standing at) for #40's
  /// proximity announcements - same per-id anchor lookup
  /// SessionTrackingScreen's admin-side route overlay already does.
  Future<void> _loadPlannedPath() async {
    final anchorIds = routeAnchorIds(widget.route);
    // One request when the server has it (E2), else all at once: one request
    // after another took ~90 s on campus mobile data in a test walk, and
    // guidance can't start without the path.
    final plan = buildTripPlan(
      anchorIds,
      await fetchRoutePoints(_mapApi, anchorIds),
    );
    _startPoint = plan.startPoint;
    if (mounted) {
      setState(() {
        _plannedPath = plan.points;
        _plannedFloors = plan.floors;
        if (plan.floors.isNotEmpty) {
          _startFloor = plan.startFloor!;
          _currentFloor = plan.startFloor!;
          _startHazard = plan.startHazard;
          _startTypeId = plan.startTypeId;
        }
        _waypoints = plan.waypoints;
        _checkpoints = CheckpointSequence(plan.cornerCount);
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
    final nearest = resumeWaypointIndex(here, _waypoints);
    _nextWaypointIndex = nearest;
    // GPS can't tell the floor: trust the waypoint it's nearest to.
    _currentFloor = _waypoints[nearest].floor;
    _startFloorChecked = true;
  }

  String _destinationName(AppLocalizations l10n) =>
      widget.destinationName ??
      (_waypoints.isNotEmpty ? _waypoints.last.name : null) ??
      l10n.navYourDestination;

  /// Where guidance thinks the user is: the camera-corrected position when
  /// it's fresh, raw GPS otherwise.
  LatLng? _currentPosition() {
    final live = _liveCorrected();
    if (live != null) {
      _lastUsedCorrected = true;
      _staleSince = null;
      _staleFrom = live;
      return live;
    }
    _lastUsedCorrected = false;
    final position = _locationService.lastPosition;
    if (position == null) return null;
    final raw = position.latLng;
    // Blend from the last corrected position to raw GPS instead of jumping
    // the tens of metres that can separate them.
    final staleFrom = _staleFrom;
    if (staleFrom != null) {
      _staleSince ??= clock.now();
      final from = staleFrom;
      final f =
          (clock.now().difference(_staleSince!).inMilliseconds /
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

  /// The live GPS fix with the latest correction's offset applied, while
  /// that offset is fresh; null otherwise.
  LatLng? _liveCorrected() {
    final offset = _correctionOffset;
    final correctedAt = _correctedAt;
    final raw = _rawPosition;
    if (offset == null ||
        correctedAt == null ||
        raw == null ||
        clock.now().difference(correctedAt) >= _kCorrectionFreshness) {
      return null;
    }
    return applyOffset(raw, offset.x, offset.y);
  }

  LatLng? get _rawPosition {
    final position = _locationService.lastPosition;
    return position?.latLng;
  }

  /// Where the segment being walked starts: the previous waypoint, or the
  /// route's start for the first one.
  LatLng? _segmentStart() => _nextWaypointIndex == 0
      ? _startPoint
      : _waypoints[_nextWaypointIndex - 1].point;

  /// Which way the user faces (true north): HeadingTracker's gyro heading
  /// anchored to walking, else the compass, else the GPS direction of
  /// travel while actually moving. Null when none is usable.
  double? _currentHeading() {
    final tracked = _tracker.value;
    if (tracked != null) return tracked;
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
    if (_waypoints.isEmpty && !_pathLoaded.isCompleted) {
      if (!_loadingAnnounced) {
        _loadingAnnounced = true;
        _speak(
          AppLocalizations.of(context)!.navLoadingRoute,
          repeatable: false,
        );
      }
      return;
    }
    if (_nextWaypointIndex >= _waypoints.length) return;
    if (_floorChange != null) {
      _checkFloorChange();
      return;
    }
    if (!_startFloorChecked) {
      _startFloorChecked = true;
      // The route starts at the foot of the stairs.
      final change = _floorChangeAfter(-1);
      if (change != null) {
        _beginFloorChange(-1, change);
        return;
      }
    }
    final here = _currentPosition();
    if (here == null) return;
    final fix = _locationService.lastPosition;
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

    if (_needsStartCue) _speakStartCue(here);
    _checkStall(here);

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
    final now = clock.now();
    final cue = _guidance.update(
      turn: _lastTurn!,
      metersToTarget: _lastTargetDistance!,
      now: now,
      reliable: _tracker.reliable(now),
    );
    final l10n = AppLocalizations.of(context)!;
    switch (cue) {
      case TurnCue():
        _speak(turnWords(l10n, cue), cueType: 'turn');
      case StartWalkingCue(:final steps):
        _resetProgress(_lastTargetDistance);
        _speak(l10n.navGoStraightSteps(steps), cueType: 'start_walking');
      case SlowTurnCue():
        _speak(l10n.navSlowTurn, cueType: 'slow_turn');
      case null:
        break;
    }
  }

  /// The heading, only when it can be trusted (see HeadingTracker.reliable).
  double? _reliableHeading() =>
      _tracker.reliable(clock.now()) ? _tracker.value : null;

  /// The first instruction, once the route is loaded. With a heading that
  /// can be trusted it's face-then-walk (TurnGuidance); without one there's
  /// no knowing which way the user faces, so they're told to walk and the
  /// walking direction takes it from there.
  void _speakStartCue(LatLng here) {
    _needsStartCue = false;
    _speakLegNotes(_waypoints[_nextWaypointIndex]);
    _resetProgress(haversineMeters(here, _waypoints[_nextWaypointIndex].point));
    if (_reliableHeading() != null) {
      _guidance.reset(now: clock.now());
      return;
    }
    // A hallway leads the way; a plaza doesn't, and "walk forward" there left
    // people standing at the start (Icesi, 2026-11-05).
    if (_startTypeId != _kHallwayType && _speakCompassDirection(here)) {
      _guidance.reset(now: clock.now(), walking: true);
      return;
    }
    _speak(
      AppLocalizations.of(context)!.navWalkForward(
        roundSteps(haversineMeters(here, _waypoints[_nextWaypointIndex].point)),
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
    final compass = _heading.value;
    if (compass == null) return false;
    final target = _waypoints[_nextWaypointIndex].point;
    final from = _segmentStart();
    final bearing = from == null || haversineMeters(from, target) < 1
        ? bearingDegrees(here, target)
        : bearingDegrees(from, target);
    final turn = signedTurn(trueHeading(compass, _declination), bearing);
    final steps = roundSteps(haversineMeters(here, target));
    final l10n = AppLocalizations.of(context)!;
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
    final now = clock.now();
    final meters = haversineMeters(here, _waypoints[_nextWaypointIndex].point);
    final best = _bestMeters;
    if (best == null || meters <= best - _kStallProgressMeters) {
      _bestMeters = meters;
      _lastProgressAt = now;
      return;
    }
    if (_reliableHeading() != null ||
        !isStalled(lastProgressAt: _lastProgressAt, now: now)) {
      return;
    }
    _lastProgressAt = now;
    if (!_speakCompassDirection(here)) _sayKeepWalking(meters);
  }

  void _sayKeepWalking(double meters) {
    _speak(
      AppLocalizations.of(context)!.navKeepWalking(roundSteps(meters)),
      cueType: 'stall',
    );
  }

  /// GPS has stopped answering: said once, and its stream is started again.
  void _sayGpsStale(Duration age) {
    if (_gpsStaleAnnounced || age < _kStaleFixAnnounce) return;
    _gpsStaleAnnounced = true;
    _log.event('gps_stale', fields: {'age_s': age.inSeconds});
    _speak(
      AppLocalizations.of(context)!.homeSearchingLocation,
      repeatable: false,
    );
    _locationService.restart();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final now = clock.now();
    if (state == AppLifecycleState.paused) {
      _pausedAt = now;
      _log.event('app_paused', at: now);
    } else if (state == AppLifecycleState.resumed) {
      final pausedAt = _pausedAt;
      if (pausedAt == null) return;
      _pausedAt = null;
      _log.event(
        'app_resumed',
        at: now,
        fields: {'gap_s': now.difference(pausedAt).inSeconds},
      );
      if (mounted && !_stopped) _repeatLastAnnouncement();
    }
  }

  /// Waypoint progress. Reaching any upcoming waypoint counts, not only
  /// the next one, so a noisy fix that skips past a point doesn't leave
  /// guidance stuck waiting for it. Reaching the last one finishes the trip.
  /// Returns true when something was announced.
  bool _checkProximity(LatLng here) {
    final raw = _rawPosition;
    final last = _waypoints.length - 1;
    final lastLegFrom = last > 0 ? _waypoints[last - 1].point : _startPoint;
    final arrivalMeters = arrivalRadius(
      gpsAccuracy: _locationService.lastPosition?.accuracy ?? 10,
      lastLegMeters: lastLegFrom == null
          ? null
          : haversineMeters(lastLegFrom, _waypoints[last].point),
    );
    var reached = -1;
    for (var i = _nextWaypointIndex; i < _waypoints.length; i++) {
      // GPS can't tell floors apart: the point above can't be reached, skipped
      // to or arrived at from here.
      if (_waypoints[i].floor != _currentFloor) break;
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
      if (i > _nextWaypointIndex &&
          i < last &&
          (raw == null ||
              !maySkipTo(
                metersToNext: haversineMeters(
                  raw,
                  _waypoints[_nextWaypointIndex].point,
                ),
                metersToLater: haversineMeters(raw, point),
                maxMeters: _kProximityThresholdMeters,
              ))) {
        continue;
      }
      if (skips &&
          (raw == null ||
              haversineMeters(raw, point) >
                  (i == last
                      ? arrivalMeters + _kArrivalRawGpsSlackMeters
                      : _kProximityThresholdMeters))) {
        continue;
      }
      if (i == last && haversineMeters(here, point) > arrivalMeters) {
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
    _log.event(
      reached == _waypoints.length - 1 ? 'arrival' : 'waypoint',
      fields: {'index': reached, 'skipped': reached - _nextWaypointIndex},
    );
    if (reached == _waypoints.length - 1) {
      _arrive();
      return true;
    }
    _nextWaypointIndex = reached + 1;
    final floorChange = _floorChangeAfter(reached);
    if (floorChange != null) {
      _beginFloorChange(reached, floorChange);
      return true;
    }
    _announceNextLeg(
      reached == 0 ? _startPoint : _waypoints[reached - 1].point,
      _waypoints[reached],
      _waypoints[_nextWaypointIndex],
    );
    return true;
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

  /// At the foot of the stairs (waypoint [from], -1: the route's start): which
  /// way to go, then guidance waits for the barometer ([_checkFloorChange]).
  void _beginFloorChange(int from, FloorChange change) {
    final l10n = AppLocalizations.of(context)!;
    final now = clock.now();
    final floors = change.floor - _currentFloor;
    final types = {
      from < 0 ? _startHazard : _waypoints[from].hazardType,
      _waypoints[change.lastIndex].hazardType,
    };
    final up = floors > 0;
    final floor = change.floor + 1;
    final action = floorChangeAction(l10n, types: types, up: up, floor: floor);
    _floorChange = change;
    _floorWaitSince = now;
    _floorDetector.start(floors, now: now);
    _log.event(
      'floor_wait',
      at: now,
      fields: {
        'from': _currentFloor,
        'to': change.floor,
        'pressure_hpa': _floorDetector.pressure,
        'barometer': _barometerSeen,
      },
    );
    _speak(
      '$action ${_barometerSeen ? l10n.navFloorWillTell : l10n.navFloorNoSensor}',
      cueType: 'floor',
    );
  }

  /// While waiting at a floor change: has the barometer heard it, or has the
  /// wait run out? Then guidance picks up from the far end.
  void _checkFloorChange() {
    final change = _floorChange!;
    final now = clock.now();
    final waited = now.difference(_floorWaitSince!);
    final detected = _floorDetector.reached;
    final limit = _barometerSeen
        ? _kFloorWaitLimit
        : _kNoBarometerWaitPerFloor * (change.floor - _currentFloor).abs();
    if (!detected && waited < limit) return;
    _log.event(
      detected ? 'floor_detected' : 'floor_timeout',
      at: now,
      fields: {
        'to': change.floor,
        'seconds': waited.inSeconds,
        'delta_hpa': _floorDetector.delta,
      },
    );
    _floorChange = null;
    _floorDetector.stop();
    _currentFloor = change.floor;
    final l10n = AppLocalizations.of(context)!;
    buzz(Buzz.long);
    _speak(
      detected
          ? l10n.navFloorReached(change.floor + 1)
          : l10n.navFloorTimeout(change.floor + 1),
      cueType: 'floor',
    );
    setState(() {});
    if (change.lastIndex == _waypoints.length - 1) {
      _arrive();
      return;
    }
    _nextWaypointIndex = change.lastIndex + 1;
    _arrivalStreak = 0;
    _resetProgress(null);
    // Off the stairs, nothing says which way the user faces.
    _needsStartCue = true;
  }

  /// Whether intermediate waypoint [i] counts as reached from [here]: close
  /// to it, or - for the next one - walked up to along its straight.
  bool _cornerReached(LatLng here, int i) {
    if (haversineMeters(here, _waypoints[i].point) <= _kCornerMeters) {
      return true;
    }
    return i == _nextWaypointIndex &&
        _cornerProgress(here) == CornerProgress.reached;
  }

  /// Progress toward the next waypoint when it's a corner (not the
  /// destination), or null.
  CornerProgress? _cornerProgress(LatLng here) {
    final i = _nextWaypointIndex;
    final from = _segmentStart();
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
      heading: _reliableHeading(),
      legBearing: bearingDegrees(from, corner),
      // The next waypoint is on another floor, nearly overhead: no bearing.
      nextLegBearing: _waypoints[i + 1].floor != _waypoints[i].floor
          ? null
          : bearingDegrees(corner, _waypoints[i + 1].point),
      reachedMeters: _kCornerMeters,
      warnMeters: _kTurnWarningMeters,
      maxCrossTrackMeters: _kCornerCrossTrackMeters,
    );
  }

  /// "In 8 meters, turn left", once per corner, so the turn instruction at
  /// the corner itself doesn't come as a surprise.
  void _warnTurnAhead(LatLng here) {
    final i = _nextWaypointIndex;
    if (_warnedForWaypoint == i ||
        _cornerProgress(here) != CornerProgress.warn) {
      return;
    }
    _warnedForWaypoint = i;
    final from = _segmentStart()!;
    final corner = _waypoints[i].point;
    final hazard = _waypoints[i].hazardType;
    if (hazard != null) {
      final l10n = AppLocalizations.of(context)!;
      _speak(
        l10n.navHazardAhead(
          hazardLabel(l10n, hazard),
          roundSteps(haversineMeters(here, corner)),
        ),
        cueType: 'hazard',
      );
    }
    if (_waypoints[i + 1].floor != _waypoints[i].floor) return;
    final turn = signedTurn(
      bearingDegrees(from, corner),
      bearingDegrees(corner, _waypoints[i + 1].point),
    );
    if (haversineMeters(from, corner) < _kMinLegForWarningMeters ||
        turn.abs() <= TurnGuidance.alignedDegrees) {
      return;
    }
    final steps = roundSteps(haversineMeters(here, corner));
    final l10n = AppLocalizations.of(context)!;
    _speak(
      turn > 0
          ? l10n.navTurnAheadRightSteps(steps)
          : l10n.navTurnAheadLeftSteps(steps),
      cueType: 'turn_ahead',
    );
  }

  /// "Attention: three steps down" - the admins' warnings on the leg that
  /// ends at [to], said as it starts.
  void _speakLegNotes(Waypoint to) {
    final l10n = AppLocalizations.of(context)!;
    for (final note in to.legNotes) {
      _speak(l10n.navLegWarning(note), cueType: 'hazard');
    }
  }

  /// Starts counting progress toward the next waypoint afresh, from
  /// [meters] away (null: the next periodic update speaks regardless).
  void _resetProgress(double? meters) {
    _bestMeters = null;
    _lastProgressAt = null;
    _progressMeters = meters;
    _progressSteps = meters == null ? null : roundSteps(meters);
  }

  /// At a waypoint: one sentence for what to do next. "At the cafeteria,
  /// turn right and walk about 20 steps", or "go straight, about 30
  /// steps". The turn comes from the route itself (the bend between the two
  /// legs), not the phone's heading, which can be far off; the steps are the
  /// leg's length. A user who has already turned (by a trusted heading) just
  /// hears "go straight".
  void _announceNextLeg(LatLng? previous, Waypoint from, Waypoint to) {
    final l10n = AppLocalizations.of(context)!;
    final steps = roundSteps(haversineMeters(from.point, to.point));
    final nextBearing = bearingDegrees(from.point, to.point);
    final routeTurn = previous == null
        ? 0.0
        : signedTurn(bearingDegrees(previous, from.point), nextBearing);
    final heading = _reliableHeading();
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
    _resetProgress(haversineMeters(from.point, to.point));
    // Walking: the user turns as told, and is corrected (once) only if a
    // trusted heading shows them going the wrong way.
    _guidance.reset(now: clock.now(), walking: true);
  }

  /// Within range of the destination: say so and finish the trip on its
  /// own - no need to find the End button.
  void _arrive() {
    if (_arrived) return;
    _arrived = true;
    final l10n = AppLocalizations.of(context)!;
    if (widget.adminPreview) {
      // Test walk: keep the session open so the destination checkpoint
      // shows where the user really was when arrival fired.
      _speak(
        l10n.navArrivedTestWalk(_destinationName(l10n)),
        assertive: true,
        cueType: 'arrival',
      );
      return;
    }
    _speak(
      l10n.navArrivedFinished(_destinationName(l10n)),
      assertive: true,
      cueType: 'arrival',
    );
    _endSession(arrived: true);
  }

  /// Admin test walk: the user is standing exactly on the next checkpoint
  /// (start, a corner, the destination). Records where raw GPS and the
  /// correction put them at that moment; the destination one ends the walk.
  void _markCheckpoint() {
    final index = _checkpoints.mark();
    if (index == null) return;
    buzz(Buzz.short);
    final raw = _rawPosition;
    final corrected = _liveCorrected();
    final correctedAt = _correctedAt;
    _log.event(
      'checkpoint',
      fields: {
        'index': index,
        'of': _checkpoints.count,
        'raw': ?(raw == null ? null : [raw.latitude, raw.longitude]),
        'corrected': ?(corrected == null
            ? null
            : [corrected.latitude, corrected.longitude]),
        'correction_age_s': ?(correctedAt == null
            ? null
            : clock.now().difference(correctedAt).inMilliseconds / 1000),
      },
    );
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            l10n.navCheckpointMarked(_checkpointLabel(l10n, index)),
          ),
        ),
      );
    setState(() {});
    if (_checkpoints.done) _endSession(arrived: _arrived);
  }

  void _undoCheckpoint() {
    final index = _checkpoints.undo();
    if (index == null) return;
    _log.event('checkpoint_undo', fields: {'index': index});
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            l10n.navCheckpointUndone(_checkpointLabel(l10n, index)),
          ),
        ),
      );
    setState(() {});
  }

  String _checkpointLabel(AppLocalizations l10n, int index) => index == 0
      ? l10n.navCheckpointStart
      : index == _checkpoints.count - 1
      ? l10n.navCheckpointDestination
      : l10n.navCheckpointCorner(index);

  /// While walking a leg, a short "N meters ahead" every
  /// `_kPeriodicAnnouncementInterval` fills long silent stretches - but
  /// only if nothing else was said recently, and never while the user is
  /// still turning.
  void _announcePeriodicDistance() {
    if (!_guiding || _stopped || _arrived || !mounted) return;
    if (!_guidance.walking || _nextWaypointIndex >= _waypoints.length) return;
    if (_floorChange != null) return;
    final lastSpoken = _lastSpokenAt;
    if (lastSpoken != null &&
        clock.now().difference(lastSpoken) < _kQuietBeforePeriodic) {
      return;
    }
    final here = _currentPosition();
    if (here == null) return;
    final distance = haversineMeters(
      here,
      _waypoints[_nextWaypointIndex].point,
    );
    if (distance <= _kProximityThresholdMeters) return;
    final l10n = AppLocalizations.of(context)!;
    switch (progressSince(lastMeters: _progressMeters, meters: distance)) {
      case Progress.same:
        // Not getting closer: "N steps to go" as if it were progress doesn't
        // help, but neither did the silence (Icesi, 2026-11-05).
        final spoken = _lastSpokenAt;
        if (spoken == null ||
            clock.now().difference(spoken) >= _kQuietBeforeKeepWalking) {
          _sayKeepWalking(distance);
        }
        return;
      case Progress.closer:
        final steps = roundSteps(distance);
        _progressMeters = distance;
        if (steps == _progressSteps) return;
        _progressSteps = steps;
        _speak(l10n.navStepsAhead(steps), cueType: 'meters_ahead');
      case Progress.away:
        _resetProgress(distance);
        _speak(l10n.navMovingAway, cueType: 'away');
        _turnBackTowardTarget(here);
    }
  }

  /// After "you're moving away": with a trusted heading, face-then-walk
  /// takes over (TurnGuidance orients again); otherwise, while walking,
  /// the GPS direction of travel says which way to turn.
  void _turnBackTowardTarget(LatLng here) {
    final now = clock.now();
    if (_reliableHeading() != null) {
      _guidance.reset(now: now);
      return;
    }
    final position = _locationService.lastPosition;
    final segmentStart = _segmentStart();
    if (position == null ||
        position.speed < _kMinSpeedForGpsHeading ||
        segmentStart == null) {
      return;
    }
    final turn = signedTurn(
      position.heading,
      guidanceBearing(here, segmentStart, _waypoints[_nextWaypointIndex].point),
    );
    if (turn.abs() <= TurnGuidance.alignedDegrees) return;
    final l10n = AppLocalizations.of(context)!;
    _speak(turnWords(l10n, TurnCue.from(turn)), cueType: 'turn');
  }

  Future<void> _initCamera() async {
    // Null when unavailable (no hardware, permission denied, etc.) -
    // correction ticks below then fall back to raw-GPS-only logging.
    final controller = await widget.sensors.camera();
    if (controller == null) return;
    if (_stopped) {
      await controller.dispose();
      return;
    }
    _cameraController = controller;
    if (mounted) setState(() {});
  }

  Future<void> _startSession() async {
    final userId = _userId;
    if (userId == null) {
      // Called from initState, where the strings can't be read yet: it
      // threw, and "not signed in" never showed.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _error = AppLocalizations.of(context)!.commonNotSignedIn;
          _starting = false;
        });
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
              // The phone, for the trip report (B2).
              'device_info': await widget.sensors.device(),
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
        _speak(l10n.navAnnouncementCameraDisclosure, repeatable: false);
        // Once: TalkBack used to read the notice again and again on top
        // of the voice (#257).
        showSpokenNotice(context, l10n.navAnnouncementCameraDisclosure);
      }
      // The first instruction comes from _guide once the route is loaded
      // (_speakStartCue).
      _guidance.reset(now: clock.now());
      _needsStartCue = true;
      _guiding = true;
      _loop.start();
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

  /// Per-tick diagnostics for tuning (navigation_logs.debug): what
  /// guidance saw and decided, plus everything said since the last tick.
  /// [correction] is backend-positioning's own `debug`, when there is one.
  Map<String, dynamic> _debugSnapshot(
    Position position, {
    Map<String, dynamic>? correction,
    String? failure,
    Map<String, int>? timing,
    DateTime? photoAt,
  }) {
    final correctedAt = _correctedAt;
    final snapshot = <String, dynamic>{
      'compass': _heading.value,
      'compass_raw': _lastRawCompass,
      'compass_accuracy': _lastCompassAccuracy,
      'heading': _tracker.value,
      'heading_source': _tracker.source,
      'heading_reliable': _tracker.reliable(clock.now()),
      // Which mode the trip ran in, for reading the logs (#257).
      'talkback': _screenReader,
      'pressure_hpa': _floorDetector.pressure,
      'floor': _currentFloor,
      'waiting_floor': _floorChange?.floor,
      'gyroscope': _tracker.hasGyroscope,
      // How far the compass (true) is from the tracked heading: magnetic
      // disturbance shows up here.
      'compass_vs_heading': _tracker.value == null || _heading.value == null
          ? null
          : signedTurn(
              _tracker.value!,
              trueHeading(_heading.value!, _declination),
            ),
      'gps_speed': position.speed,
      'gps_course': position.heading,
      'gps_time': position.timestamp.toUtc().toIso8601String(),
      'position_source': _lastUsedCorrected ? 'corrected' : 'raw',
      'correction_age_s': correctedAt == null
          ? null
          : clock.now().difference(correctedAt).inMilliseconds / 1000,
      'target_index': _nextWaypointIndex,
      'target_distance_m': _lastTargetDistance,
      'target_bearing': _lastTargetBearing,
      'turn': _lastTurn,
      'guidance': _guidance.walking ? 'walking' : 'orienting',
      ..._log.drain(),
      'correction': ?correction,
      'failure': ?failure,
      'timing_ms': ?timing,
      'photo_at': ?photoAt?.toUtc().toIso8601String(),
    };
    return snapshot;
  }

  /// The heading sent with a photo: the tracked heading back in magnetic
  /// degrees, like the anchor photos' own (the compass alone, when there's
  /// no tracker heading yet), so the heading gate compares like with like.
  /// Never the GPS course: meaningless while standing still.
  double? _sentHeading() {
    final tracked = _reliableHeading();
    return tracked == null ? null : trueHeading(tracked, -_declination);
  }

  /// A correction came back for [fix]: the green marker and guidance use
  /// it, through the offset from that fix (see _liveCorrected).
  void _applyCorrection(Map<String, dynamic> result, Position fix) {
    if (!mounted) return;
    setState(() {
      _correctedLat = (result['corrected_lat'] as num).toDouble();
      _correctedLong = (result['corrected_long'] as num).toDouble();
      _correctionError = (result['correction_error'] as num).toDouble();
      _correctedAt = clock.now();
      _correctionOffset = offsetMeters(
        fix.latLng,
        LatLng(_correctedLat!, _correctedLong!),
      );
    });
  }

  /// The lens looks covered: said (assertive) and shown, once per streak.
  void _sayCameraBlocked() {
    if (!mounted) return;
    final text = AppLocalizations.of(context)!.navAnnouncementCameraBlocked;
    _speak(text, assertive: true);
    showSpokenNotice(context, text);
  }

  /// Admin test flow: records the last instruction as wrong, with where it
  /// happened and what guidance saw, for the session view and tuning.
  Future<void> _reportWrongInstruction() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    buzz(Buzz.short);
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
        'corrected_lat': _liveCorrected()?.latitude ?? _correctedLat,
        'corrected_long': _liveCorrected()?.longitude ?? _correctedLong,
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
    _loop.stop();
    _guidanceTimer?.cancel();
    _loadingTimer?.cancel();
    _barometerProbeTimer?.cancel();
    _barometerSub?.cancel();
    _periodicAnnouncementTimer?.cancel();
    _compassSub?.cancel();
    _gyroSub?.cancel();
    _accelSub?.cancel();
    _positionSub?.cancel();
    if (sessionId == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() => _ending = true);
    final position = _locationService.lastPosition;
    // One last tick before the session is closed, carrying what happened
    // since the previous one - the arrival above all. It used to be lost
    // whenever the camera loop's own tick was still in flight.
    if (position != null && _log.hasPending) {
      await _loop.logRaw(sessionId, position);
    }
    try {
      await _navigationApi.patch('/sessions/$sessionId', {
        'status': 'completed',
        'end_time': clock.now().toUtc().toIso8601String(),
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
        // Said aloud just before (#257).
        title: SpokenText(child: Text(l10n.navFeedbackTitle)),
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
              final userId = _userId;
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
    WidgetsBinding.instance.removeObserver(this);
    widget.sensors.keepAwake(false);
    _loop.stop();
    _periodicAnnouncementTimer?.cancel();
    _guidanceTimer?.cancel();
    _loadingTimer?.cancel();
    _barometerProbeTimer?.cancel();
    _barometerSub?.cancel();
    _compassSub?.cancel();
    _gyroSub?.cancel();
    _accelSub?.cancel();
    _positionSub?.cancel();
    _cameraController?.dispose();
    _voice.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final live = _liveCorrected();
    final correctedLat = live?.latitude ?? _correctedLat;
    final correctedLong = live?.longitude ?? _correctedLong;
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
                      // Coordinates and the map are for admins testing the
                      // flow; a user test asked for them off the user's
                      // screen, and users didn't know what "the map" to tap
                      // was.
                      LocationInfo(showCoordinates: widget.adminPreview),
                      if (widget.adminPreview) ...[
                        if (correctedLat != null && correctedLong != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16.0,
                            ),
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
                      ],
                      // Users with low vision can turn the map on (D2); the
                      // coordinates above stay for admins.
                      if (widget.adminPreview || showMapNotifier.value) ...[
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
                                plannedPathFloors: _plannedFloors,
                                currentFloor: _currentFloor,
                                extraMarkers:
                                    correctedLat != null &&
                                        correctedLong != null
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
                      ] else ...[
                        const Spacer(),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(160),
                              textStyle: Theme.of(
                                context,
                              ).textTheme.headlineSmall,
                            ),
                            onPressed: _repeatLastAnnouncement,
                            icon: const Icon(Icons.replay, size: 40),
                            label: Text(l10n.navRepeatButton),
                          ),
                        ),
                        const Spacer(),
                      ],
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
                      if (widget.adminPreview && _checkpoints.next != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                          child: GestureDetector(
                            onLongPress: _undoCheckpoint,
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.blue.shade700,
                                minimumSize: const Size.fromHeight(56),
                              ),
                              onPressed: _sessionId == null || _ending
                                  ? null
                                  : _markCheckpoint,
                              icon: const Icon(Icons.flag),
                              label: Text(
                                l10n.navCheckpointButton(
                                  _checkpointLabel(l10n, _checkpoints.next!),
                                ),
                              ),
                            ),
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

/// The trip's camera, for [CorrectionLoop].
class _Lens implements TripCamera {
  _Lens(this._controller);

  final CameraController _controller;

  @override
  bool get ready => _controller.value.isInitialized;

  @override
  Future<TripPhoto> take() async {
    final image = await _controller.takePicture();
    return (
      bytes: await image.readAsBytes(),
      filename: path.basename(image.path),
    );
  }
}
