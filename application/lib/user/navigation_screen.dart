import 'dart:async';

import '../voice/home_voice_controller.dart';
import '../services/trip_commands.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:camera/camera.dart';
import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
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
import '../services/geo_utils.dart';
import '../services/heading_tracker.dart';
import '../services/location_service.dart';
import '../voice/app_voice.dart';
import '../voice/trip_announcer.dart';
import '../voice/notices.dart';
import '../services/buzz.dart';
import '../services/route_points.dart';
import '../services/test_walk.dart';
import '../services/turn_guidance.dart';
import '../services/trip_plan.dart';
import '../services/trip_sessions.dart';
import 'correction_loop.dart';
import 'trip_feedback.dart';
import 'position_source.dart';
import 'leg_progress.dart';
import 'route_progress.dart';
import 'trip_log.dart';
import 'trip_guide.dart';
import 'trip_sensors.dart';
import '../services/api_error_messages.dart';
import '../voice/skip_speech.dart';

/// No barometer reading this long after opening: the phone hasn't got one.
const Duration _kBarometerProbe = Duration(seconds: 3);

/// No progress cue for this long after the screen opens unless something
/// else was said: "Preparing the route", then "One moment" every
/// [_kLoadingRepeat] until the first instruction. Testers didn't know
/// whether the app was working (Icesi, 2026-11-03).
const Duration _kLoadingNotice = Duration(milliseconds: 1500);
const Duration _kLoadingRepeat = Duration(seconds: 6);

/// How often turn guidance re-evaluates heading vs bearing. Independent of
/// the ~1s camera-correction loop, which can run slower.
const Duration _kGuidanceInterval = Duration(milliseconds: 500);

/// Navigation's per-tick calls: an answer later than this is useless, and
/// waiting the default 60 s stalled the whole loop (no logs, stale
/// correction) through a ~20 s connection drop in a field test.
const Duration _kTickRequestTimeout = Duration(seconds: 8);

