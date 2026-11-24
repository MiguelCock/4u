import 'package:flutter/material.dart';

import '../voice/voice_attempts.dart';
import '../l10n/app_localizations.dart';
import '../services/voice_settings_menu.dart';
import '../services/destination_matcher.dart' show SpokenAnswer, spokenAnswer;
import '../services/app_preferences.dart';
import '../services/buzz.dart';
import '../services/geo_utils.dart';
import '../services/place_suggestions.dart';
import '../services/spoken_destination.dart';
import '../voice/home_voice_controller.dart';
import 'anchor_point_picker_screen.dart';
import 'home_dialogs.dart';
import 'trip_starter.dart';

/// What [DestinationConversation] needs from the screen it runs on.
abstract interface class ConversationHost {
  BuildContext get context;
  bool get mounted;

  /// Something shown changed: the destination, or the choices appearing.
  void conversationChanged();

  /// A destination was just chosen: an earlier error no longer applies.
  void destinationChosen();

  /// The user said yes to "Go to X?": find the route.
  Future<void> startTrip();

  /// Saves preference changes to the profile and applies them (#226).
  Future<void> savePreferences(Map<String, dynamic> changes);
}

/// Choosing where to go, by voice first (D1), or by hand (#268): asking,
/// listening, misses, several matches, "Go to X?", and the picker. Came out
/// of `UserHomeScreen`; the voice is [HomeVoiceController]'s, the places
/// [TripStarter]'s.
class DestinationConversation {
  DestinationConversation({
    required this.host,
    required this.voice,
    required this.trip,
  });

  final ConversationHost host;
  final HomeVoiceController voice;
  final TripStarter trip;

  /// Where the user chose to go, or null.
  Map<String, dynamic>? destination;

  /// Start and destination rows, shown only when the user asked for them
  /// in Settings, or when voice can't be used this time (D1, D2).
  bool _revealChoices = false;

  bool get showsChoices => homeShowsChoices(
    setting: showChoicesNotifier.value,
    revealed: _revealChoices,
  );

  /// Voice first (D1): the app asks and listens by itself, unless the phone
  /// has no recognizer.
  bool get voiceFirst => !_revealChoices;

  BuildContext get _context => host.context;
  AppLocalizations get _l10n => AppLocalizations.of(_context)!;
  String get _language => Localizations.localeOf(_context).languageCode;
  bool get _onTop => ModalRoute.of(_context)?.isCurrent == true;

  /// "Baño · Piso 2 · Edificio C" (see [destinationLabel]).
  String label(Map<String, dynamic> anchor) => destinationLabel(
    anchor,
    buildingNames: trip.buildingNames,
    floorLabel: (floor) => _l10n.commonFloorOption(floor + 1),
  );

  /// [label] to be read aloud.
  String spoken(Map<String, dynamic> anchor) => spokenLabel(label(anchor));

  /// Meters from the user, for the nearest-first order of same-named places.
  double _distanceFromUser(Map<String, dynamic> anchor) {
    final position = trip.location.lastPosition;
    final there = anchorPosition(anchor);
    if (position == null || there == null) return double.infinity;
    return haversineMeters(position.latLng, there);
  }

  List<Map<String, dynamic>> get _buildings => campusBuildings(
    trip.buildings,
    activeIds: trip.activeBuildings,
    startBuildingId: trip.start?['building_id'],
  );

