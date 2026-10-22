import 'dart:async';
import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
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
import '../services/geo_utils.dart';
import '../services/image_utils.dart';
import '../services/location_service.dart';
import '../services/speech_voice.dart';
import '../services/api_error_messages.dart';

/// A resolved checkpoint along the planned route - an anchor point's
/// coordinates plus its description, used for proximity announcements
/// (#40). Deliberately distance-based only, not compass-bearing turn
/// detection ("turn left") - see this file's `_checkProximity` doc comment.
class _Waypoint {
  final LatLng point;
  final String description;

  const _Waypoint({required this.point, required this.description});
}

/// How close (meters) the live GPS fix needs to be to a waypoint before
/// it's announced as "approaching"/"arrived" - roughly in line with GPS's
/// own typical accuracy, so it doesn't fire too early or never fire at all.
const double _kProximityThresholdMeters = 20.0;

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
          waypoints.add(
            _Waypoint(
              point: point,
              description:
                  anchor['location_description'] as String? ?? anchorIds[i],
            ),
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
  }

  /// Distance-based proximity announcements, not full compass-bearing
  /// turn-by-turn ("turn left in 20 meters") - #40's literal ask - that
  /// would need comparing the device's compass heading against the bearing
  /// to the next waypoint, a deliberate scope cut for a follow-up. This
  /// announces each waypoint in order once the live GPS fix comes within
  /// `_kProximityThresholdMeters` of it, skipping ahead past any waypoint
  /// never reached within range (e.g. a noisy fix overshot it) rather than
  /// getting stuck waiting for an exact hit.
  void _checkProximity(Position position) {
    if (_nextWaypointIndex >= _waypoints.length) return;
    final here = LatLng(position.latitude, position.longitude);
    final target = _waypoints[_nextWaypointIndex];
    if (haversineMeters(here, target.point) > _kProximityThresholdMeters) {
      return;
    }
    final isLast = _nextWaypointIndex == _waypoints.length - 1;
    final l10n = AppLocalizations.of(context)!;
    _speak(
      isLast
          ? l10n.navAnnouncementArrived(target.description)
          : l10n.navAnnouncementApproaching(target.description),
    );
    _nextWaypointIndex++;
  }

  /// Fills the gap between arrival-based announcements with an ongoing
  /// "N meters to X" update, every `_kPeriodicAnnouncementInterval` - only
  /// while still outside `_kProximityThresholdMeters`, so this never
  /// doubles up with `_checkProximity`'s own announcement right at the
  /// threshold. Distance is rounded to the nearest 10m since a raw GPS
  /// distance jitters tick to tick - an exact-looking number would be
  /// misleadingly precise.
  void _announcePeriodicDistance() {
    if (_stopped || !mounted) return;
    if (_nextWaypointIndex >= _waypoints.length) return;
    final position = _locationService.lastPosition;
    if (position == null) return;
    final target = _waypoints[_nextWaypointIndex];
    final distance = haversineMeters(
      LatLng(position.latitude, position.longitude),
      target.point,
    );
    if (distance <= _kProximityThresholdMeters) return;
    final rounded = (distance / 10).round() * 10;
    _speak(
      AppLocalizations.of(
        context,
      )!.navAnnouncementDistanceToNext(rounded, target.description),
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
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        _speak(
          l10n.navAnnouncementStarting(widget.route['name'] as String? ?? ''),
        );
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
      if (mounted) _checkProximity(position);
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

  Future<void> _endSession() async {
    final sessionId = _sessionId;
    _stopped = true;
    _pendingTickTimer?.cancel();
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
    if (mounted) {
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
        title: Text(widget.route['name'] as String? ?? l10n.navDefaultTitle),
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
                          onPressed: _ending ? null : _endSession,
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
