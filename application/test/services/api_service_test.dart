import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:application/services/api_service.dart';

void main() {
  setUp(() {
    dotenv.testLoad(fileInput: '''
USER_MANAGEMENT_URL=http://user.example
MAP_MANAGEMENT_URL=http://map.example
ROUTE_MANAGEMENT_URL=http://route.example
NAVIGATION_MANAGEMENT_URL=http://nav.example
''');
  });

  test('each API client reads its own base URL from the environment', () {
    expect(UserManagementApi().baseUrl, 'http://user.example');
    expect(MapManagementApi().baseUrl, 'http://map.example');
    expect(RouteManagementApi().baseUrl, 'http://route.example');
    expect(NavigationManagementApi().baseUrl, 'http://nav.example');
  });

  test('missing env var falls back to an empty base URL rather than throwing', () {
    dotenv.testLoad(fileInput: '');
    expect(UserManagementApi().baseUrl, '');
  });

  test('ApiException.toString() includes the status code and body', () {
    final exception = ApiException(404, 'not found');
    expect(exception.toString(), contains('404'));
    expect(exception.toString(), contains('not found'));
  });
}
