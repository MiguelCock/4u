import 'dart:async';
import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_compass/flutter_compass.dart';
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

/// How close (meters) the live GPS fix needs to be to a waypoint before
/// it's announced as "approaching"/"arrived" - roughly in line with GPS's
/// own typical accuracy, so it doesn't fire too early or never fire at all.
const double _kProximityThresholdMeters = 20.0;

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

  const NavigationScreen({super.key, required this.route});

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
      if (heading != null) _heading.add(heading);
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
  Future<void> _speak(String text, {bool assertive = false}) async {
    _lastAnnouncement = text;
    _lastSpokenAt = DateTime.now();
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
    _speak(text, assertive: true);
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
    final waypoints = <_Waypoint>[];
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
        if (i > 0) {
          final description = (anchor['location_description'] as String? ?? '')
              .trim();
          // The final point is always named when spoken (falling back to
          // "your destination"); in-between ones only if they're a real
          // destination-type place.
          final named =
              description.isNotEmpty &&
              (i == anchorIds.length - 1 || isDestinationAnchor(anchor));
          waypoints.add(
            _Waypoint(point: point, name: named ? description : null),
          );
        }
      } on ApiException {
        // The guidance line/checkpoints are a nice-to-have overlay - a
        // missing/deleted anchor shouldn't block navigation, it just means
        // no line/announcement for that point.
      }
    }
    if (mounted) {
      setState(() {
        _plannedPath = points;
        _waypoints = waypoints;
      });
    }
    if (!_pathLoaded.isCompleted) _pathLoaded.complete();
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
      return LatLng(_correctedLat!, _correctedLong!);
    }
    final position = _locationService.lastPosition;
    return position == null
        ? null
        : LatLng(position.latitude, position.longitude);
  }

  /// Compass heading, or GPS direction of travel while actually moving if
  /// the phone has no compass. Null when neither is usable.
  double? _currentHeading() {
    final compass = _heading.value;
    if (compass != null) return compass;
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
    final cue = _guidance.update(
      turn: signedTurn(heading, bearingDegrees(here, target)),
      metersToTarget: haversineMeters(here, target),
      now: DateTime.now(),
    );
    final l10n = AppLocalizations.of(context)!;
    switch (cue) {
      case TurnCue(turnAround: true):
        _speak(l10n.navTurnAround);
      case TurnCue(:final degrees, :final right):
        _speak(right ? l10n.navTurnRight(degrees) : l10n.navTurnLeft(degrees));
      case StartWalkingCue(:final meters):
        _speak(l10n.navStartWalking(meters));
      case null:
        break;
    }
  }

  /// Waypoint progress. Reaching any upcoming waypoint counts, not only
  /// the next one, so a noisy fix that skips past a point doesn't leave
  /// guidance stuck waiting for it. Reaching the last one finishes the trip.
  /// Returns true when something was announced.
  bool _checkProximity(LatLng here) {
    var reached = -1;
    for (var i = _nextWaypointIndex; i < _waypoints.length; i++) {
      if (haversineMeters(here, _waypoints[i].point) <=
          _kProximityThresholdMeters) {
        reached = i;
      }
    }
    if (reached == -1) return false;
    if (reached == _waypoints.length - 1) {
      _arrive();
      return true;
    }
    _nextWaypointIndex = reached + 1;
    _announceNextLeg(_waypoints[reached], _waypoints[_nextWaypointIndex]);
    return true;
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
    _speak(name == null ? action : '${l10n.navAtPlace(name)} $action');
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
    _speak(AppLocalizations.of(context)!.navMetersAhead(roundMeters(distance)));
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
    try {
      final result = await _navigationApi.post('/sessions', {
        'user_id': userId,
        'building_id': widget.route['building_id'],
        'route_id': widget.route['id'],
        if (startPosition != null)
          'start_position': {
            'latitude': startPosition.latitude,
            'longitude': startPosition.longitude,
          },
        'device_info': {'platform': Platform.isAndroid ? 'android' : 'other'},
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
        _speak(l10n.navStartingTo(_destinationName(l10n)));
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

  Future<void> _logRawTick(String sessionId, Position position) async {
    try {
      await _navigationApi.post('/logs', {
        'session_id': sessionId,
        'gps_lat': position.latitude,
        'gps_long': position.longitude,
        'gps_accuracy': position.accuracy,
        'heading': position.heading,
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
        await _logRawTick(sessionId, position);
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
                  'heading': position.heading.toString(),
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
      });
    } catch (_) {
      // Camera capture or /correct_position failed (unreachable, slow,
      // unauthenticated, etc.) - degrade to a raw-GPS-only tick rather than
      // dropping this tick entirely.
      await _logRawTick(sessionId, position);
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
