import 'package:eyes4u/services/buzz.dart';
import 'package:eyes4u/voice/app_voice.dart';
import 'package:eyes4u/voice/trip_announcer.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class _Trip {
  _Trip({bool voiceOn = true}) : voiceOn = ValueNotifier(voiceOn) {
    voice = AppVoice(
      speak: (text) async {
        said.add(text);
        voice.onStarted();
        Future.delayed(const Duration(seconds: 2), voice.onEnded);
      },
      stop: () async {},
      configure: (_) async => true,
    );
    announcer = TripAnnouncer(
      owner: voice.claim(),
      logCue: (type, text) => cues.add('$type:$text'),
      buzzer: (kind) async => buzzes.add(kind),
      voiceOn: this.voiceOn,
      micOpen: mic,
      closeMic: () {
        closes++;
        mic.value = false;
      },
    );
  }

  final mic = ValueNotifier(false);
  var closes = 0;

  late final AppVoice voice;
  late final TripAnnouncer announcer;
  final ValueNotifier<bool> voiceOn;
  final said = <String>[];
  final cues = <String>[];
  final buzzes = <Buzz>[];
}

void main() {
  test('an instruction buzzes, is logged, said, and kept for Repeat', () {
    fakeAsync((async) {
      final trip = _Trip();
      trip.announcer.speak('Gira a la derecha.', cueType: 'turn');
      async.elapse(const Duration(seconds: 3));
      expect(trip.buzzes, [Buzz.short]);
      expect(trip.cues, ['turn:Gira a la derecha.']);
      expect(trip.said, ['Gira a la derecha.']);
      expect(trip.announcer.lastAnnouncement, 'Gira a la derecha.');
      expect(trip.announcer.lastCueType, 'turn');
    });
  });

  test('a notice is said but is not what Repeat plays', () {
    fakeAsync((async) {
      final trip = _Trip();
      trip.announcer.speak('Sigue recto.', cueType: 'leg');
      trip.announcer.speak('Un momento.', repeatable: false);
      async.elapse(const Duration(seconds: 5));
      expect(trip.buzzes, [Buzz.short], reason: 'info cues do not buzz');
      expect(trip.announcer.repeat(), 'Sigue recto.');
      async.elapse(const Duration(seconds: 3));
      expect(trip.said, ['Sigue recto.', 'Un momento.', 'Sigue recto.']);
    });
  });

  test('Repeat interrupts what is queued', () {
    fakeAsync((async) {
      final trip = _Trip();
      trip.announcer.speak('Gira a la izquierda.', cueType: 'turn');
      trip.announcer.speak('Quedan 40 metros.');
      async.elapse(const Duration(milliseconds: 500));
      trip.announcer.lastAnnouncement = 'Gira a la izquierda.';
      trip.announcer.lastCueType = 'turn';
      trip.announcer.repeat();
      async.elapse(const Duration(seconds: 5));
      expect(trip.said, ['Gira a la izquierda.', 'Gira a la izquierda.']);
    });
  });

  test('with voice guidance off, cues are logged and buzzed, not said', () {
    fakeAsync((async) {
      final trip = _Trip(voiceOn: false);
      trip.announcer.speak('Gira a la derecha.', cueType: 'turn');
      async.elapse(const Duration(seconds: 3));
      expect(trip.said, isEmpty);
      expect(trip.cues, hasLength(1));
      expect(trip.buzzes, [Buzz.short]);
    });
  });

  test('released, the trip is heard no more', () {
    fakeAsync((async) {
      final trip = _Trip();
      trip.announcer.release();
      trip.announcer.speak('Llegaste.');
      async.elapse(const Duration(seconds: 3));
      expect(trip.said, isEmpty);
      expect(trip.announcer.repeat(), 'Llegaste.');
    });
  });

  test('nothing said yet: Repeat does nothing', () {
    expect(_Trip().announcer.repeat(), isNull);
  });

  group('pause and repeat (#228)', () {
    test('a repeat says so, and Repeat still has the plain instruction', () {
      fakeAsync((async) {
        final trip = _Trip();
        trip.announcer.speak('Gira a la derecha.', cueType: 'turn');
        async.elapse(const Duration(seconds: 3));
        expect(
          trip.announcer.repeat(prefix: 'Repito: '),
          'Repito: Gira a la derecha.',
        );
        async.elapse(const Duration(seconds: 3));
        expect(trip.said.last, 'Repito: Gira a la derecha.');
        expect(trip.announcer.lastAnnouncement, 'Gira a la derecha.');
      });
    });

    test('paused: instructions are logged and kept, not said or buzzed', () {
      fakeAsync((async) {
        final trip = _Trip();
        trip.announcer.pause('En pausa.');
        async.elapse(const Duration(seconds: 3));
        trip.buzzes.clear();
        trip.announcer.speak('Gira a la izquierda.', cueType: 'turn');
        async.elapse(const Duration(seconds: 3));
        expect(trip.said, ['En pausa.']);
        expect(trip.buzzes, isEmpty);
        expect(trip.cues.last, 'turn:Gira a la izquierda.');
        expect(trip.announcer.lastAnnouncement, 'Gira a la izquierda.');
      });
    });

    test('paused: safety and endings are still said', () {
      fakeAsync((async) {
        final trip = _Trip();
        trip.announcer.pause('En pausa.');
        async.elapse(const Duration(seconds: 3));
        trip.announcer.speak('La cámara está tapada.', assertive: true);
        async.elapse(const Duration(seconds: 3));
        expect(trip.said.last, 'La cámara está tapada.');
      });
    });

    test('resuming says so, then the current instruction', () {
      fakeAsync((async) {
        final trip = _Trip();
        trip.announcer.pause('En pausa.');
        trip.announcer.speak('Sigue recto.', cueType: 'leg');
        async.elapse(const Duration(seconds: 3));
        trip.announcer.resume('Seguimos.');
        async.elapse(const Duration(seconds: 3));
        expect(trip.announcer.paused, isFalse);
        expect(trip.said.last, 'Seguimos. Sigue recto.');
      });
    });

    test('nothing is said into an open microphone; safety closes it', () {
      fakeAsync((async) {
        final trip = _Trip();
        trip.mic.value = true;
        trip.announcer.speak('Sigue recto.', cueType: 'leg');
        async.elapse(const Duration(seconds: 3));
        expect(trip.said, isEmpty);
        expect(trip.announcer.lastAnnouncement, 'Sigue recto.');
        trip.announcer.speak('La cámara está tapada.', assertive: true);
        async.elapse(const Duration(seconds: 3));
        expect(trip.closes, 1);
        expect(trip.said, ['La cámara está tapada.']);
      });
    });
  });
}
