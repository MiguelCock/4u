import 'dart:async';
import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

class ApiException implements Exception {
  /// Used as [statusCode] when no HTTP response came back at all (no
  /// connection, DNS failure, timeout).
  static const int networkError = 0;

  final int statusCode;
  final String body;

  ApiException(this.statusCode, this.body);

  bool get isNetworkError => statusCode == networkError;

  /// The backend's FastAPI `{"detail": "..."}` message, when the body is
  /// shaped that way and `detail` is a plain string (FastAPI's own
  /// validation errors use a list there instead - those return null).
  String? get detail {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['detail'] is String) {
        return decoded['detail'] as String;
      }
    } catch (_) {}
    return null;
  }

  @override
  String toString() => 'ApiException($statusCode): $body';
}

/// Thin JSON/HTTP wrapper shared by the per-service API clients below, so
/// screens call e.g. `UserManagementApi().get(...)` instead of re-inlining
/// `Uri.parse`/`http.get`/`jsonDecode` everywhere.
class ApiService {
  final String baseUrl;
  final http.Client _client;
  final String? Function() _getAccessToken;
  final Future<void> Function() _refreshSession;

  /// [client]/[getAccessToken]/[refreshSession] exist for tests - every
  /// real caller uses the defaults (a plain client and the live Supabase
  /// session). The defaults are closures, so constructing an ApiService
  /// never touches Supabase until a request is actually made.
  ApiService(
    this.baseUrl, {
    http.Client? client,
    String? Function()? getAccessToken,
    Future<void> Function()? refreshSession,
  }) : _client = client ?? http.Client(),
       _getAccessToken =
           getAccessToken ??
           (() => Supabase.instance.client.auth.currentSession?.accessToken),
       _refreshSession =
           refreshSession ??
           (() => Supabase.instance.client.auth.refreshSession());

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  /// Attaches the signed-in user's Supabase access token, if any, so
  /// backend services can verify who's actually calling instead of trusting
  /// whatever id shows up in a request body/path (omitted when signed out -
  /// endpoints that require auth then 401 instead of silently acting as
  /// nobody).
  Map<String, String> _authHeaders([Map<String, String>? extra]) {
    final token = _getAccessToken();
    return {if (token != null) 'Authorization': 'Bearer $token', ...?extra};
  }

  /// Sends a request built by [sender], and on a 401 refreshes the session
  /// and retries exactly once with freshly-read headers.
  ///
  /// supabase_flutter's own auto-refresh timer is paused while the app is
  /// backgrounded (screen locked, app switched), so a token can expire in
  /// that gap and the first request after resuming can race the async
  /// refresh and go out with the stale token. Retrying here makes that
  /// invisible to every screen instead of surfacing "Invalid or expired
  /// token" mid-workflow. If there's no session to refresh (signed out),
  /// the original 401 is returned as-is.
  Future<http.Response> _send(
    Future<http.Response> Function(Map<String, String> headers) sender, [
    Map<String, String>? extraHeaders,
    Duration? timeout,
  ]) async {
    final response = await _attempt(sender, extraHeaders, timeout);
    if (response.statusCode != 401) return response;
    try {
      await _refreshSession();
    } catch (_) {
      return response;
    }
    return _attempt(sender, extraHeaders, timeout);
  }

  /// One request, with a timeout, and with transport failures (no
  /// connection, DNS, timeout) turned into an [ApiException] - every screen
  /// already catches `ApiException`, so this way a dropped connection is
  /// handled like any other failed request instead of escaping and leaving
  /// a spinner running forever.
  Future<http.Response> _attempt(
    Future<http.Response> Function(Map<String, String> headers) sender,
    Map<String, String>? extraHeaders, [
    Duration? timeout,
  ]) async {
    try {
      return await sender(
        _authHeaders(extraHeaders),
      ).timeout(timeout ?? requestTimeout);
    } on TimeoutException catch (e) {
      throw ApiException(ApiException.networkError, e.toString());
    } on http.ClientException catch (e) {
      throw ApiException(ApiException.networkError, e.message);
    }
  }

  /// Generous enough for a photo upload on a slow connection, matching the
  /// gateway's own 60s proxy timeout.
  static const requestTimeout = Duration(seconds: 60);

  Future<dynamic> get(String path) async {
    final response = await _send(
      (headers) => _client.get(_uri(path), headers: headers),
    );
    return _handle(response);
  }

  /// [timeout] overrides [requestTimeout] for calls whose answer is only
  /// useful quickly (navigation's per-tick calls).
  Future<dynamic> post(
    String path,
    Map<String, dynamic> body, {
    Duration? timeout,
  }) async {
    final response = await _send(
      (headers) =>
          _client.post(_uri(path), headers: headers, body: jsonEncode(body)),
      {'Content-Type': 'application/json'},
      timeout,
    );
    return _handle(response);
  }

  Future<dynamic> patch(String path, Map<String, dynamic> body) async {
    final response = await _send(
      (headers) =>
          _client.patch(_uri(path), headers: headers, body: jsonEncode(body)),
      {'Content-Type': 'application/json'},
    );
    return _handle(response);
  }

  Future<dynamic> delete(String path) async {
    final response = await _send(
      (headers) => _client.delete(_uri(path), headers: headers),
    );
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
    Duration? timeout,
  }) async {
    // A MultipartRequest can only be sent once, so a fresh one is built
    // per attempt.
    final response = await _send(
      (headers) async {
        final request = http.MultipartRequest('POST', _uri(path))
          ..headers.addAll(headers)
          ..files.add(
            http.MultipartFile.fromBytes(fieldName, bytes, filename: filename),
          );
        if (fields != null) request.fields.addAll(fields);
        return http.Response.fromStream(await _client.send(request));
      },
      null,
      timeout,
    );
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

class PositioningApi extends ApiService {
  PositioningApi() : super('$_gatewayUrl/positioning');
}
