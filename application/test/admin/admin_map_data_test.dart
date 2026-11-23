import 'package:eyes4u/admin/admin_map_data.dart';
import 'package:eyes4u/services/api_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/api_fakes.dart';

/// A map server whose `/changes` answers [answer], counting full loads.
class _Server extends FakeMapApi {
  _Server({this.answer})
    : super(
        places: [
          {'id': 'p1', 'name': 'Icesi'},
        ],
        anchors: [
          {'id': 'a1', 'status': 'verified'},
        ],
        photos: [
          {'id': 'ph1', 'anchor_point_id': 'a1'},
        ],
      );

  /// null: no /changes (404); else what it says, given the `since`.
  Object? Function(String since)? answer;
  int fullLoads = 0;

  /// How long /changes takes to answer, and the most answering at once.
  Duration delay = Duration.zero;
  int _answering = 0;
  int mostAtOnce = 0;

  @override
  Future<dynamic> get(String path) async {
    if (path == '/places') fullLoads++;
    if (path.startsWith('/changes?since=')) {
      final a = answer;
      if (a == null) throw ApiException(404, path);
      _answering++;
      if (_answering > mostAtOnce) mostAtOnce = _answering;
      await Future<void>.delayed(delay);
      _answering--;
      final result = a(Uri.decodeQueryComponent(path.substring(15)));
      if (result is ApiException) throw result;
      return result;
    }
    return super.get(path);
  }
}

void main() {
  setUpAll(() => dotenv.testLoad(fileInput: ''));

  AdminMapData data(_Server server, {Set<String>? indexed}) => AdminMapData(
    mapApi: server,
    aiTrainingApi: FakeAiTrainingApi(indexedPhotoIds: indexed),
  );

  test('a full load: the lists, then the index status', () async {
    final d = data(_Server(), indexed: {});
    var heard = 0;
    d.addListener(() => heard++);
    expect(d.loading, isTrue);
    await d.loadAll();
    await pumpEventQueue();
    expect(d.loading, isFalse);
    expect(d.places.single['name'], 'Icesi');
    expect(d.unsearchablePhotos, 1);
    expect(heard, 2);
  });

  test('a failed load ends the spinner and keeps why', () async {
    final server = _Server()..failConnections = true;
    final d = data(server);
    await d.loadAll();
    expect(d.loading, isFalse);
    expect(d.loadError, isA<ApiException>());
  });

  test('sync merges /changes and counts what\'s new', () async {
    final asked = <String>[];
    final server = _Server(
      answer: (since) {
        asked.add(since);
        return {
          'next_since': 's${asked.length}',
          if (asked.length > 1)
            'places': [
              {'id': 'p2', 'name': 'Javeriana'},
            ],
        };
      },
    );
    final d = data(server);
    await d.loadAll();
    expect(await d.sync(announce: true), 1);
    expect(asked.last, 's1');
    expect(d.places.map((p) => p['id']), ['p1', 'p2']);
    expect(await d.sync(announce: true), 0);
    expect(server.fullLoads, 1);
  });

  test('without /changes: a full load after an edit, not every 30 s', () async {
    final server = _Server();
    final d = data(server);
    await d.loadAll();
    expect(await d.sync(announce: true), 0);
    expect(server.fullLoads, 1);
    await d.sync(announce: false);
    expect(server.fullLoads, 2);
  });

  test('"full" from the server, or a failed /changes: a full load', () async {
    Object failure = {'next_since': 's'};
    final server = _Server(answer: (_) => failure);
    final d = data(server);
    await d.loadAll();
    failure = {'full': true};
    await d.sync(announce: true);
    expect(server.fullLoads, 2);
    failure = ApiException(500, 'boom');
    await d.sync(announce: true);
    expect(server.fullLoads, 2, reason: 'the timer never falls back');
    await d.sync(announce: false);
    expect(server.fullLoads, 3);
  });

  test('syncs run one at a time', () async {
    final server = _Server(answer: (_) => {'next_since': 's'});
    final d = data(server);
    await d.loadAll();
    server.delay = const Duration(milliseconds: 20);
    await Future.wait([
      d.sync(announce: true),
      d.sync(announce: false),
      d.sync(announce: true),
    ]);
    expect(server.mostAtOnce, 1);
  });
}
