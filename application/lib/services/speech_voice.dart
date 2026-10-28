import 'package:flutter_tts/flutter_tts.dart';

/// TTS locales to try for an app language, best first. Colombian Spanish
/// first since that's where the app is used, then the variants Google's
/// engine most often ships.
List<String> ttsLanguageCandidates(String languageCode) {
  return switch (languageCode) {
    'es' => const ['es-CO', 'es-US', 'es-MX', 'es-ES'],
    _ => const ['en-US', 'en-GB'],
  };
}

String _normalizeLocale(String locale) => locale.replaceAll('_', '-');

/// The installed voice to use for [candidates], or null if none matches.
/// [voices] is `FlutterTts.getVoices`' raw result: a list of maps with at
/// least `name` and `locale` (e.g. `es-us-x-esd-local` / `es-US`). Voices
/// that don't need the network are preferred, so guidance keeps working
/// with poor connectivity.
Map<String, String>? pickVoice(List<dynamic> voices, List<String> candidates) {
  Map<String, String>? best;
  var bestRank = 1 << 30;
  for (final raw in voices) {
    if (raw is! Map) continue;
    final name = raw['name']?.toString();
    final locale = raw['locale']?.toString();
    if (name == null || locale == null) continue;
    final index = candidates.indexWhere(
      (c) => c.toLowerCase() == _normalizeLocale(locale).toLowerCase(),
    );
    if (index == -1) continue;
    final needsNetwork =
        raw['network_required']?.toString() == '1' ||
        name.toLowerCase().contains('network');
    final rank = index * 2 + (needsNetwork ? 1 : 0);
    if (rank < bestRank) {
      bestRank = rank;
      best = {'name': name, 'locale': locale};
    }
  }
  return best;
}

/// Points [tts] at a voice for the *app's* language ([languageCode], from
/// `Localizations.localeOf`), never the phone's TTS default. Without this,
/// a phone set to English read the Spanish UI text with an English voice.
/// Returns false when no voice for that language is installed, so the
/// caller can tell the user how to install one.
Future<bool> configureTts(FlutterTts tts, String languageCode) async {
  final candidates = ttsLanguageCandidates(languageCode);
  try {
    // Android only: queue polite announcements instead of each one cutting
    // off the last (the default flushes). Assertive ones still stop() first.
    await tts.setQueueMode(1);
  } catch (_) {}
  try {
    // A little faster than the engine's normal 0.5: users in the first
    // test, used to TalkBack, found the instructions slow.
    await tts.setSpeechRate(0.6);
  } catch (_) {}
  try {
    final voices = await tts.getVoices;
    final voice = voices is List ? pickVoice(voices, candidates) : null;
    if (voice != null) {
      await tts.setLanguage(voice['locale']!);
      await tts.setVoice(voice);
      return true;
    }
  } catch (_) {
    // Some engines don't list voices - fall through to language-only.
  }
  for (final language in candidates) {
    final available = await tts.isLanguageAvailable(language);
    if (available == true || available == 1) {
      await tts.setLanguage(language);
      return true;
    }
  }
  return false;
}
