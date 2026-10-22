import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import 'api_service.dart';

/// A plain-language, localized explanation of a failed request, for
/// showing to a user - never the raw status code or backend JSON.
///
/// Screens keep their own sentence ("Failed to save anchor point: {error}")
/// and pass this in as the `{error}` part. [fallback] replaces the generic
/// wording for a 404 or an unrecognized error when the caller knows
/// something more specific to say.
String friendlyApiErrorMessage(
  BuildContext context,
  Object error, {
  String? fallback,
}) {
  final l10n = AppLocalizations.of(context)!;
  return friendlyApiErrorMessageFor(l10n, error, fallback: fallback);
}

/// [friendlyApiErrorMessage] without a BuildContext, for tests and for
/// callers that already hold an [AppLocalizations].
String friendlyApiErrorMessageFor(
  AppLocalizations l10n,
  Object error, {
  String? fallback,
}) {
  if (error is AuthRetryableFetchException) {
    return l10n.commonErrorNetworkUnreachable;
  }
  // Supabase Auth's own messages ("Invalid login credentials", "Password
  // should be at least 6 characters") are already written for people.
  if (error is AuthException) return error.message;
  if (error is! ApiException) return fallback ?? l10n.commonErrorUnexpected;
  final status = error.statusCode;
  if (error.isNetworkError) return l10n.commonErrorNetworkUnreachable;
  // 400s are the backend's own deliberate validation messages, already
  // written for a person to read.
  // 400 and 409 carry the backend's own explanation (validation, "still
  // used by other data", "already exists"), written to be shown as-is.
  if (status == 400 || status == 409) {
    return error.detail ?? fallback ?? l10n.commonErrorUnexpected;
  }
  // Only reachable once ApiService's own refresh-and-retry has failed too.
  if (status == 401) return l10n.commonErrorSessionExpired;
  if (status == 403) return l10n.commonErrorForbidden;
  if (status == 404) return fallback ?? l10n.commonErrorNotFoundGeneric;
  if (status >= 500) return l10n.commonErrorServerUnavailable;
  return fallback ?? l10n.commonErrorUnexpected;
}
