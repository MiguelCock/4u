import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/app_preferences.dart';
import '../services/buzz.dart';
import '../services/spoken_destination.dart';
import '../services/geo_utils.dart';
import '../services/location_service.dart';
import 'anchor_point_picker_screen.dart';
import 'home_dialogs.dart';
import 'home_tutorial.dart';
import 'navigation_screen.dart';
import 'trip_starter.dart';
import 'unfinished_trip.dart';
import 'settings_screen.dart';
import '../services/api_error_messages.dart';
import '../services/exit_guard.dart';
import '../voice/app_voice.dart';
import '../voice/home_voice_controller.dart';
import '../widgets/speak_circle.dart';

/// The `user`-role home screen IS the trip-planning flow now (not a map,
/// not a separate screen reached via a FAB): the user only picks a
/// destination - the start point is auto-selected as the verified anchor
/// point nearest to them, Uber-pickup-pin style, rather than making them
/// pick both ends. It's shown as soon as it's known (from raw GPS), and
/// re-picked from a camera-corrected position when they tap Find route.
class UserHomeScreen extends StatefulWidget {
  /// True when reached via AdminHomeScreen's "Test as user" drawer entry
  /// (#79) - purely cosmetic (shows a banner so an admin can't mistake this
  /// for a second real account), no behavior change: nothing downstream of
  /// here (this screen, NavigationScreen, the feedback dialog) checks role.
  final bool adminPreview;

  /// What the screen talks to, for tests (#268). Every real caller uses the
  /// defaults: the gateway's APIs, the app's one recognizer, location and
  /// voice.
  final MapManagementApi? mapApi;
  final RouteManagementApi? routeApi;
  final PositioningApi? positioningApi;
  final NavigationManagementApi? navigationApi;
  final LocationService? locationService;
  final SpeechToText? speech;
  final AppVoice? voice;

  const UserHomeScreen({
    super.key,
    this.adminPreview = false,
    this.mapApi,
    this.routeApi,
    this.positioningApi,
    this.navigationApi,
    this.locationService,
    this.speech,
    this.voice,
  });

  @override
  State<UserHomeScreen> createState() => _UserHomeScreenState();
}

class _UserHomeScreenState extends State<UserHomeScreen> with RouteAware {
  late final _routeApi = widget.routeApi ?? RouteManagementApi();
  late final _locationService = widget.locationService ?? LocationService();
  StreamSubscription<Position>? _positionSub;

  /// The start, the map behind it, and the route (#268).
  late final TripStarter _trip;

  /// A trip left open last time (#268).
  late final _unfinished = UnfinishedTrips(
    navigationApi: widget.navigationApi,
    routeApi: _routeApi,
    locationService: _locationService,
  );
  Map<String, dynamic>? _end;
  bool _finding = false;
  Timer? _stillFindingTimer;

  bool _askingFloor = false;
  static const Duration _kStillFindingEvery = Duration(seconds: 5);
  String? _error;
  final _exitGuard = ExitGuard();

  // Saying the destination out loud (speech_to_text) instead of drilling
  // down University -> Building -> place.

  /// Speaking and listening (#268): the voice, the microphone, their
  /// order, misses, and going quiet while a page covers this screen.
  late final HomeVoiceController _voiceCtl;
  bool _routeSubscribed = false;
  bool get _listening => _voiceCtl.isListening;

  @override
  void initState() {
    super.initState();
    _voiceCtl = HomeVoiceController(speech: widget.speech, voice: widget.voice)
      ..listening.addListener(_onListeningChanged);
    _trip = TripStarter(
      mapApi: widget.mapApi,
      routeApi: _routeApi,
      positioningApi: widget.positioningApi,
      locationService: _locationService,
    )..addListener(_onTripChanged);
    _positionSub = _locationService.positionStream.listen(
      (position) => _trip.onPosition(position, busy: _finding),
    );
    _loadAnchors();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final resumed = await _checkUnfinishedTrip();
      // Admins' "Test as user" too: testers at Icesi used it.
      await _showTutorialOnFirstRun();
      if (!resumed) await _askForDestination();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _voiceCtl.setLanguage(Localizations.localeOf(context).languageCode);
    final route = ModalRoute.of(context);
    if (!_routeSubscribed && route is PageRoute) {
      _routeSubscribed = true;
      voiceRouteObserver.subscribe(this, route);
    }
  }

