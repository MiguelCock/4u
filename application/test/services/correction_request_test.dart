import 'package:clock/clock.dart';
import 'package:eyes4u/services/correction_request.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/api_fakes.dart';

void main() {
  setUpAll(() => dotenv.testLoad(fileInput: ''));

  test('a photo with its fix, heading and frame flag', () async {
    await withClock(Clock.fixed(DateTime.utc(2026, 11, 15, 10)), () async {
      final api = FakePositioningApi(answer: {'corrected_lat': 6.2});
      final answer = await postCorrection(
        api,
        bytes: const [1, 2, 3],
        filename: 'p.jpg',
        sessionId: 's1',
        fix: fix(6.2, -75.58),
        heading: 90,
        storeFrame: true,
      );
      expect(answer, {'corrected_lat': 6.2});
      expect(api.sent.single, {
        'path': '/correct_position',
        'field': 'photo',
        'session_id': 's1',
        'latitude': '6.2',
        'longitude': '-75.58',
        'accuracy': '5.0',
        'heading': '90.0',
        'gps_time': '2026-11-15T10:00:00.000Z',
        'store_frame': 'true',
      });
    });
  });

  test('no heading and no frame: neither field is sent', () async {
    final api = FakePositioningApi(answer: {});
    await postCorrection(
      api,
      bytes: const [1],
      filename: 'p.jpg',
      sessionId: 'start-check-1',
      fix: fix(6.2, -75.58),
    );
    expect(api.sent.single.keys, isNot(contains('heading')));
    expect(api.sent.single.keys, isNot(contains('store_frame')));
  });
}