  /// Right after sign-in: "Where do you want to go?", then listening. Not
  /// over another page, and not once a destination is chosen.
  Future<void> ask() async {
    if (!host.mounted || destination != null || !voiceFirst || !_onTop) return;
    voice.resetMisses();
    if (MediaQuery.of(_context).accessibleNavigation) {
      // TalkBack reads the new screen first; the question comes after it.
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!host.mounted) return;
    }
    final l10n = _l10n;
    await voice.say(l10n.homeAskDestination);
    if (!host.mounted || destination != null || !_onTop) return;
    await _listen(prompt: l10n.homeListenExample);
  }

  /// The Speak button: listens again, or stops listening. It never restarts
  /// anything else, which is how people got lost (D1). Stopping takes
  /// effect at once, whatever the recognizer does next.
  Future<void> speakButton() async {
    if (voice.isListening) {
      await voice.stopListeningByHand(_l10n.homeStoppedListening);
      return;
    }
    voice.resetMisses();
    await _listen(prompt: _l10n.homeListenPrompt);
  }

  /// Listens for a place, after saying [prompt] (what to say: a tester
  /// heard nothing and didn't know what to answer). Without a recognizer,
  /// says so once and shows the choices: retrying can't bring one back.
  Future<void> _listen({required String prompt}) async {
    final l10n = _l10n;
    final language = _language;
    await trip.ensureLoaded();
    if (!host.mounted) return;
    final started = await voice.listen(
      _heard,
      language: language,
      prompt: prompt,
    );
    if (started == ListenStart.unavailable && host.mounted) {
      _revealChoices = true;
      host.conversationChanged();
      await voice.say(l10n.homeVoiceUnavailable);
    }
  }

  Future<void> _heard(String heard) async {
    final l10n = _l10n;
    // Felt: listening has stopped.
    buzz(Buzz.short);
    // Every alternate the recognizer offered, best first (#262).
    final alternates = voice.lastHeard.isNotEmpty
        ? voice.lastHeard
        : [(words: heard, confidence: -1.0)];
    void logAttempt(String outcome, {String? used}) =>
        VoiceAttempts.instance.add(
          heard: alternates,
          soundPeak: voice.lastSoundPeak,
          outcome: outcome,
          used: used,
        );
    if (heard.trim().isEmpty) {
      logAttempt('nothing');
      await _missed(l10n.homeVoiceNothingHeard);
      return;
    }
    voice.resetMisses();
    if (asksForSettings(heard)) {
      logAttempt('settings');
      await _settingsMenu();
      return;
    }
    final buildings = _buildings;
    if (asksWhatPlaces(heard)) {
      logAttempt('what_places');
      await _suggest(buildings);
      return;
    }
    final candidates = destinationCandidates(
      trip.anchors,
      buildings: buildings,
      startId: trip.start?['id'],
    );
    // The top guess first; if it names nothing, the alternates (#262).
    final best = bestHeard(alternates, (words) {
      final found = resolveSpokenDestination(
        words,
        candidates: candidates,
        buildings: buildings,
        buildingNames: trip.buildingNames,
        distance: _distanceFromUser,
      );
      return found.isEmpty ? null : found;
    });
    final found = best?.result ?? const <Map<String, dynamic>>[];
    logAttempt(
      found.isEmpty ? 'no_match' : (found.length == 1 ? 'one' : 'several'),
      used: best != null && best.words != heard ? best.words : null,
    );
    if (found.isEmpty) {
      // Only mention a list when there's one on screen.
      await _missed(
        showsChoices
            ? l10n.homeVoiceNoMatchWithList(heard)
            : l10n.homeVoiceNoMatch(heard),
      );
      return;
    }
    await _chooseFrom(found);
  }

  /// Nothing usable was heard: say why, and try again up to
  /// [HomeVoiceController.retries] times, then stop with the way to carry
  /// on by hand. Never a loop.
  Future<void> _missed(String why) async {
    final l10n = _l10n;
    if (!voice.missed()) {
      if (!showsChoices) {
        await voice.say(why);
        await _offerManualSearch();
        return;
      }
      await voice.say('$why ${l10n.homeVoiceGiveUp}');
      return;
    }
    await voice.say(why);
    // A destination chosen earlier doesn't stop it: the user is asking again.
    if (host.mounted && _onTop) await _listen(prompt: l10n.homeListenPrompt);
  }

  /// After the last miss (#226): "¿Quieres activar la búsqueda manual?".
  /// "Sí" turns on the start and destination rows, saved like Settings.
  Future<void> _offerManualSearch() async {
    final l10n = _l10n;
    if (!host.mounted) return;
    await voice.say(l10n.homeOfferManualSearch);
    await voice.askUntil<SpokenAnswer>(
      spokenAnswer,
      onAnswer: (answer) async {
        if (answer == SpokenAnswer.change) {
          await voice.say(l10n.homeVoiceGiveUp);
          return;
        }
        if (await _save({VoiceSetting.manualSearch.key: true})) {
          host.conversationChanged();
          await voice.say(l10n.homeManualSearchOn);
        }
      },
      language: _language,
      notUnderstood: l10n.homeManualSearchSayYesOrNo,
      giveUp: l10n.homeVoiceGiveUp,
      retries: 1,
      stillOpen: () => host.mounted && _onTop,
    );
  }

  /// Saves [changes], and says so if it couldn't.
  Future<bool> _save(Map<String, dynamic> changes) async {
    try {
      await host.savePreferences(changes);
      return true;
    } catch (_) {
      await voice.say(_l10n.voiceSettingsSaveFailed);
      return false;
    }
  }

  /// "Ajustes" (#226): the settings read one at a time, each with its
  /// value; "sí", "no", "lenta/normal/rápida", "siguiente" or "salir".
  Future<void> _settingsMenu() async {
    final menu = VoiceSettingsMenu.current();
    await voice.say(_l10n.voiceSettingsIntro);
    await _menuStep(menu);
  }

  Future<void> _menuStep(VoiceSettingsMenu menu) async {
    final l10n = _l10n;
    if (!host.mounted || !_onTop) return;
    await voice.say(_menuPrompt(menu));
    Future<void> next() async {
      if (menu.advance()) {
        await _menuStep(menu);
      } else {
        await _closeMenu();
      }
    }

    await voice.askUntil<MenuReply>(
      menu.answer,
      onAnswer: (reply) async {
        switch (reply) {
          case MenuSet():
            if (await _save({reply.setting.key: reply.value})) {
              menu.set(reply);
              host.conversationChanged();
              await voice.say(
                l10n.voiceSettingsChanged(
                  _settingName(reply.setting),
                  _valueName(reply.setting, reply.value),
                ),
              );
            }
            await next();
          case MenuNext():
            await next();
          case MenuExit():
            await _closeMenu();
        }
      },
      language: _language,
      notUnderstood: l10n.voiceSettingsNotUnderstood,
      giveUp: l10n.voiceSettingsClosed,
      stillOpen: () => host.mounted && _onTop,
    );
  }

  Future<void> _closeMenu() async {
    await voice.say(_l10n.voiceSettingsClosed);
    if (host.mounted && _onTop) await _listen(prompt: _l10n.homeListenPrompt);
  }

  String _menuPrompt(VoiceSettingsMenu menu) {
    final l10n = _l10n;
    final setting = menu.current;
    final value = _valueName(setting, menu.values[setting]!);
    return setting == VoiceSetting.speed
        ? l10n.voiceSettingsSpeedPrompt(value)
        : l10n.voiceSettingsTogglePrompt(_settingName(setting), value);
  }

  String _settingName(VoiceSetting setting) {
    final l10n = _l10n;
    return switch (setting) {
      VoiceSetting.speed => l10n.voiceSettingSpeed,
      VoiceSetting.manualSearch => l10n.voiceSettingManualSearch,
      VoiceSetting.map => l10n.voiceSettingMap,
      VoiceSetting.boldText => l10n.voiceSettingBoldText,
      VoiceSetting.voiceGuidance => l10n.voiceSettingVoiceGuidance,
    };
  }

  String _valueName(VoiceSetting setting, Object value) {
    final l10n = _l10n;
    if (setting == VoiceSetting.speed) {
      return switch (speechRateName(value as double)) {
        'slow' => l10n.voiceSpeedSlow,
        'fast' => l10n.voiceSpeedFast,
        _ => l10n.voiceSpeedNormal,
      };
    }
    return value == true ? l10n.voiceSettingOn : l10n.voiceSettingOff;
  }

  /// "¿Qué lugares hay?" (D9): the nearest places, a few at a time.
  Future<void> _suggest(List<Map<String, dynamic>> buildings) async {
    final places = suggestedPlaces(
      destinationCandidates(
        trip.anchors,
        buildings: buildings,
        startId: trip.start?['id'],
      ),
      name: spoken,
      distance: _distanceFromUser,
    );
    if (places.isEmpty) {
      await voice.say(_l10n.homeNoPlacesYet);
      return;
    }
    await _chooseFrom(places, suggested: true);
  }

  /// One option goes straight to "Go to X?", several to a choice of a few
  /// at a time ([chooseDestination], D12 rule R10), with "más" for the next
  /// ones. [suggested]: an answer to "¿qué lugares hay?", read as "Cerca
  /// hay: …" even when there's one.
  Future<void> _chooseFrom(
    List<Map<String, dynamic>> found, {
    bool suggested = false,
  }) async {
    if (found.length == 1 && !suggested) {
      confirm(found.single);
      return;
    }
    for (var page = 0; ; page++) {
      final options = optionsPage(found, page);
      if (options.isEmpty) {
        // Only on a page asked for by "más" when there was none (a stale
        // button): back to asking.
        await voice.say(_l10n.homeNoMorePlaces);
        if (host.mounted && _onTop) {
          await _listen(prompt: _l10n.homeListenPrompt);
        }
        return;
      }
      final l10n = _l10n;
      final choice = await chooseDestination(
        _context,
        voice: voice,
        language: _language,
        options: options,
        label: label,
        spoken: spoken,
        listen: voiceFirst,
        intro: page > 0
            ? l10n.homeMoreOptions
            : suggested
            ? l10n.homeSuggestPlaces
            : null,
        more: found.length > (page + 1) * kOptionsPerPage,
      );
      if (!host.mounted) return;
      final picked = choice.picked;
      if (choice.more) continue;
      if (choice.noneOfThem) {
        ask(); // "ninguno": ask again
      } else if (picked != null) {
        confirm(picked);
      }
      return;
    }
  }

  /// A destination was chosen (by voice or from the list): "Go to X?"
  /// ([confirmDestination]), whose Start route button starts the trip.
  Future<void> confirm(Map<String, dynamic> anchor) async {
    destination = anchor;
    host.destinationChosen();
    final start = await confirmDestination(
      _context,
      voice: voice,
      language: _language,
      label: label(anchor),
      spoken: spoken(anchor),
      listen: voiceFirst,
    );
    if (!host.mounted) return;
    if (start == true) {
      host.startTrip();
    } else if (start == false) {
      if (showsChoices) {
        // "Change destination": every tester was unsure how to (2026-11-03).
        pickByHand();
      } else {
        // No list on screen: ask again instead.
        destination = null;
        host.conversationChanged();
        ask();
      }
    }
  }

  /// The University → Building → place picker, then "Go to X?".
  Future<void> pickByHand() async {
    final picked = await Navigator.of(_context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => AnchorPointPickerScreen(
          title: _l10n.homeWhereTo,
          excludeAnchorId: trip.start?['id'] as String?,
        ),
      ),
    );
    if (picked != null && host.mounted) {
      await voice.say(_l10n.homeYouChose(spoken(picked)));
      if (host.mounted) confirm(picked);
    }
  }
}