  /// A page (a trip, Settings) now covers this screen: stop listening and
  /// give up the voice until it's back on top.
  @override
  void didPushNext() => _voiceCtl.cover();

  @override
  void didPopNext() => _voiceCtl.uncover();

  void _onListeningChanged() {
    if (mounted) setState(() {});
  }

  void _onTripChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _stillFindingTimer?.cancel();
    _positionSub?.cancel();
    if (_routeSubscribed) voiceRouteObserver.unsubscribe(this);
    _voiceCtl.listening.removeListener(_onListeningChanged);
    _voiceCtl.dispose();
    _trip
      ..removeListener(_onTripChanged)
      ..dispose();
    super.dispose();
  }

  /// Speaks [text] with the app's own voice, TalkBack on or not. Nothing is
  /// shown: a status line on screen read as if it were still true ("I'm
  /// listening" after stopping), and TalkBack reading it would be heard by
  /// the recognizer (D1).
  /// Always, whatever "Guía de voz" says: that setting is for the trip's
  /// instructions, and with it off this screen was silent.
  Future<void> _say(String text, {bool interrupt = false}) =>
      _voiceCtl.say(text, interrupt: interrupt);

  /// Start and destination rows, shown only when the user asked for them
  /// in Settings, or when voice can't be used this time (D1, D2).
  bool _revealChoices = false;

  bool get _showsChoices => homeShowsChoices(
    setting: showChoicesNotifier.value,
    revealed: _revealChoices,
  );

  /// Buildings a user can be sent to (see [campusBuildings]).
  List<Map<String, dynamic>> get _campusBuildings => campusBuildings(
    _trip.buildings,
    activeIds: _trip.activeBuildings,
    startBuildingId: _trip.start?['building_id'],
  );

  List<Map<String, dynamic>> get _destinationCandidates =>
      destinationCandidates(
        _trip.anchors,
        buildings: _campusBuildings,
        startId: _trip.start?['id'],
      );

  /// [_destinationLabel] to be read aloud.
  String _spokenLabel(Map<String, dynamic> anchor) =>
      spokenLabel(_destinationLabel(anchor));

  /// Meters from the user, for the nearest-first order of same-named places.
  double _distanceFromUser(Map<String, dynamic> anchor) {
    final position = _locationService.lastPosition;
    final lat = (anchor['latitude'] as num?)?.toDouble();
    final lng = (anchor['longitude'] as num?)?.toDouble();
    if (position == null || lat == null || lng == null) return double.infinity;
    return haversineMeters(
      LatLng(position.latitude, position.longitude),
      LatLng(lat, lng),
    );
  }

  String _destinationLabel(Map<String, dynamic> anchor) => destinationLabel(
    anchor,
    buildingNames: _trip.buildingNames,
    floorLabel: (floor) =>
        AppLocalizations.of(context)!.commonFloorOption(floor + 1),
  );

  /// Voice first (D1): the app asks and listens by itself, unless the voice is
  /// off or a screen reader is on (it would be heard as the answer). Not
  /// over a dialog, and never again once a destination is chosen.
  bool get _voiceFirst => !_revealChoices;

  /// Right after sign-in: "Where do you want to go?", then listening.
  Future<void> _askForDestination() async {
    if (!mounted || _end != null || !_voiceFirst) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    _voiceCtl.resetMisses();
    if (MediaQuery.of(context).accessibleNavigation) {
      // TalkBack reads the new screen first; the question comes after it.
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
    }
    final l10n = AppLocalizations.of(context)!;
    await _say(l10n.homeAskDestination);
    if (!mounted || _end != null || ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    await _startListening(_handleSpoken, prompt: l10n.homeListenExample);
  }

  /// Nothing usable was heard: say why, and try again up to
  /// [HomeVoiceController.retries]
  /// times, then stop with the way to carry on by hand. Never a loop.
  Future<void> _missed(String why) async {
    final l10n = AppLocalizations.of(context)!;
    if (!_voiceCtl.missed()) {
      await _say('$why ${l10n.homeVoiceGiveUp}');
      return;
    }
    await _say(why);
    // A destination chosen earlier doesn't stop it: the user is asking again.
    if (mounted && ModalRoute.of(context)?.isCurrent == true) {
      await _startListening(_handleSpoken, prompt: l10n.homeListenPrompt);
    }
  }

  /// The Speak button: listens again, or stops listening. It never restarts
  /// anything else, which is how people got lost (D1). Stopping takes effect
  /// at once, whatever the recognizer does next.
  Future<void> _listenForDestination() async {
    if (_listening) {
      await _voiceCtl.stopListeningByHand(
        AppLocalizations.of(context)!.homeStoppedListening,
      );
      return;
    }
    _voiceCtl.resetMisses();
    await _startListening(
      _handleSpoken,
      prompt: AppLocalizations.of(context)!.homeListenPrompt,
    );
  }

  /// Opens the microphone once, after saying [prompt] (what to say: a tester
  /// heard nothing and didn't know what to answer), with a felt and heard
  /// mark just before (the recognizer isn't on yet, so it doesn't take them
  /// as speech). Calls [onHeard] once with what was said, '' for nothing.
  /// False when there's no recognizer or microphone.
  Future<bool> _startListening(
    Future<void> Function(String heard) onHeard, {
    String? prompt,
    Duration listenFor = const Duration(seconds: 30),
    Duration pauseFor = const Duration(seconds: 5),
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final language = Localizations.localeOf(context).languageCode;

    await _trip.ensureLoaded();
    if (!mounted) return false;
    final started = await _voiceCtl.listen(
      onHeard,
      language: language,
      prompt: prompt,
      listenFor: listenFor,
      pauseFor: pauseFor,
    );
    if (started == ListenStart.unavailable && mounted) {
      // Said once, and the choices appear. Retrying can't bring a
      // microphone back.
      setState(() => _revealChoices = true);
      await _say(l10n.homeVoiceUnavailable);
    }
    return started == ListenStart.started;
  }

  Future<void> _handleSpoken(String heard) async {
    final l10n = AppLocalizations.of(context)!;
    // Felt: listening has stopped.
    buzz(Buzz.short);
    if (heard.trim().isEmpty) {
      await _missed(l10n.homeVoiceNothingHeard);
      return;
    }
    _voiceCtl.resetMisses();
    final found = resolveSpokenDestination(
      heard,
      candidates: _destinationCandidates,
      buildings: _campusBuildings,
      buildingNames: _trip.buildingNames,
      distance: _distanceFromUser,
    );
    if (found.isEmpty) {
      // Only mention a list when there's one on screen.
      await _missed(
        _showsChoices
            ? l10n.homeVoiceNoMatchWithList(heard)
            : l10n.homeVoiceNoMatch(heard),
      );
      return;
    }
    await _chooseFrom(found);
  }

  /// One option goes straight to "Go to X?", several to a choice of the first
  /// few ([chooseDestination]).
  Future<void> _chooseFrom(List<Map<String, dynamic>> found) async {
    if (found.length == 1) {
      _confirmAndStart(found.single);
      return;
    }
    final choice = await chooseDestination(
      context,
      voice: _voiceCtl,
      language: Localizations.localeOf(context).languageCode,
      options: found.take(3).toList(),
      label: _destinationLabel,
      spoken: _spokenLabel,
      listen: _voiceFirst,
    );
    if (!mounted) return;
    final picked = choice.picked;
    if (choice.noneOfThem) {
      _askForDestination(); // "ninguno": ask again
    } else if (picked != null) {
      _confirmAndStart(picked);
    }
  }

  /// A destination was chosen (by voice or from the list): "Go to X?"
  /// ([confirmDestination]), whose Start route button starts the trip.
  Future<void> _confirmAndStart(Map<String, dynamic> anchor) async {
    setState(() {
      _end = anchor;
      _error = null;
    });
    final start = await confirmDestination(
      context,
      voice: _voiceCtl,
      language: Localizations.localeOf(context).languageCode,
      label: _destinationLabel(anchor),
      spoken: _spokenLabel(anchor),
      listen: _voiceFirst,
    );
    if (!mounted) return;
    if (start == true) {
      _findRoute();
    } else if (start == false) {
      if (_showsChoices) {
        // "Change destination": every tester was unsure how to (2026-11-03).
        _pickEnd();
      } else {
        // No list on screen: ask again instead.
        setState(() => _end = null);
        _askForDestination();
      }
    }
  }

  /// Best-effort early load (see [TripStarter.loadQuietly]).
  Future<void> _loadAnchors() => _trip.loadQuietly();

  /// How the Start row names the start point. Unnamed in-between points
  /// (hallways...) have no description, so they're described by distance
  /// instead of a raw id.
  String _startLabel(AppLocalizations l10n, Map<String, dynamic> start) {
    final description = (start['location_description'] as String? ?? '').trim();
    if (description.isNotEmpty) {
      return l10n.homeStartNearestSubtitle(_destinationLabel(start));
    }
    final position = _locationService.lastPosition;
    final lat = (start['latitude'] as num?)?.toDouble();
    final lng = (start['longitude'] as num?)?.toDouble();
    if (position == null || lat == null || lng == null) {
      return l10n.homeStartSubtitle;
    }
    final meters = haversineMeters(
      LatLng(position.latitude, position.longitude),
      LatLng(lat, lng),
    ).round();
    return l10n.homeStartUnnamedSubtitle(meters);
  }

  Future<void> _pickEnd() async {
    final picked = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => AnchorPointPickerScreen(
          title: AppLocalizations.of(context)!.homeWhereTo,
          excludeAnchorId: _trip.start?['id'] as String?,
        ),
      ),
    );
    if (picked != null && mounted) {
      await _say(
        AppLocalizations.of(context)!.homeYouChose(_spokenLabel(picked)),
      );
      if (mounted) _confirmAndStart(picked);
    }
  }

  /// Runs the start-point check ([TripStarter.locateStart]) and says what it
  /// found. Shared by Find route and tapping the Start row. Throws
  /// ApiException if the anchors can't be loaded.
  Future<Map<String, dynamic>?> _locateStart() async {
    final l10n = AppLocalizations.of(context)!;
    final check = await _trip.locateStart(
      // Said in full before the first photo: the user turns while it's taken.
      beforePhotos: () async {
        if (mounted) await _say(l10n.homeCheckingStartPrompt);
      },
    );
    if (!mounted) return null;
    final start = check.start;
    if (start != null) {
      final description = (start['location_description'] as String? ?? '')
          .trim();
      _say(
        l10n.homeStartChecked(
          description.isNotEmpty ? description : l10n.homeStartNearestPoint,
          check.matched,
          TripStarter.checkPhotos,
        ),
      );
    }
    return start;
  }

  /// Tapping the Start row: run the check on demand.
  Future<void> _relocateStart() async {
    if (_trip.locating || _finding) return;
    setState(() => _error = null);
    try {
      await _locateStart();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = AppLocalizations.of(
          context,
        )!.commonErrorLoadDataFailed(friendlyApiErrorMessage(context, e));
      });
      _say(_error!);
    }
  }

  /// First launch: the spoken tutorial once, on its own.
  Future<void> _showTutorialOnFirstRun() async {
    if (await firstRunTutorialDue() && mounted) await _showTutorial();
  }

  Future<void> _showTutorial() => showHomeTutorial(context, voice: _voiceCtl);

  /// A trip left open by closing the app mid-route ([UnfinishedTrips]):
  /// continued or finished. True when the user went back into it.
  Future<bool> _checkUnfinishedTrip() async {
    final trip = await _unfinished.find();
    if (trip == null || !mounted) return false;
    if (_trip.anchors.isEmpty) await _loadAnchors();
    if (!mounted) return false;
    final end = _trip.anchors.where(
      (a) => a['id'] == trip.route['end_anchor_id'],
    );
    final resume = await askResumeTrip(
      context,
      trip: trip,
      destination: end.isEmpty
          ? null
          : end.first['location_description'] as String?,
    );
    if (!mounted) return false;
    if (resume) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => NavigationScreen(
            route: trip.route,
            resumeSessionId: trip.session['id'] as String,
            adminPreview: widget.adminPreview,
          ),
        ),
      );
      return true;
    }
    await _unfinished.abandon(trip.session);
    return false;
  }

  /// Which of [floors] the user is on: their earlier answer until they've
  /// moved [TripStarter.keepWithinMeters], else asked ([askStartFloor]). Null
  /// if they back out.
  Future<int?> _startFloor(List<int> floors, LatLng here) async {
    final remembered = _trip.rememberedFloor(floors, here);
    if (remembered != null) return remembered;
    _askingFloor = true;
    final floor = await askStartFloor(
      context,
      voice: _voiceCtl,
      floors: floors,
    );
    _askingFloor = false;
    if (floor != null) _trip.rememberFloor(floor, here);
    return floor;
  }

  /// backend-route-management's 404 detail says which end isn't connected.
  String _noPathMessage(AppLocalizations l10n, String? detail) =>
      switch (noPathEnd(detail)) {
        NoPathEnd.start => l10n.homeErrorNoPathStart,
        NoPathEnd.destination => l10n.homeErrorNoPathDestination,
        NoPathEnd.unknown => l10n.homeErrorNoPath,
      };

  Future<void> _findRoute() async {
    final end = _end;
    if (end == null) return;
    setState(() {
      _finding = true;
      _error = null;
    });

    final l10n = AppLocalizations.of(context)!;
    _say(
      _locationService.lastPosition == null
          ? l10n.homeSearchingLocation
          : l10n.homeFindingRoute,
    );
    // Silence while it worked made testers think it was broken.
    _stillFindingTimer?.cancel();
    _stillFindingTimer = Timer.periodic(_kStillFindingEvery, (_) {
      if (!mounted || !_finding) {
        _stillFindingTimer?.cancel();
        return;
      }
      if (!_askingFloor) _say(l10n.commonOneMoment);
    });
    void sayRetrying() {
      if (mounted && _finding) _say(l10n.commonRetrying);
    }

    ApiService.retries.addListener(sayRetrying);
    try {
      await _findRouteFrom(l10n);
    } finally {
      ApiService.retries.removeListener(sayRetrying);
      _stillFindingTimer?.cancel();
    }
  }

  Future<void> _findRouteFrom(AppLocalizations l10n) async {
    final end = _end!;
    // Waits for a fix (and re-checks location) instead of giving up on the
    // first try: in battery saver that said "GPS off" while it was on.
    final position = await _locationService.ensureReady();
    if (!mounted) return;
    if (position == null) {
      setState(() {
        _error = _locationService.lastError == LocationError.serviceDisabled
            ? l10n.locationServiceDisabledError
            : _locationService.lastError != null
            ? l10n.locationPermissionDeniedError
            : l10n.homeErrorNoGpsFix;
        _finding = false;
      });
      _say(_error!);
      return;
    }

    try {
      // Everyone gets the camera check of the start (it says to hold the
      // phone up and turn slowly). The first user test found it confusing
      // when its instruction wasn't heard: it was spoken over the open
      // microphone, which `_say` no longer does.
      final here = LatLng(position.latitude, position.longitude);
      var start = _trip.checkIsFresh ? _trip.start : await _locateStart();
      if (!mounted) return;
      // GPS can't tell floors apart: the nearest point may be overhead.
      final floors = floorsNear(_trip.anchors, here);
      if (start != null && floors.length > 1) {
        final floor = await _startFloor(floors, here);
        if (!mounted) return;
        if (floor == null) {
          setState(() {
            _finding = false;
          });
          return;
        }
        start = _trip.startOnFloor(floor, here);
      }
      if (start == null) {
        setState(() {
          _error = AppLocalizations.of(context)!.homeErrorNoVerifiedAnchors;
          _finding = false;
        });
        _say(_error!);
        return;
      }
      if (alreadyAt(start, end)) {
        setState(() {
          _error = AppLocalizations.of(context)!.homeErrorAlreadyAtDestination(
            end['location_description'] as String? ?? end['id'] as String,
          );
          _finding = false;
        });
        _say(_error!);
        return;
      }

      final route = await _trip.findRoute(start, end);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => NavigationScreen(
            route: route,
            destinationName: _spokenLabel(end),
            adminPreview: widget.adminPreview,
          ),
        ),
      );
      setState(() => _finding = false);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.statusCode == 404
            ? _noPathMessage(AppLocalizations.of(context)!, e.detail)
            : AppLocalizations.of(context)!.homeErrorFailedToFindRoute(
                friendlyApiErrorMessage(context, e),
              );
        _finding = false;
      });
      _say(_error!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Root screen for users (AuthGate's child, not a pushed route): back
    // asks to press again instead of closing the app. The admin's "Test as
    // user" preview is a pushed route, so there back just pops.
    return PopScope(
      canPop: widget.adminPreview,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitGuard.onBack(context);
      },
      child: _scaffold(l10n),
    );
  }

  Widget _scaffold(AppLocalizations l10n) {
    return Scaffold(
      // Only about going somewhere: the account options are at the bottom
      // (D2), where they don't compete with the main task.
      appBar: AppBar(title: Text(l10n.appTitle), backgroundColor: Colors.blue),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadAnchors,
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(child: _body(l10n)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The one button of the simple home screen: a circle, not a screen-wide
  /// pill. While listening its colour and icon change; no text says so.
  Widget _speakCircle(AppLocalizations l10n) => SpeakCircle(
    listening: _listening,
    busy: _finding,
    label: l10n.homeSayDestinationButton,
    stopLabel: l10n.homeStopListeningButton,
    onPressed: _listenForDestination,
  );

  Widget _body(AppLocalizations l10n) {
    // Without the choices the screen is one big Speak button (D1/D2): the
    // simplest it can be. They appear when voice can't be used.
    final choices = _showsChoices;
    return Column(
      children: [
        if (widget.adminPreview)
          Container(
            width: double.infinity,
            color: Colors.amber.shade100,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              l10n.adminPreviewBanner,
              // Explicit dark color - this background is a fixed light
              // amber regardless of theme, and in dark mode the ambient
              // text color defaults to near-white (same issue fixed for
              // LocationInfo's GPS row).
              style: const TextStyle(
                color: Colors.black87,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (choices) ...[
          ListTile(
            leading: const Icon(Icons.radio_button_checked, color: Colors.blue),
            title: Text(l10n.homeStartLabel),
            // Not a live region: it changes on every GPS fix, and the
            // start check's result is spoken (#257).
            subtitle: Semantics(
              child: Text(
                _trip.locating
                    ? (_trip.progress > 0
                          ? l10n.homeCheckingStartProgress(
                              _trip.progress,
                              TripStarter.checkPhotos,
                            )
                          : l10n.homeLocatingStart)
                    : _trip.start != null
                    ? _startLabel(l10n, _trip.start!)
                    : l10n.homeStartSubtitle,
              ),
            ),
            trailing: _trip.locating
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : widget.adminPreview
                ? Icon(
                    Icons.my_location,
                    semanticLabel: l10n.homeCheckStartTooltip,
                  )
                : null,
            onTap: !widget.adminPreview || _trip.locating || _finding
                ? null
                : _relocateStart,
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(
              _end == null ? Icons.radio_button_unchecked : Icons.location_on,
              color: _end == null ? Colors.grey : Colors.blue,
            ),
            // "¿A dónde vas? Biblioteca" read as a question about the place
            // already chosen: no tester knew it was where to change it.
            title: Text(
              _end == null
                  ? l10n.homeChooseDestination
                  : l10n.homeDestinationLabel(
                      _end!['location_description'] as String? ??
                          _end!['id'] as String,
                    ),
            ),
            subtitle: Text(
              _end == null
                  ? l10n.homeTapToChooseDestination
                  : l10n.homeTapToChangeDestination,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickEnd,
          ),
        ],
        if (!choices) Expanded(child: Center(child: _speakCircle(l10n))),
        if (choices)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
              ),
              onPressed: _finding ? null : _listenForDestination,
              icon: Icon(_listening ? Icons.stop_circle_outlined : Icons.mic),
              label: Text(
                _listening ? l10n.homeListening : l10n.homeSayDestinationButton,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16.0),
            // Spoken by _say where it's set; a live region made TalkBack
            // say it a second time (#257).
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        if (!choices && _finding)
          Padding(
            padding: const EdgeInsets.all(16),
            child: LinearProgressIndicator(
              semanticsLabel: l10n.homeFindingRoute,
            ),
          ),
        if (choices) ...[
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(64),
                textStyle: Theme.of(context).textTheme.titleLarge,
              ),
              onPressed: (_end != null && !_finding) ? _findRoute : null,
              child: _finding
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        semanticsLabel: l10n.homeFindingRoute,
                      ),
                    )
                  : Text(l10n.homeFindRouteButton),
            ),
          ),
        ],
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.help_outline),
          title: Text(l10n.homeTutorialButton),
          onTap: () async {
            await _say(l10n.homeOpeningHelp);
            if (mounted) _showTutorial();
          },
        ),
        ListTile(
          leading: const Icon(Icons.settings_outlined),
          title: Text(l10n.homeSettingsTooltip),
          onTap: () async {
            await _say(l10n.homeOpeningSettings);
            if (!mounted) return;
            await Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
          },
        ),
        ListTile(
          leading: const Icon(Icons.logout),
          title: Text(l10n.commonLogOut),
          onTap: () async {
            await _say(l10n.homeLoggingOut, interrupt: true);
            await Supabase.instance.client.auth.signOut();
          },
        ),
      ],
    );
  }
}
