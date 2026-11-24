import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/geo_utils.dart';
import '../services/location_service.dart';
import 'destination_conversation.dart';
import 'home_dialogs.dart';
import 'home_tutorial.dart';
import 'home_widgets.dart';
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

class _UserHomeScreenState extends State<UserHomeScreen>
    with RouteAware
    implements ConversationHost {
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
      if (!resumed) await _talk.ask();
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

  /// Choosing where to go (#268): voice first, or by hand.
  late final _talk = DestinationConversation(
    host: this,
    voice: _voiceCtl,
    trip: _trip,
  );

  @override
  void conversationChanged() {
    if (mounted) setState(() {});
  }

  @override
  void destinationChosen() {
    if (mounted) setState(() => _error = null);
  }

  @override
  Future<void> startTrip() => _findRoute();

  /// Best-effort early load (see [TripStarter.loadQuietly]).
  Future<void> _loadAnchors() => _trip.loadQuietly();

  /// How the Start row names the start point. Unnamed in-between points
  /// (hallways...) have no description, so they're described by distance
  /// instead of a raw id.
  String _startLabel(AppLocalizations l10n, Map<String, dynamic> start) {
    final description = (start['location_description'] as String? ?? '').trim();
    if (description.isNotEmpty) {
      return l10n.homeStartNearestSubtitle(_talk.label(start));
    }
    final position = _locationService.lastPosition;
    final there = anchorPosition(start);
    if (position == null || there == null) return l10n.homeStartSubtitle;
    final meters = haversineMeters(position.latLng, there).round();
    return l10n.homeStartUnnamedSubtitle(meters);
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
      _fail(
        AppLocalizations.of(
          context,
        )!.commonErrorLoadDataFailed(friendlyApiErrorMessage(context, e)),
      );
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

  Future<void> _findRoute() async {
    final end = _talk.destination;
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
    final end = _talk.destination!;
    final outcome = await _trip.planTrip(
      end,
      locate: _locateStart,
      askFloor: _startFloor,
    );
    if (!mounted) return;
    switch (outcome) {
      case TripFound(:final route):
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => NavigationScreen(
              route: route,
              destinationName: _talk.spoken(end),
              adminPreview: widget.adminPreview,
              placesNearby: _trip.anchors,
            ),
          ),
        );
        setState(() => _finding = false);
      case TripCancelled():
        setState(() => _finding = false);
      default:
        _fail(
          tripOutcomeMessage(
            l10n,
            outcome,
            destination: end,
            apiError: (e) => friendlyApiErrorMessage(context, e),
          )!,
        );
    }
  }

  /// Something stopped the trip from starting: shown, and said once.
  void _fail(String message) {
    setState(() {
      _error = message;
      _finding = false;
    });
    _say(message);
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
    onPressed: _talk.speakButton,
  );

  Widget _body(AppLocalizations l10n) {
    // Without the choices the screen is one big Speak button (D1/D2): the
    // simplest it can be. They appear when voice can't be used.
    final choices = _talk.showsChoices;
    final end = _talk.destination;
    return Column(
      children: [
        if (widget.adminPreview) const AdminPreviewBanner(),
        if (choices) ...[
          StartRow(
            subtitle: _startSubtitle(l10n),
            locating: _trip.locating,
            canCheck: widget.adminPreview,
            onCheck: !widget.adminPreview || _trip.locating || _finding
                ? null
                : _relocateStart,
          ),
          const Divider(height: 1),
          DestinationRow(
            name: end == null
                ? null
                : end['location_description'] as String? ?? end['id'] as String,
            onTap: _talk.pickByHand,
          ),
          SayDestinationButton(
            listening: _listening,
            onPressed: _finding ? null : _talk.speakButton,
          ),
        ] else
          Expanded(child: Center(child: _speakCircle(l10n))),
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
          FindRouteButton(
            finding: _finding,
            onPressed: (end != null && !_finding) ? _findRoute : null,
          ),
        ],
        HomeFooter(
          onHelp: () => _then(l10n.homeOpeningHelp, _showTutorial),
          onSettings: () => _then(
            l10n.homeOpeningSettings,
            () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
          onLogOut: () async {
            await _say(l10n.homeLoggingOut, interrupt: true);
            await Supabase.instance.client.auth.signOut();
          },
        ),
      ],
    );
  }

  /// Every action says what it does first (D1), then does it if the screen
  /// is still there.
  Future<void> _then(String saying, Future<void> Function() action) async {
    await _say(saying);
    if (mounted) await action();
  }

  /// The Start row's text: the check's progress, the start, or "your
  /// current location" until one is known.
  String _startSubtitle(AppLocalizations l10n) {
    final start = _trip.start;
    if (_trip.locating) {
      return _trip.progress > 0
          ? l10n.homeCheckingStartProgress(
              _trip.progress,
              TripStarter.checkPhotos,
            )
          : l10n.homeLocatingStart;
    }
    return start != null ? _startLabel(l10n, start) : l10n.homeStartSubtitle;
  }
}
