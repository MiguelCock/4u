import 'api_service.dart';
import 'app_preferences.dart';

/// Saves [changes] to the user's `profiles.preferences` and applies them
/// (#226: settings changed by voice). The saved map is read first and
/// merged, since PATCH replaces the whole of it and Settings' other choices
/// (verbosity, language...) must survive.
Future<Map<String, dynamic>> savePreferenceChanges(
  ApiService userApi,
  String userId,
  Map<String, dynamic> changes,
) async {
  final profile =
      await userApi.get('/profiles/$userId') as Map<String, dynamic>;
  final merged = {
    ...?(profile['preferences'] as Map?)?.cast<String, dynamic>(),
    ...changes,
  };
  await userApi.patch('/profiles/$userId', {'preferences': merged});
  applyPreferences(merged);
  return merged;
}
