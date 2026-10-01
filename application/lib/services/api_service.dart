import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

class ApiException implements Exception {
  final int statusCode;
  final String body;

  ApiException(this.statusCode, this.body);

  @override
  String toString() => 'ApiException($statusCode): $body';
}

/// Thin JSON/HTTP wrapper shared by the per-service API clients below, so
/// screens call e.g. `UserManagementApi().get(...)` instead of re-inlining
/// `Uri.parse`/`http.get`/`jsonDecode` everywhere.
class ApiService {
  final String baseUrl;

  ApiService(this.baseUrl);

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  /// Attaches the signed-in user's Supabase access token, if any, so
  /// backend services can verify who's actually calling instead of trusting
  /// whatever id shows up in a request body/path (omitted when signed out -
  /// endpoints that require auth then 401 instead of silently acting as
  /// nobody).
  Map<String, String> _authHeaders([Map<String, String>? extra]) {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    return {if (token != null) 'Authorization': 'Bearer $token', ...?extra};
  }

  Future<dynamic> get(String path) async {
    final response = await http.get(_uri(path), headers: _authHeaders());
    return _handle(response);
  }

  Future<dynamic> post(String path, Map<String, dynamic> body) async {
    final response = await http.post(
      _uri(path),
      headers: _authHeaders({'Content-Type': 'application/json'}),
      body: jsonEncode(body),
    );
    return _handle(response);
  }

  Future<dynamic> patch(String path, Map<String, dynamic> body) async {
    final response = await http.patch(
      _uri(path),
      headers: _authHeaders({'Content-Type': 'application/json'}),
      body: jsonEncode(body),
    );
    return _handle(response);
  }

  Future<dynamic> delete(String path) async {
    final response = await http.delete(_uri(path), headers: _authHeaders());
    return _handle(response);
  }

  /// Uploads [bytes] as a multipart file field named [fieldName] to [path],
  /// plus any extra form [fields] sent alongside the file.
  Future<dynamic> postMultipart(
    String path, {
    required String fieldName,
    required List<int> bytes,
    required String filename,
    Map<String, String>? fields,
  }) async {
    final request = http.MultipartRequest('POST', _uri(path))
      ..headers.addAll(_authHeaders())
      ..files.add(
        http.MultipartFile.fromBytes(fieldName, bytes, filename: filename),
      );
    if (fields != null) request.fields.addAll(fields);
    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);
    return _handle(response);
  }

  dynamic _handle(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return null;
      return jsonDecode(response.body);
    }
    throw ApiException(response.statusCode, response.body);
  }
}

/// Every service is reached through the single API gateway (`API_GATEWAY_URL`),
/// each at its own path prefix - see `gateway/nginx.conf` for the routing.
String get _gatewayUrl => dotenv.env['API_GATEWAY_URL'] ?? '';

class UserManagementApi extends ApiService {
  UserManagementApi() : super('$_gatewayUrl/user');
}

class MapManagementApi extends ApiService {
  MapManagementApi() : super('$_gatewayUrl/map');
}

class RouteManagementApi extends ApiService {
  RouteManagementApi() : super('$_gatewayUrl/route');
}

class NavigationManagementApi extends ApiService {
  NavigationManagementApi() : super('$_gatewayUrl/navigation');
}

class DataCollectionApi extends ApiService {
  DataCollectionApi() : super('$_gatewayUrl/data-collection');
}

class AiTrainingApi extends ApiService {
  AiTrainingApi() : super('$_gatewayUrl/ai-training');
}
