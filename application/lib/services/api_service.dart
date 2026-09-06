import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

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

  Future<dynamic> get(String path) async {
    final response = await http.get(_uri(path));
    return _handle(response);
  }

  Future<dynamic> post(String path, Map<String, dynamic> body) async {
    final response = await http.post(
      _uri(path),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    return _handle(response);
  }

  Future<dynamic> patch(String path, Map<String, dynamic> body) async {
    final response = await http.patch(
      _uri(path),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    return _handle(response);
  }

  Future<dynamic> delete(String path) async {
    final response = await http.delete(_uri(path));
    return _handle(response);
  }

  /// Uploads [bytes] as a multipart file field named [fieldName] to [path].
  Future<dynamic> postMultipart(
    String path, {
    required String fieldName,
    required List<int> bytes,
    required String filename,
  }) async {
    final request = http.MultipartRequest('POST', _uri(path))
      ..files.add(http.MultipartFile.fromBytes(fieldName, bytes, filename: filename));
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

class UserManagementApi extends ApiService {
  UserManagementApi() : super(dotenv.env['USER_MANAGEMENT_URL'] ?? '');
}

class MapManagementApi extends ApiService {
  MapManagementApi() : super(dotenv.env['MAP_MANAGEMENT_URL'] ?? '');
}

class RouteManagementApi extends ApiService {
  RouteManagementApi() : super(dotenv.env['ROUTE_MANAGEMENT_URL'] ?? '');
}

class NavigationManagementApi extends ApiService {
  NavigationManagementApi() : super(dotenv.env['NAVIGATION_MANAGEMENT_URL'] ?? '');
}
