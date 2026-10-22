import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/services/api_error_messages.dart';
import 'package:eyes4u/services/api_service.dart';

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final es = lookupAppLocalizations(const Locale('es'));

  String message(Object error, {String? fallback, AppLocalizations? l10n}) =>
      friendlyApiErrorMessageFor(l10n ?? en, error, fallback: fallback);

  test('never shows the raw status code or backend JSON', () {
    for (final status in [401, 403, 404, 500, 502, 418]) {
      final text = message(ApiException(status, '{"detail":"raw backend"}'));
      expect(text, isNot(contains('raw backend')), reason: '$status');
      expect(text, isNot(contains('ApiException')), reason: '$status');
      expect(text, isNot(contains('$status')), reason: '$status');
    }
  });

  test('network failures say the server could not be reached', () {
    expect(
      message(ApiException(ApiException.networkError, 'Failed host lookup')),
      en.commonErrorNetworkUnreachable,
    );
    expect(
      message(AuthRetryableFetchException(message: 'SocketException')),
      en.commonErrorNetworkUnreachable,
    );
  });

  test('401 means the session expired', () {
    expect(
      message(ApiException(401, '{"detail":"Invalid or expired token"}')),
      en.commonErrorSessionExpired,
    );
  });

  test('403 means no permission', () {
    expect(message(ApiException(403, '')), en.commonErrorForbidden);
  });

  test('404 uses the fallback when given, else a generic not-found', () {
    expect(message(ApiException(404, '')), en.commonErrorNotFoundGeneric);
    expect(message(ApiException(404, ''), fallback: 'custom'), 'custom');
  });

  test('5xx means a server-side problem', () {
    expect(message(ApiException(500, '')), en.commonErrorServerUnavailable);
    expect(message(ApiException(503, '')), en.commonErrorServerUnavailable);
  });

  test('400 passes through the backend validation detail', () {
    expect(
      message(ApiException(400, '{"detail":"Start and end must differ"}')),
      'Start and end must differ',
    );
    expect(message(ApiException(400, 'not json')), en.commonErrorUnexpected);
  });

  test('409 passes through why the backend refused', () {
    expect(
      message(
        ApiException(
          409,
          '{"detail":"This is still used by other data, so it can\'t be deleted yet."}',
        ),
      ),
      "This is still used by other data, so it can't be deleted yet.",
    );
  });

  test('Supabase Auth messages are already human-readable', () {
    expect(
      message(const AuthException('Invalid login credentials')),
      'Invalid login credentials',
    );
  });

  test('anything else is a generic message, or the fallback', () {
    expect(message(Exception('boom')), en.commonErrorUnexpected);
    expect(message(Exception('boom'), fallback: 'custom'), 'custom');
  });

  test('messages are localized', () {
    expect(message(ApiException(403, ''), l10n: es), es.commonErrorForbidden);
    expect(es.commonErrorForbidden, isNot(en.commonErrorForbidden));
  });
}
