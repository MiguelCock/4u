import 'dart:async';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:geolocator/geolocator.dart';

import '../services/api_service.dart';
import '../services/correction_request.dart';
import '../services/image_utils.dart';
import '../services/test_walk.dart';
import 'trip_log.dart';

/// A photo the trip took: its bytes and file name.
typedef TripPhoto = ({Uint8List bytes, String filename});

/// The camera, as the correction loop needs it.
abstract interface class TripCamera {
  /// Ready to take a photo.
  bool get ready;
  Future<TripPhoto> take();
}

/// A tick's `debug` map ([DebugSnapshot] is the screen's: it knows the
/// compass, the guidance and the floors).
typedef DebugSnapshot =
    Map<String, dynamic> Function(
      Position fix, {
      Map<String, dynamic>? correction,
      String? failure,
      Map<String, int>? timing,
      DateTime? photoAt,
    });

/// The trip's position correction, once a second (Phase C): a photo and
/// the GPS fix to `/correct_position`, then the answer and a `POST /logs`.
/// Any failure (no camera, a covered lens, the server down or slow) logs a
/// raw-GPS tick instead: it never stops the trip.
///
/// Ticks start every second (`nextTickDelay`), not a second after the last
/// one finished, which made the "1 s" loop run every ~3.7 s. After an answer
/// saying `server_busy`, no photo is sent for 5 s and ticks are 3 s apart.
class CorrectionLoop {
  CorrectionLoop({
    required this.api,
    required this.log,
    required this.sessionId,
    required this.position,
    required this.camera,
    required this.debug,
    required this.heading,
    required this.onCorrected,
    required this.onCameraBlocked,
    required this.onNewMatch,
    this.storeFrame = false,
    this.timeout = const Duration(seconds: 8),
    this.blockedAfter = 3,
  });

  final PositioningApi api;
  final TripLog log;
  final String? Function() sessionId;
  final Position? Function() position;
  final TripCamera? Function() camera;
  final DebugSnapshot debug;

  /// The direction the camera faces as a photo is taken (magnetic), or
  /// null to skip the backend's heading gate.
  final double? Function() heading;

  /// A correction came back, for [fix].
  final void Function(Map<String, dynamic> result, Position fix) onCorrected;

  /// The lens looks covered on [blockedAfter] ticks in a row: said once per
  /// streak, so one dim hallway doesn't count.
  final void Function() onCameraBlocked;

  /// A photo matched an anchor point other than the last one matched.
  final void Function() onNewMatch;

  /// Test walks keep their frames (backend-positioning's store_frame).
  final bool storeFrame;
  final Duration timeout;
  final int blockedAfter;

  bool _stopped = false;
  Timer? _next;
  DateTime? _pausedUntil;
  int _blockedStreak = 0;
  bool _blockedSaid = false;
  String? _lastMatchId;

  /// Starts ticking, and keeps going until [stop].
  void start() {
    _stopped = false;
    _tick();
  }

  void stop() {
    _stopped = true;
    _next?.cancel();
  }

  Future<void> _tick() async {
    if (_stopped) return;
    final started = clock.now();
    final id = sessionId();
    final fix = position();
    final paused = photoPaused(started, _pausedUntil);
    try {
      if (id == null || fix == null) return;
      if (paused) {
        await logRaw(id, fix, failure: 'server_busy');
        return;
      }
      final lens = camera();
      if (lens == null || !lens.ready) {
        await logRaw(id, fix);
        return;
      }
      await _correct(id, fix, lens);
    } finally {
      if (!_stopped) {
        _next = Timer(
          nextTickDelay(
            clock.now().difference(started),
            period: paused ? pausedTickPeriod : const Duration(seconds: 1),
          ),
          _tick,
        );
      }
    }
  }

  /// A tick with the GPS fix alone, saying why when it's a [failure].
  Future<void> logRaw(String id, Position fix, {String? failure}) => log.post({
    'session_id': id,
    'gps_lat': fix.latitude,
    'gps_long': fix.longitude,
    'gps_accuracy': fix.accuracy,
    'heading': fix.heading,
    'debug': debug(fix, failure: failure),
  });

  Future<void> _correct(String id, Position fix, TripCamera lens) async {
    try {
      final captureStarted = clock.now();
      // The direction the camera faces as the photo is taken, not when the
      // answer comes back.
      final sentHeading = heading();
      final photo = await lens.take();
      final captureMs = clock.now().difference(captureStarted).inMilliseconds;

      if (isFrameBlocked(photo.bytes)) {
        _blockedStreak++;
        if (_blockedStreak >= blockedAfter && !_blockedSaid) {
          _blockedSaid = true;
          onCameraBlocked();
        }
        await logRaw(id, fix, failure: 'camera_blocked');
        return;
      }
      _blockedStreak = 0;
      _blockedSaid = false;

      final correctStarted = clock.now();
      final result = await postCorrection(
        api,
        bytes: photo.bytes,
        filename: photo.filename,
        sessionId: id,
        fix: fix,
        heading: sentHeading,
        storeFrame: storeFrame,
        timeout: timeout,
      );
      final correctMs = clock.now().difference(correctStarted).inMilliseconds;

      if (result['server_busy'] == true) {
        _pausedUntil = clock.now().add(photoPauseWhenBusy);
      }
      onCorrected(result, fix);

      // Once per *newly* matched anchor point, not every tick confirming the
      // same match: that would be constant buzzing (#83).
      final matchId = result['anchor_match_id'] as String?;
      if (matchId != null && matchId != _lastMatchId) {
        _lastMatchId = matchId;
        onNewMatch();
      }

      // Not awaited: the next photo shouldn't wait on the log upload.
      unawaited(
        log.post({
          'session_id': id,
          'gps_lat': fix.latitude,
          'gps_long': fix.longitude,
          'gps_accuracy': fix.accuracy,
          'heading': fix.heading,
          'corrected_lat': result['corrected_lat'],
          'corrected_long': result['corrected_long'],
          'correction_error': result['correction_error'],
          'anchor_match_id': result['anchor_match_id'],
          'confidence_score': result['confidence_score'],
          'raw_image_url': result['raw_image_url'],
          'debug': debug(
            fix,
            correction: (result['debug'] as Map?)?.cast<String, dynamic>(),
            timing: {'capture': captureMs, 'correct': correctMs},
            photoAt: captureStarted,
          ),
        }),
      );
    } catch (e) {
      // The photo or /correct_position failed (unreachable, slow,
      // unauthenticated...): a raw-GPS tick rather than none.
      await logRaw(
        id,
        fix,
        failure: e is ApiException
            ? 'api_${e.statusCode}'
            : e.runtimeType.toString(),
      );
    }
  }
}
