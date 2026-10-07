import 'dart:async';
import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as path;
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../location.dart';
import '../map.dart';
import '../services/api_service.dart';
import '../services/app_preferences.dart';
import '../services/geo_utils.dart';
import '../services/location_service.dart';

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

  @override
  void initState() {
    super.initState();
    _startSession();
    _initCamera();
    _loadPlannedPath();
  }

  /// Speaks [text] if the user has voice guidance on (#39/#40/#85) -
  /// voiceGuidanceNotifier is the same app_preferences.dart pattern
  /// high_contrast/font_scale already use, just read directly here rather
  /// than via a ValueListenableBuilder, since this screen doesn't need to
  /// rebuild when it changes, only to check it at the moment of an
  /// announcement.
  Future<void> _speak(String text) async {
    if (!voiceGuidanceNotifier.value) return;
    await _tts.speak(text);
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

  Future<void> _initCamera() async {
    if (await Permission.camera.request() != PermissionStatus.granted) return;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;
      final controller = CameraController(
        cameras.first,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await controller.initialize();
      if (_stopped) {
        await controller.dispose();
        return;
      }
      _cameraController = controller;
      if (mounted) setState(() {});
    } catch (_) {
      // Camera unavailable (no hardware, denied mid-flow, etc.) -
      // correction ticks below fall back to raw-GPS-only logging.
    }
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
        _speak(
          AppLocalizations.of(
            context,
          )!.navAnnouncementStarting(widget.route['name'] as String? ?? ''),
        );
      }
      _runTick();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = AppLocalizations.of(
          context,
        )!.navFailedToStartSession(e.toString());
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
                          child: Text(
                            _error!,
                            style: const TextStyle(color: Colors.red),
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
                      Expanded(
                        child: SimpleMapWidget(
                          plannedPath: _plannedPath,
                          extraMarkers:
                              correctedLat != null && correctedLong != null
                              ? [
                                  Marker(
                                    point: LatLng(correctedLat, correctedLong),
                                    width: 80,
                                    height: 80,
                                    child: const Icon(
                                      Icons.location_pin,
                                      color: Colors.green,
                                      size: 40,
                                    ),
                                  ),
                                ]
                              : const [],
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
                      top: 8,
                      right: 8,
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
