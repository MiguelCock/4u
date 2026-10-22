import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/services/speech_voice.dart';

void main() {
  test('Spanish candidates start with Colombian Spanish', () {
    expect(ttsLanguageCandidates('es').first, 'es-CO');
    expect(ttsLanguageCandidates('en').first, 'en-US');
  });

  test('picks a voice for the app language, never the phone default', () {
    final voices = [
      {'name': 'en-us-x-iol-local', 'locale': 'en-US'},
      {'name': 'es-us-x-esd-local', 'locale': 'es-US'},
    ];
    expect(pickVoice(voices, ttsLanguageCandidates('es')), {
      'name': 'es-us-x-esd-local',
      'locale': 'es-US',
    });
  });

  test('prefers the earlier candidate and offline voices', () {
    final voices = [
      {'name': 'es-es-x-eea-local', 'locale': 'es-ES'},
      {'name': 'es-us-x-sfb-network', 'locale': 'es-US'},
      {'name': 'es-us-x-esd-local', 'locale': 'es_US'},
    ];
    expect(
      pickVoice(voices, ttsLanguageCandidates('es'))!['name'],
      'es-us-x-esd-local',
    );
  });

  test('returns null when no voice for the language is installed', () {
    final voices = [
      {'name': 'en-us-x-iol-local', 'locale': 'en-US'},
      'not a map',
    ];
    expect(pickVoice(voices, ttsLanguageCandidates('es')), isNull);
  });
}
