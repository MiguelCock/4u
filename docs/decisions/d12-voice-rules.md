# D12: How the app speaks, listens and works with TalkBack (#260)

These are the rules every user screen follows. The code that enforces them is in `application/lib/voice/`. The `voice-ui` skill (`.claude/skills/voice-ui/`) checks a change against them. Each rule has a number so that reviews and comments can refer to it.

## Why rules

The app talks (its own voice), listens (the phone's recognizer) and runs alongside TalkBack, which also talks. Each of the three can end up speaking over another, or into the open microphone. Every voice bug found in testing came from two of them meeting:
- the home screen's last sentence playing under the trip's start (#258);
- TalkBack reading the camera notice again and again on top of the app's voice (#257);
- TalkBack re-reading a button whose label changed, into the microphone (#264);
- "Di sí" waiting for a tap, because a listen never said it had ended (#265).

## What it's based on

- **Android accessibility guidance** (developer.android.com, "Make apps more accessible" and "Accessibility principles"):
  - Don't change content TalkBack is reading.
  - Use `announceForAccessibility` (Flutter: `SemanticsService.sendAnnouncement`) sparingly, and live regions only for content that really changes.
  - Every control has a label that says what it does.
  - Custom actions give TalkBack users what a gesture gives others.
- **WCAG 2.2:**
  - 1.4.2 Audio Control: sound that plays on its own can be stopped.
  - 2.2.1 Timing Adjustable: a time limit can be extended, or doesn't matter.
  - 2.2.4 Interruptions: the user can postpone interruptions, except emergencies.
  - 2.5.1 Pointer Gestures: anything a multi-tap does is also a single action.
  - 3.2.2 On Input: no unexpected change of context.
  - 4.1.3 Status Messages: status changes reach assistive technology without moving focus.
- **Voice interfaces (spoken dialogue design practice):**
  - Say what to answer before listening.
  - Signal that the microphone has opened (an earcon).
  - Never speak while listening.
  - Confirm before acting.
  - Keep lists short, with a way to hear more.
  - Repeat on request.
- **Our own tests:** the user tests of 2026-11-05 and 2026-11-14 and the admin tests of 2026-11-12 (local notes).

No published standard covers an app that both talks and listens next to a screen reader. These rules fill that gap for this app.

## The rules

### R1. One voice at a time
Only the screen on top speaks. A screen speaks only through the `VoiceOwner` it got from `AppVoice.instance.claim()`, never through its own `FlutterTts`. A page that covers it takes the voice. A dialog over it doesn't, and the dialog speaks with the screen's owner.

### R2. The app's own voice says everything, with TalkBack on or off
With TalkBack on, nothing the app says is read again by TalkBack:
- Text that is also spoken goes in `SpokenText` (hidden from TalkBack while it's on).
- Notices go through `showSpokenNotice`: a SnackBar with TalkBack off, nothing with it on.
- No live regions on text the app speaks, or on text that changes with each GPS fix.

Only when the user has turned the app's voice off does TalkBack announce instead (`showSpokenNotice` does this).

### R3. Announce or show
- **Instructions and answers** (turns, arrival, a found place, an error) are spoken.
- **Status that only a sighted person needs** (coordinates, the map) is shown and stays out of TalkBack, or becomes one labelled control (the trip map is the "Repeat" button).
- **Something the user must see again, with TalkBack off,** is spoken and also shown (`showSpokenNotice`).

### R4. Speak, then listen
- Every listen starts by saying what to answer (`HomeVoiceController.listen`'s `prompt`), waits until the voice says that sentence has ended (the engine's events, not a guessed time), then gives the marks (a buzz and a click), then opens the microphone.
- While the microphone is open, nothing is spoken (`VoiceOwner.beginListening`/`endListening`).
- Every way a listen can end clears that state (#265).

### R5. Never change what TalkBack may be reading
A control's label and enabled state don't change while it can have focus, for example while listening or busy. Use a sound, a buzz or the app's voice for state changes instead (#264).

### R6. Polite by default, assertive only for safety
- Routine announcements queue: route start, distance, approaching, arrival, session end.
- Only what can't wait interrupts the queue (`interrupt: true` / `assertive`): the covered camera, a dropped connection mid-trip, and repeats the user asked for.

### R7. Every announcement can be repeated
- The last instruction is kept, and a tap on the trip screen (one labelled button for TalkBack) says it again.
- Notices (the camera, "loading") aren't instructions and aren't what Repeat plays.

### R8. Everything can be skipped
- Tapping the screen three times quickly stops what the app is saying. A waiting listen then opens at once.
- With TalkBack on, its taps don't reach the app, so the same thing is the custom action **"Callar la app" / "Quiet the app"** on the screen (TalkBack's actions menu).
- Skipping never cancels a trip or answers a question. It only ends the speech, and the next step comes sooner (WCAG 1.4.2, 2.5.1).

### R9. Listen with a limit, then stop and say so
A listen ends on silence. After two retries the app says what to do next (the buttons are still there) and stops listening. A long silent listening cycle leaves people unsure whether the app is listening (D1).

### R10. Lists are short
- Spoken lists have at most three items, followed by "más" for more (D9).
- The user picks by number or name (`pickSpokenOption`).

### R11. Confirm before acting
A heard destination is confirmed ("¿Ir a X? Di sí para empezar") before a trip starts. No change of context happens on a guess (WCAG 3.2.2).

### R12. Covered or closed screens go quiet
- On `didPushNext`, `dispose` or the end of a trip, the screen stops listening and releases its owner.
- An answer that arrives for a dialog that has already closed is dropped.

### R13. Wait for TalkBack before the first question
With TalkBack on, a screen that asks something on opening waits about 2 s, so that TalkBack finishes reading the screen before the microphone opens.

## Where each rule lives

| Rule | Code |
|---|---|
| R1, R12 | `AppVoice`, `VoiceOwner`, `voiceRouteObserver` (`lib/voice/app_voice.dart`) |
| R2, R3 | `showSpokenNotice`, `SpokenText`, `screenReaderOn` (`lib/voice/notices.dart`) |
| R4, R9, R13 | `HomeVoiceController` (`lib/voice/home_voice_controller.dart`) |
| R5 | `SpeakCircle` (`lib/widgets/speak_circle.dart`) |
| R6, R7 | `TripAnnouncer` (`lib/voice/trip_announcer.dart`) |
| R8 | `SkipSpeech` (`lib/voice/skip_speech.dart`), `AppVoice.skip` |
| R10, R11 | `destination_conversation.dart`, `home_dialogs.dart`, `pickSpokenOption` |

## Checking a change

Run the `voice-ui` skill on a diff that touches a user screen, a dialog or `lib/voice/`. A phone check covers what the tests can't. Do it once with TalkBack on and once with it off:
- one voice at a time;
- nothing read twice;
- nothing spoken into the open microphone;
- three taps, or "Callar la app", stops the speech.
