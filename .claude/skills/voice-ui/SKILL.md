---
name: voice-ui
description: Apply and check the app's voice and TalkBack rules (D12). Use when building or changing a user screen, a dialog, the tutorial, anything that speaks, listens or shows a notice in application/, or anything in application/lib/voice/; and to review such a diff against the rules.
---

# Voice and TalkBack rules (D12)

The rules are in `docs/decisions/d12-voice-rules.md` (R1–R13). Read it first. The library that enforces them is in `application/lib/voice/`.

## When building

Use the library. Don't write a new voice mechanism.

- **Speaking:**
  - A screen claims the voice: `AppVoice.instance.claim()` → `VoiceOwner`. Never create a `FlutterTts`. (R1)
  - On a trip, speak through `TripAnnouncer` (polite or assertive, repeatable, logged, buzzed). (R6, R7)
  - On the home screen and its dialogs, speak through `HomeVoiceController.say`. (R4)
- **Listening:** `HomeVoiceController.listen` / `askUntil` with a `prompt`. Never open `SpeechToText` directly, and never speak while it's open. (R4, R9)
- **Text the app also speaks:** wrap it in `SpokenText`. (R2)
- **Notices:** `showSpokenNotice`, never a bare `SnackBar` for something spoken. (R2, R3)
- **Controls:** a label and enabled state that don't change while focused. Signal state with sound or the app's voice. (R5)
- **Covered or closed:**
  - Pages are `RouteAware` on `voiceRouteObserver`.
  - `didPushNext` and `dispose` release the owner and stop listening.
  - Answers for closed dialogs are dropped. (R12)
- **Lists:** at most 3 spoken items, then "más". Pick with `pickSpokenOption`. (R10)
- **Acting on speech:** confirm before acting on anything heard. (R11)
- **Asking on open:** with `screenReaderOn(context)`, wait ~2 s before the first listen. (R13)
- **Skipping:** `SkipSpeech` wraps the app (three taps, or the "Callar la app" TalkBack action). Never make skipping cancel or answer anything. (R8)
- **Strings:** every spoken string goes in both `app_en.arb` and `app_es.arb`.

## When checking a diff

For each changed file in `application/lib/` that speaks, listens, shows a notice or builds a user-facing control, go through this list and report each violation with its rule number and `file:line`:

1. `FlutterTts(`, `SpeechToText(` or `SnackBar(` outside `lib/voice/` → R1/R2.
2. A `say`/`_speak` that can run while the microphone is open, or a listen without a prompt → R4.
3. A `Semantics(label:` or button label/`onPressed` that depends on listening/busy state → R5.
4. `liveRegion: true` on text the app speaks or that updates per fix → R2.
5. `interrupt: true` / `assertive: true` for something that isn't safety or a requested repeat → R6.
6. A new screen or dialog that speaks without being `RouteAware`, or without releasing in `dispose` → R12.
7. A spoken list longer than 3 items → R10.
8. A trip, start or change acted on from speech without confirmation → R11.
9. A spoken string missing from either ARB file.
10. Tests: widget tests for a speaking screen pump it with a fake `AppVoice` (see `test/voice/` and `test/user/`), and cover TalkBack on (`MediaQueryData(accessibleNavigation: true)`) and off.

Finish with what needs a phone, done once with TalkBack on and once with it off:
- one voice at a time;
- nothing read twice;
- nothing spoken into the microphone;
- skipping works.
