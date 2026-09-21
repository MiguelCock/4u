import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:application/services/api_service.dart';

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
}
