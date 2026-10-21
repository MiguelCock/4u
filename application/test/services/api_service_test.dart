import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:eyes4u/services/api_service.dart';

void main() {
  setUp(() {
    dotenv.testLoad(fileInput: 'API_GATEWAY_URL=http://gateway.example');
  });

  test('each API client appends its own path prefix to the gateway URL', () {
    expect(UserManagementApi().baseUrl, 'http://gateway.example/user');
    expect(MapManagementApi().baseUrl, 'http://gateway.example/map');
    expect(RouteManagementApi().baseUrl, 'http://gateway.example/route');
    expect(
      NavigationManagementApi().baseUrl,
      'http://gateway.example/navigation',
    );
    expect(
      DataCollectionApi().baseUrl,
      'http://gateway.example/data-collection',
    );
    expect(AiTrainingApi().baseUrl, 'http://gateway.example/ai-training');
    expect(PositioningApi().baseUrl, 'http://gateway.example/positioning');
  });

  test(
    'missing env var falls back to just the path prefix rather than throwing',
    () {
      dotenv.testLoad(fileInput: '');
      expect(UserManagementApi().baseUrl, '/user');
    },
  );

  test('ApiException.toString() includes the status code and body', () {
    final exception = ApiException(404, 'not found');
    expect(exception.toString(), contains('404'));
    expect(exception.toString(), contains('not found'));
  });

  test('ApiException.detail extracts a FastAPI string detail', () {
    expect(ApiException(400, '{"detail":"Bad input"}').detail, 'Bad input');
    expect(ApiException(422, '{"detail":[{"msg":"x"}]}').detail, isNull);
    expect(ApiException(500, 'not json').detail, isNull);
  });

  test('a dropped connection becomes a network ApiException', () async {
    final api = ApiService(
      'http://api.example',
      client: MockClient(
        (_) async => throw http.ClientException('Failed host lookup'),
      ),
      getAccessToken: () => null,
      refreshSession: () async {},
    );
    await expectLater(
      api.get('/thing'),
      throwsA(isA<ApiException>().having((e) => e.isNetworkError, 'net', true)),
    );
  });

  group('401 refresh-and-retry', () {
    late List<String?> sentTokens;
    late int refreshCalls;
    late String token;

    ApiService buildApi(
      List<int> statuses, {
      Future<void> Function()? refreshSession,
    }) {
      var call = 0;
      return ApiService(
        'http://api.example',
        client: MockClient((request) async {
          sentTokens.add(request.headers['Authorization']);
          final status = statuses[call++];
          return http.Response(status == 200 ? '{"ok":true}' : '', status);
        }),
        getAccessToken: () => token,
        refreshSession:
            refreshSession ??
            () async {
              refreshCalls++;
              token = 'fresh';
            },
      );
    }

    setUp(() {
      sentTokens = [];
      refreshCalls = 0;
      token = 'stale';
    });

    test('retries once with a refreshed token after a 401', () async {
      final result = await buildApi([401, 200]).get('/thing');
      expect(result, {'ok': true});
      expect(refreshCalls, 1);
      expect(sentTokens, ['Bearer stale', 'Bearer fresh']);
    });

    test('a 401 that survives the retry still throws', () async {
      await expectLater(
        buildApi([401, 401]).post('/thing', {}),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 401)),
      );
      expect(refreshCalls, 1);
      expect(sentTokens, hasLength(2));
    });

    test(
      'a failed refresh surfaces the original 401 without retrying',
      () async {
        final api = buildApi([
          401,
        ], refreshSession: () async => throw Exception('no session'));
        await expectLater(
          api.delete('/thing'),
          throwsA(
            isA<ApiException>().having((e) => e.statusCode, 'status', 401),
          ),
        );
        expect(sentTokens, hasLength(1));
      },
    );

    test('multipart uploads are rebuilt for the retry', () async {
      final result = await buildApi([401, 200]).postMultipart(
        '/upload',
        fieldName: 'photo',
        bytes: [1, 2, 3],
        filename: 'a.jpg',
        fields: {'k': 'v'},
      );
      expect(result, {'ok': true});
      expect(sentTokens, ['Bearer stale', 'Bearer fresh']);
    });

    test('non-401 errors are not retried', () async {
      await expectLater(
        buildApi([500]).get('/thing'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 500)),
      );
      expect(refreshCalls, 0);
    });
  });
}
