import 'dart:math';
import 'dart:typed_data';

import 'package:eyes4u/user/correction_loop.dart';
import 'package:eyes4u/user/trip_log.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;

import '../support/api_fakes.dart';

/// The trip's correction tick on its own (Phase C).

Uint8List _jpg({required bool covered}) {
  final random = Random(1);
  final image = img.Image(width: 32, height: 32);
  for (final pixel in image) {
    final v = covered ? 0 : random.nextInt(256);
    pixel
      ..r = v
      ..g = v
      ..b = v;
  }
  return Uint8List.fromList(img.encodeJpg(image));
}

class _Camera implements TripCamera {
  bool covered = false;
  int taken = 0;

  @override
  bool get ready => true;

  @override
  Future<TripPhoto> take() async {
    taken++;
    return (bytes: _jpg(covered: covered), filename: 'p$taken.jpg');
  }
}

class _Setup {
  _Setup({this.camera, Map<String, dynamic>? answer, this.walking})
    : positioning = FakePositioningApi(answer: answer);

  final double? walking;

  final _Camera? camera;
  final FakePositioningApi positioning;
  final navigation = FakeNavigationApi();
  final corrected = <Map<String, dynamic>>[];
  var blocked = 0;
  var matches = 0;
  Position here = fix(6.2, -75.58);

  late final loop = CorrectionLoop(
    api: positioning,
    log: TripLog(navigation),
    sessionId: () => 's1',
    position: () => here,
    camera: () => camera,
    debug: (fix, {correction, failure, timing, photoAt}) => {
      'failure': ?failure,
    },
    heading: () => 90,
    walkHeading: () => walking,
    onCorrected: (result, fix) => corrected.add(result),
    onCameraBlocked: () => blocked++,
    onNewMatch: () => matches++,
  );

  /// Each `POST /logs`' failure, null for a tick that worked.
  List<String?> get failures => [
    for (final (path, body) in navigation.posts)
      if (path == '/logs') (body['debug'] as Map)['failure'] as String?,
  ];
}

void main() {
  setUpAll(() => dotenv.testLoad(fileInput: ''));

  test('no camera: a raw GPS tick every second', () {
    fakeAsync((async) {
      final s = _Setup();
      s.loop.start();
      async.elapse(const Duration(milliseconds: 3500));
      s.loop.stop();
      expect(s.failures, [null, null, null, null]);
      expect(s.positioning.sent, isEmpty);
      async.elapse(const Duration(seconds: 5));
      expect(s.failures, hasLength(4)); // stopped means stopped
    });
  });

  test('the trusted walking direction goes with the photo (#120)', () {
    fakeAsync((async) {
      final s = _Setup(camera: _Camera(), walking: 97.5);
      s.loop.start();
      async.elapse(const Duration(milliseconds: 500));
      s.loop.stop();
      expect(s.positioning.sent.first['walk_heading'], '97.5');
      expect(s.positioning.sent.first['heading'], '90.0');
    });
  });

  test('a photo is corrected, logged, and a new match buzzes once', () {
    fakeAsync((async) {
      final s = _Setup(
        camera: _Camera(),
        answer: {
          'corrected_lat': 6.20001,
          'corrected_long': -75.58,
          'correction_error': 2.0,
          'anchor_match_id': 'a1',
        },
      );
      s.loop.start();
      async.elapse(const Duration(milliseconds: 2500));
      s.loop.stop();
      expect(s.corrected, hasLength(3));
      expect(s.matches, 1); // the same anchor three times
      expect(s.positioning.sent.first['heading'], '90.0');
      final log = s.navigation.posts.first.$2;
      expect(log['corrected_lat'], 6.20001);
      expect(log['anchor_match_id'], 'a1');
    });
  });

  test('a covered lens: said once after three ticks, logged each time', () {
    fakeAsync((async) {
      final camera = _Camera()..covered = true;
      final s = _Setup(camera: camera, answer: const {});
      s.loop.start();
      async.elapse(const Duration(milliseconds: 1500));
      expect(s.blocked, 0);
      async.elapse(const Duration(seconds: 3));
      s.loop.stop();
      expect(s.blocked, 1);
      expect(s.failures.toSet(), {'camera_blocked'});
      expect(s.positioning.sent, isEmpty);
    });
  });

  test('server busy: no photos for 5 s, ticks 3 s apart', () {
    fakeAsync((async) {
      final camera = _Camera();
      final s = _Setup(
        camera: camera,
        answer: {
          'corrected_lat': 6.2,
          'corrected_long': -75.58,
          'correction_error': 2.0,
          'server_busy': true,
        },
      );
      s.loop.start();
      async.elapse(const Duration(milliseconds: 500));
      expect(camera.taken, 1);
      async.elapse(const Duration(seconds: 4));
      expect(camera.taken, 1);
      expect(s.failures.where((f) => f == 'server_busy'), hasLength(2));
      async.elapse(const Duration(seconds: 3));
      s.loop.stop();
      expect(camera.taken, 2); // the pause is over
    });
  });

  test('the server down: a raw tick that says why', () {
    fakeAsync((async) {
      final s = _Setup(camera: _Camera()); // no answer: 503
      s.loop.start();
      async.elapse(const Duration(milliseconds: 500));
      s.loop.stop();
      expect(s.failures, ['api_503']);
      expect(s.corrected, isEmpty);
    });
  });
}
