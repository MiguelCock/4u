import 'dart:async';

import 'package:eyes4u/admin/admin_map_data.dart';
import 'package:eyes4u/admin/map_edit_controller.dart';
import 'package:eyes4u/services/api_service.dart';
import 'package:eyes4u/services/connect_chain.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import '../support/api_fakes.dart';

final _points = [
  {'id': 'a', 'latitude': 6.2, 'longitude': -75.58, 'floor': 0},
  {'id': 'b', 'latitude': 6.2001, 'longitude': -75.58, 'floor': 0},
];

/// A map server whose connection POST answers when [answer] completes.
class _Server extends FakeMapApi {
  _Server() : super(anchors: _points);

  Completer<dynamic> answer = Completer();

  @override
  Future<dynamic> post(
    String path,
    Map<String, dynamic> body, {
    Duration? timeout,
    bool retry = false,
  }) {
    writes.add(('POST', path, body));
    return answer.future;
  }
}

Future<(MapEditController, AdminMapData, _Server)> _setup({
  String? user = 'me',
}) async {
  final server = _Server();
  final data = AdminMapData(mapApi: server, aiTrainingApi: FakeAiTrainingApi());
  await data.loadAll();
  return (
    MapEditController(api: server, data: data, userId: () => user),
    data,
    server,
  );
}

void main() {
  setUpAll(() => dotenv.testLoad(fileInput: ''));

  test('taps select, deselect, then a second point makes a pair', () async {
    final (edit, _, _) = await _setup();
    edit.setConnecting(true);
    expect(edit.tap(_points[0]), isA<ConnectSelect>());
    expect(edit.connectFromId, 'a');
    expect(edit.tap(_points[0]), isA<ConnectDeselect>());
    expect(edit.connectFromId, isNull);
    edit.tap(_points[0]);
    final pair = edit.tap(_points[1]);
    expect(pair, isA<ConnectPair>());
    expect(edit.connectFromId, 'a', reason: 'save moves it on, not tap');
  });

  test('saving shows a grey line at once, then the saved row', () async {
    final (edit, data, server) = await _setup();
    edit.connectFrom(_points[0]);
    final pair = edit.tap(_points[1]) as ConnectPair;
    final saving = edit.save(pair);
    expect(data.connections.single['pending'], isTrue);
    expect(edit.connectFromId, 'b', reason: 'the next tap goes on from b');
    expect(
      await edit.save(pair),
      isA<ConnectAlreadySaving>(),
      reason: 'the same pair waits',
    );
    server.answer.complete([
      {'id': 'c1', 'anchor_point_a_id': 'a', 'anchor_point_b_id': 'b'},
    ]);
    expect(await saving, isA<ConnectSaved>());
    expect(data.connections.single['id'], 'c1');
    expect(server.paths('POST'), ['/anchor-point-connections']);
    expect(server.writes.single.$3?['created_by'], 'me');
  });

  test('a refused save takes the grey line away', () async {
    final (edit, data, server) = await _setup();
    edit.connectFrom(_points[0]);
    final saving = edit.save(edit.tap(_points[1]) as ConnectPair);
    server.answer.completeError(ApiException(409, 'duplicate'));
    final result = await saving;
    expect((result as ConnectFailed).error.statusCode, 409);
    expect(data.connections, isEmpty);
  });

  test('nobody signed in: nothing is sent', () async {
    final (edit, data, server) = await _setup(user: null);
    edit.connectFrom(_points[0]);
    final result = await edit.save(edit.tap(_points[1]) as ConnectPair);
    expect(result, isA<ConnectNotSignedIn>());
    expect(server.writes, isEmpty);
    expect(data.connections, isEmpty);
  });

  test('moving, connecting and leaving the map', () async {
    final (edit, _, _) = await _setup();
    var changes = 0;
    edit.addListener(() => changes++);
    edit.startMove(_points[0]);
    edit.pickMoveTarget(const LatLng(6.3, -75.5));
    expect(edit.moveTarget, isNotNull);
    edit.connectFrom(_points[1]);
    expect(edit.movingPoint, isNull, reason: 'connecting ends a move');
    expect(edit.connecting, isTrue);
    edit.leaveMap();
    expect(edit.connecting, isFalse);
    expect(edit.connectFromId, isNull);
    expect(changes, 4);
  });
}