/// How often (while still outside `RouteProgress.proximityMeters` of the next
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

  /// The recognizer for spoken commands (#228); the app's own by default.
  final SpeechToText? speech;

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
    this.speech,
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

  /// How the trip speaks, through its right to speak: claimed as the trip
  /// starts, so whatever the home screen was still saying is dropped (#258).
  late final TripAnnouncer _announcer;
  String? _sessionId;
  CameraController? _cameraController;

  Timer? _periodicAnnouncementTimer;
  Timer? _guidanceTimer;
  Timer? _loadingTimer;
  Timer? _barometerProbeTimer;
  StreamSubscription<double>? _barometerSub;
  final _route = RouteProgress();
  bool _barometerSeen = false;

  int? _startTypeId;

  /// Progress along the leg being walked: the stall check and the
  /// periodic update.
  final _leg = LegProgress();

  final _recentFixes = RecentFixes();

  /// When the app was paused (the screen went off, say).
  DateTime? _pausedAt;
  List<int> _plannedFloors = const [];

  StreamSubscription<CompassReading>? _compassSub;
  final _heading = HeadingSmoother();
  final _tracker = HeadingTracker();
  StreamSubscription<AxisReading>? _gyroSub;
  StreamSubscription<AxisReading>? _accelSub;
  StreamSubscription<Position>? _positionSub;
  final _pathLoaded = Completer<void>();
  bool _stopped = false;

  /// Admin test walk: the checkpoints still to tap (see test_walk.dart),
  /// one per route corner plus the start and the destination.
  CheckpointSequence _checkpoints = CheckpointSequence(0);

  /// Magnetic declination (degrees, east positive) - see trueHeading().
  final double _declination =
      double.tryParse(dotenv.env['MAGNETIC_DECLINATION'] ?? '') ?? -7.5;

  bool _starting = true;
  bool _ending = false;
  String? _error;

  /// Where guidance thinks the user is: corrected, raw, or between.
  final _where = PositionSource();
  List<LatLng> _plannedPath = [];
  List<Waypoint> get _waypoints => _route.waypoints;

  /// The trip's turn-by-turn guidance (see TripGuide).
  late final _guide = TripGuide(
    route: _route,
    leg: _leg,
    tracker: _tracker,
    compass: _heading,
    announcer: _announcer,
    log: _log,
    l10n: () => AppLocalizations.of(context)!,
    position: _currentPosition,
    raw: () => _rawPosition,
    lastFix: () => _locationService.lastPosition,
    barometerSeen: () => _barometerSeen,
    startTypeId: () => _startTypeId,
    pathLoaded: () => _pathLoaded.isCompleted,
    destinationName: () => _destinationName(AppLocalizations.of(context)!),
    onArrived: () => _endSession(arrived: true),
    onChanged: () {
      if (mounted) setState(() {});
    },
    restartGps: _locationService.restart,
    declination: _declination,
    adminPreview: widget.adminPreview,
  );

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
    // True north and trusted only: the filter's walking direction (#120).
    walkHeading: _guide.reliableHeading,
    onCorrected: _applyCorrection,
    onCameraBlocked: _sayCameraBlocked,
    onNewMatch: HapticFeedback.selectionClick,
    storeFrame: widget.adminPreview,
    timeout: _kTickRequestTimeout,
  );

  /// Latest guidance inputs, kept for the per-tick diagnostics.
  double? _lastRawCompass;
  double? _lastCompassAccuracy;

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
    _tripOwner = _appVoice.claim();
    _announcer = TripAnnouncer(
      owner: _tripOwner,
      logCue: _log.cue,
      micOpen: _micOpen,
      closeMic: () => _commands?.stopListening(),
    );
    _startSession();
    _initCamera();
    _loadPlannedPath();
    _periodicAnnouncementTimer = Timer.periodic(
      _kPeriodicAnnouncementInterval,
      (_) {
        if (mounted && !_stopped) _guide.periodic();
      },
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
      if (_where.hasCorrection && mounted) setState(() {});
    });
    _guidanceTimer = Timer.periodic(_kGuidanceInterval, (_) {
      if (mounted && !_stopped) _guide.step();
    });
    _loadingTimer = Timer(_kLoadingNotice, _sayStillLoading);
    _barometerSub = widget.sensors.pressure().listen((pressure) {
      _barometerSeen = true;
      _route.detector.add(pressure, clock.now());
    }, onError: _sensorError);
    _barometerProbeTimer = Timer(_kBarometerProbe, () {
      if (_barometerSeen) return;
      _log.event('barometer_missing');
    });
  }

  /// Until the first real announcement: "Preparing the route", then "One
  /// moment" every [_kLoadingRepeat].
  void _sayStillLoading() {
    if (_stopped ||
        !mounted ||
        _announcer.lastAnnouncement != null ||
        _error != null) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    _speak(
      _guide.loadingAnnounced ? l10n.commonOneMoment : l10n.navLoadingRoute,
      repeatable: false,
    );
    _guide.loadingAnnounced = true;
    _loadingTimer = Timer(_kLoadingRepeat, _sayStillLoading);
  }

  /// A sensor stream failed: logged with the next tick, so a phone whose
  /// gyroscope doesn't work shows up in the session data.
  void _sensorError(Object error) {
    _log.event('sensor_error', fields: {'error': error.toString()});
  }

  /// Speaks [text] through [_announcer] (see TripAnnouncer.speak).
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

  /// Re-speaks the most recent instruction on demand (the Repeat button, a
  /// tap on the map), and shows it for anyone with the voice or sound off.
  void _repeatLastAnnouncement() {
    final text = _announcer.repeat(
      prefix: AppLocalizations.of(context)!.navRepeatPrefix,
    );
    if (text != null) showSpokenNotice(context, text, replace: true);
  }

  /// The trip's voice, shared by guidance and the spoken commands (#228).
  late VoiceOwner _tripOwner;

  /// Spoken commands during the trip (#228), made on first use so a trip
  /// that never listens never touches the recognizer.
  HomeVoiceController? _commands;

  /// Whether a command listen has the microphone: guidance holds (R4).
  final ValueNotifier<bool> _micOpen = ValueNotifier(false);

  HomeVoiceController _ensureCommands() {
    final existing = _commands;
    if (existing != null) return existing;
    final made = HomeVoiceController(
      speech: widget.speech,
      voice: _appVoice,
      owner: _tripOwner,
    );
    made.listening.addListener(() => _micOpen.value = made.listening.value);
    return _commands = made;
  }

  /// Pauses or resumes the instructions (#228). The trip, its photos and
  /// logs go on; the voice says which it is now (R5: the button's label
  /// never changes).
  Future<void> _togglePause() async {
    final l10n = AppLocalizations.of(context)!;
    if (_announcer.paused) {
      _log.event('guidance_resumed');
      await _announcer.resume(l10n.navResumed);
    } else {
      _log.event('guidance_paused');
      await _announcer.pause(l10n.navPaused);
    }
    if (mounted) setState(() {});
  }

  /// Listens once for "pausa", "seguir" or "repetir" (#228): a long press
  /// on Repeat, or TalkBack's "Decir una orden".
  Future<void> _listenForCommand() async {
    if (_stopped) return;
    final l10n = AppLocalizations.of(context)!;
    final language = Localizations.localeOf(context).languageCode;
    await _ensureCommands().listen(
      (heard) async {
        if (!mounted || _stopped) return;
        switch (tripCommand(heard)) {
          case TripCommand.pause:
            if (!_announcer.paused) await _togglePause();
          case TripCommand.resume:
            if (_announcer.paused) await _togglePause();
          case TripCommand.repeat:
            _repeatLastAnnouncement();
          case null:
            await _announcer.speak(
              l10n.navCommandNotHeard,
              assertive: true,
              repeatable: false,
            );
        }
      },
      language: language,
      prompt: l10n.navCommandPrompt,
      listenFor: const Duration(seconds: 8),
      pauseFor: const Duration(seconds: 3),
    );
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
    if (mounted) {
      setState(() {
        _plannedPath = plan.points;
        _plannedFloors = plan.floors;
        if (plan.floors.isNotEmpty) _startTypeId = plan.startTypeId;
        _route.load(plan);
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
    if (here != null) _route.resumeNear(here);
  }

  String _destinationName(AppLocalizations l10n) =>
      widget.destinationName ??
      (_waypoints.isNotEmpty ? _waypoints.last.name : null) ??
      l10n.navYourDestination;

  /// Where guidance thinks the user is ([PositionSource.current]).
  LatLng? _currentPosition() => _where.current(_rawPosition);

  /// The live fix moved by the latest correction, while it's fresh.
  LatLng? _liveCorrected() => _where.live(_rawPosition);

  LatLng? get _rawPosition => _locationService.lastPosition?.latLng;

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

  /// Admin test walk: the user is standing exactly on the next checkpoint
  /// (start, a corner, the destination). Records where raw GPS and the
  /// correction put them at that moment; the destination one ends the walk.
  void _markCheckpoint() {
    final index = _checkpoints.mark();
    if (index == null) return;
    buzz(Buzz.short);
    final raw = _rawPosition;
    final corrected = _liveCorrected();
    final correctedAt = _where.correctedAt;
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
    if (_checkpoints.done) _endSession(arrived: _guide.arrived);
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
      _route.needsStartCue = true;
      _guide.start();
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
    final correctedAt = _where.correctedAt;
    final snapshot = <String, dynamic>{
      'compass': _heading.value,
      'compass_raw': _lastRawCompass,
      'compass_accuracy': _lastCompassAccuracy,
      'heading': _tracker.value,
      'heading_source': _tracker.source,
      'heading_reliable': _tracker.reliable(clock.now()),
      // Which mode the trip ran in, for reading the logs (#257).
      'talkback': _screenReader,
      'pressure_hpa': _route.detector.pressure,
      'floor': _route.floor,
      'waiting_floor': _route.floorChange?.floor,
      'gyroscope': _tracker.hasGyroscope,
      // How the phone is held and how much the body sways it (#263).
      'pitch': _tracker.pitchDeg,
      'roll': _tracker.rollDeg,
      'heading_sway': _tracker.swayDeg(clock.now()),
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
      'position_source': _where.usedCorrected ? 'corrected' : 'raw',
      'correction_age_s': correctedAt == null
          ? null
          : clock.now().difference(correctedAt).inMilliseconds / 1000,
      'target_index': _route.next,
      'target_distance_m': _guide.lastTargetDistance,
      'target_bearing': _guide.lastTargetBearing,
      'turn': _guide.lastTurn,
      'guidance': _guide.walking ? 'walking' : 'orienting',
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
    final tracked = _guide.reliableHeading();
    return tracked == null ? null : trueHeading(tracked, -_declination);
  }

  /// A correction came back for [fix]: the green marker and guidance use
  /// it, through the offset from that fix (see _liveCorrected).
  void _applyCorrection(Map<String, dynamic> result, Position fix) {
    if (!mounted) return;
    setState(
      () => _where.correct(
        fix.latLng,
        LatLng(
          (result['corrected_lat'] as num).toDouble(),
          (result['corrected_long'] as num).toDouble(),
        ),
        (result['correction_error'] as num).toDouble(),
      ),
    );
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
    final instruction = _announcer.lastAnnouncement;
    try {
      await _navigationApi.post('/guidance-reports', {
        'session_id': sessionId,
        'instruction_text': instruction,
        'cue_type': _announcer.lastCueType,
        'waypoint_index': _route.next,
        if (position != null) ...{
          'gps_lat': position.latitude,
          'gps_long': position.longitude,
        },
        'corrected_lat':
            _liveCorrected()?.latitude ?? _where.corrected?.latitude,
        'corrected_long':
            _liveCorrected()?.longitude ?? _where.corrected?.longitude,
        'compass_heading': _heading.value,
        'debug': {
          'turn': _guide.lastTurn,
          'target_distance_m': _guide.lastTargetDistance,
          'target_bearing': _guide.lastTargetBearing,
          'position_source': _where.usedCorrected ? 'corrected' : 'raw',
          'guidance': _guide.walking ? 'walking' : 'orienting',
          'gps_accuracy': position?.accuracy,
          'correction_error': _where.correctionError,
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
    _guide.guiding = false;
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
      await closeSession(
        _navigationApi,
        sessionId,
        status: 'completed',
        at: position,
      );
    } on ApiException catch (_) {
      // Session end best-effort too - still let the user leave the screen.
    }
    if (mounted && !arrived) {
      await _speak(AppLocalizations.of(context)!.navAnnouncementEnded);
    }
    if (mounted) {
      await showTripFeedback(
        context,
        api: _navigationApi,
        sessionId: sessionId,
        userId: _userId,
        speak: _speak,
      );
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _stopped = true;
    WidgetsBinding.instance.removeObserver(this);
    widget.sensors.keepAwake(false);
    _loop.stop();
    _commands?.dispose();
    _micOpen.dispose();
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
    _announcer.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final live = _liveCorrected();
    final correctedLat = live?.latitude ?? _where.corrected?.latitude;
    final correctedLong = live?.longitude ?? _where.corrected?.longitude;
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
                                _where.correctionError != null
                                    ? ' (±${_where.correctionError!.toStringAsFixed(2)}m)'
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
                            customSemanticsActions: {
                              CustomSemanticsAction(
                                label: l10n.voiceQuietAction,
                              ): _appVoice.skip,
                            },
                            child: ExcludeSemantics(
                              child: SimpleMapWidget(
                                onTap: _repeatLastAnnouncement,
                                plannedPath: _plannedPath,
                                plannedPathFloors: _plannedFloors,
                                currentFloor: _route.floor,
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
                          child: QuietAction(
                            child: Semantics(
                              customSemanticsActions: {
                                CustomSemanticsAction(
                                  label: l10n.navTalkAction,
                                ): _listenForCommand,
                              },
                              child: FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size.fromHeight(160),
                                  textStyle: Theme.of(
                                    context,
                                  ).textTheme.headlineSmall,
                                ),
                                onPressed: _repeatLastAnnouncement,
                                onLongPress: _listenForCommand,
                                icon: const Icon(Icons.replay, size: 40),
                                label: Text(l10n.navRepeatButton),
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                          child: QuietAction(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(72),
                                textStyle: Theme.of(
                                  context,
                                ).textTheme.titleLarge,
                              ),
                              onPressed: _togglePause,
                              icon: Icon(
                                _announcer.paused
                                    ? Icons.play_arrow
                                    : Icons.pause,
                                size: 32,
                              ),
                              label: Text(l10n.navPauseResumeButton),
                            ),
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
