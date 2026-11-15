import 'package:clock/clock.dart';
import 'package:eyes4u/services/api_service.dart';
import 'package:eyes4u/user/trip_log.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/api_fakes.dart';

/// A server that refuses the next log, then accepts.
class _Flaky extends FakeNavigationApi {
  bool fail = true;

  @override
  Future<dynamic> post(
    String path,
    Map<String, dynamic> body, {
    Duration? timeout,
    bool retry = false,
  }) async {
    if (fail) {
      fail = false;
      throw ApiException(503, '');
    }
    return super.post(path, body, timeout: timeout, retry: retry);
  }
}

void main() {
  setUpAll(() => dotenv.testLoad(fileInput: ''));
  final t0 = DateTime.utc(2026, 11, 15, 10);

  test('cues and events go out with the next tick, once', () {
    withClock(Clock.fixed(t0), () {
      final log = TripLog(FakeNavigationApi());
      expect(log.hasPending, isFalse);
      expect(log.drain(), isEmpty);

      log.cue('turn', 'Gira a la derecha.');
      log.event('waypoint', fields: {'index': 1});
      log.event('app_paused', at: t0.subtract(const Duration(seconds: 2)));
      expect(log.hasPending, isTrue);
      expect(log.drain(), {
        'cues': [
          {
            'at': '2026-11-15T10:00:00.000Z',
            'type': 'turn',
            'text': 'Gira a la derecha.',
          },
        ],
        'events': [
          {'at': '2026-11-15T10:00:00.000Z', 'type': 'waypoint', 'index': 1},
          {'at': '2026-11-15T09:59:58.000Z', 'type': 'app_paused'},
        ],
      });
      expect(log.hasPending, isFalse);
    });
  });

  test('a dropped tick puts what it carried back, first', () async {
    final api = _Flaky();
    final log = TripLog(api)..event('arrival');
    final first = {'session_id': 's1', 'debug': log.drain()};
    await log.post(first); // refused
    expect(api.posts, isEmpty);

    log.event('feedback');
    final second = log.drain();
    expect((second['events'] as List).map((e) => e['type']), [
      'arrival',
      'feedback',
    ]);
    await log.post({'session_id': 's1', 'debug': second});
    expect(api.posts.single.$1, '/logs');
  });
}
