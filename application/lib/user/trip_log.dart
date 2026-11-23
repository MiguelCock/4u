import 'package:clock/clock.dart';

import '../services/api_service.dart';

/// What happened during a trip, for its logs (Phase C): the cues spoken and
/// the events (waypoints, floors, stalls, checkpoints...) since the last
/// tick. Each tick's `POST /logs` carries them in `debug`, and a failed post
/// puts them back for the next one: they happen only once.
class TripLog {
  TripLog(this._api, {this.timeout = const Duration(seconds: 8)});

  final NavigationManagementApi _api;

  /// A tick's request: a ~20 s connection drop froze the loop at 60 s.
  final Duration timeout;

  final List<Map<String, dynamic>> _cues = [];
  final List<Map<String, dynamic>> _events = [];

  /// Something said, with its type (`turn`, `leg`, `arrival`...).
  void cue(String type, String text) => _cues.add({
    'at': clock.now().toUtc().toIso8601String(),
    'type': type,
    'text': text,
  });

  /// Something that happened, [at] now unless given, with its [fields].
  void event(
    String type, {
    DateTime? at,
    Map<String, dynamic> fields = const {},
  }) => _events.add({
    'at': (at ?? clock.now()).toUtc().toIso8601String(),
    'type': type,
    ...fields,
  });

  bool get hasPending => _cues.isNotEmpty || _events.isNotEmpty;

  /// What's queued, as a tick's `debug` keys (`cues`, `events`, only when
  /// there are some), and the queue emptied.
  Map<String, dynamic> drain() {
    final taken = <String, dynamic>{
      if (_cues.isNotEmpty) 'cues': List.of(_cues),
      if (_events.isNotEmpty) 'events': List.of(_events),
    };
    _cues.clear();
    _events.clear();
    return taken;
  }

  /// Posts a tick's log. Best effort: a dropped tick shouldn't interrupt
  /// navigation, and what it carried goes back to the front of the queue.
  Future<void> post(Map<String, dynamic> body) async {
    try {
      await _api.post('/logs', body, timeout: timeout);
    } on ApiException catch (_) {
      final debug = body['debug'] as Map<String, dynamic>?;
      final cues = debug?['cues'] as List?;
      final events = debug?['events'] as List?;
      if (cues != null) _cues.insertAll(0, cues.cast());
      if (events != null) _events.insertAll(0, events.cast());
    }
  }
}
