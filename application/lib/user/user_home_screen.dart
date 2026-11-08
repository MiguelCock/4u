import 'dart:async';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HapticFeedback, SystemSound, SystemSoundType;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/app_preferences.dart';
import '../services/camera_helper.dart';
import '../services/destination_matcher.dart';
import '../services/destinations.dart';
import '../services/geo_utils.dart';
import '../services/image_utils.dart';
import '../services/location_service.dart';
import 'anchor_point_picker_screen.dart';
import 'navigation_screen.dart';
import 'settings_screen.dart';
import '../services/api_error_messages.dart';
import '../services/exit_guard.dart';
import '../services/speech_voice.dart';

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

  const UserHomeScreen({super.key, this.adminPreview = false});

  @override
  State<UserHomeScreen> createState() => _UserHomeScreenState();
}

class _UserHomeScreenState extends State<UserHomeScreen> {
  final _mapApi = MapManagementApi();
  final _routeApi = RouteManagementApi();
  final _positioningApi = PositioningApi();
  final _navigationApi = NavigationManagementApi();
  final _locationService = LocationService();
  StreamSubscription<Position>? _positionSub;

  List<Map<String, dynamic>> _verifiedAnchors = [];
  Map<String, dynamic>? _start;
  Map<String, dynamic>? _end;
  bool _finding = false;
  Timer? _stillFindingTimer;

  /// The user's answer to "which floor are you on?", kept until they've moved
  /// (see _startFloor).
  int? _answeredFloor;
  LatLng? _answeredFloorFrom;
  bool _askingFloor = false;
  static const Duration _kStillFindingEvery = Duration(seconds: 5);
  bool _locatingStart = false;
  int _startCheckProgress = 0;
  DateTime? _startCheckedAt;
  LatLng? _startCheckedFrom;
  String? _error;
  final _exitGuard = ExitGuard();

  // Saying the destination out loud (speech_to_text) instead of drilling
  // down University -> Building -> place.
  final _speech = SpeechToText();
  final _tts = FlutterTts();
  Future<bool>? _ttsReady;
  String? _ttsLanguage;
  bool _listening = false;
  String _heard = '';
  String? _voiceStatus;
  Map<String, String> _buildingNames = {};
  List<Map<String, dynamic>> _buildings = [];

  /// Known once the universities have loaded (see _fetchVerifiedAnchors).
  Set<String>? _activeBuildingIds;

  @override
  void initState() {
    super.initState();
    _positionSub = _locationService.positionStream.listen(_recomputeStart);
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
    final language = Localizations.localeOf(context).languageCode;
    if (language != _ttsLanguage) {
      _ttsLanguage = language;
      _ttsReady = configureTts(_tts, language).then((ready) async {
        // Speaking returns once it's said, so listening never starts while
        // the app is still talking: the recognizer would hear it.
        try {
          await _tts.awaitSpeakCompletion(true);
        } catch (_) {}
        return ready;
      });
    }
  }

  @override
  void dispose() {
    _stillFindingTimer?.cancel();
    _positionSub?.cancel();
    _speech.cancel();
    _tts.stop();
    super.dispose();
  }

  /// Shows [text] as the voice-search status (a live region) and, unless a
  /// screen reader is already reading that live region aloud, speaks it.
  Future<void> _say(String text, {bool show = true}) async {
    if (show) setState(() => _voiceStatus = text);
    if (!voiceGuidanceNotifier.value ||
        MediaQuery.of(context).accessibleNavigation) {
      return;
    }
    await _ttsReady;
    await _tts.stop();
    await _tts.speak(text);
  }

  /// Buildings a user can be sent to: active, on the campus they're on. A
  /// route can't cross campuses, and every campus has an "Edificio A".
  List<Map<String, dynamic>> get _campusBuildings {
    final active = _activeBuildingIds;
    final startBuilding = _start?['building_id'];
    String? campus;
    for (final building in _buildings) {
      if (building['id'] == startBuilding) {
        campus = building['place_id'] as String?;
      }
    }
    return _buildings
        .where(
          (b) =>
              (active?.contains(b['id']) ?? b['is_active'] != false) &&
              (campus == null || b['place_id'] == campus),
        )
        .toList();
  }

  List<Map<String, dynamic>> get _destinationCandidates {
    final campus = {for (final b in _campusBuildings) b['id']};
    return _verifiedAnchors
        .where(
          (a) =>
              isDestinationAnchor(a) &&
              a['id'] != _start?['id'] &&
              (campus.isEmpty || campus.contains(a['building_id'])),
        )
        .toList();
  }

  /// A building as a destination, in the shape of a point: the server picks
  /// the door when the route is requested.
  Map<String, dynamic> _wholeBuilding(Map<String, dynamic> building) => {
    'id': 'building:${building['id']}',
    'building_id': building['id'],
    'location_description': building['name'],
    'latitude': building['latitude'],
    'longitude': building['longitude'],
    'whole_building': true,
  };

  /// [_destinationLabel] to be read aloud.
  String _spokenLabel(Map<String, dynamic> anchor) =>
      _destinationLabel(anchor).replaceAll(' · ', ', ');

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

  String _destinationLabel(Map<String, dynamic> anchor) {
    final name = anchor['location_description'] as String? ?? '';
    if (anchor['whole_building'] == true) return name;
    final building = _buildingNames[anchor['building_id']];
    final floor = (anchor['floor'] as int?) ?? 0;
    return [
      name,
      // Two "Baño" on different floors have to be told apart.
      if (floor != 0)
        AppLocalizations.of(context)!.commonFloorOption(floor + 1),
      if (building != null && building.isNotEmpty) building,
    ].join(' · ');
  }

  /// The recognizer locale for the app language (es-CO first, like the
  /// voice), or null to let the phone use its default.
  Future<String?> _speechLocale(String language) async {
    final available = {
      for (final l in await _speech.locales())
        l.localeId.replaceAll('_', '-').toLowerCase(): l.localeId,
    };
    for (final candidate in ttsLanguageCandidates(language)) {
      final match = available[candidate.toLowerCase()];
      if (match != null) return match;
    }
    for (final entry in available.entries) {
      if (entry.key.startsWith(language)) return entry.value;
    }
    return null;
  }

  /// Voice first (D1): the app asks and listens by itself, unless the voice is
  /// off or a screen reader is on (it would be heard as the answer). Not
  /// over a dialog, and never again once a destination is chosen.
  bool get _voiceFirst =>
      voiceGuidanceNotifier.value &&
      !MediaQuery.of(context).accessibleNavigation;

  /// How many times in a row nothing usable was heard. After the first try
  /// and [_kVoiceRetries] more, it stops and points to the buttons.
  int _voiceMisses = 0;
  static const _kVoiceRetries = 2;

  /// Right after sign-in: "Where do you want to go?", then listening.
  Future<void> _askForDestination() async {
    if (!mounted || _end != null || !_voiceFirst) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    _voiceMisses = 0;
    await _say(AppLocalizations.of(context)!.homeAskDestination);
    if (!mounted || _end != null || ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    await _startListening(_handleSpoken);
  }

  /// Nothing usable was heard: say why, and try again up to [_kVoiceRetries]
  /// times, then stop with the way to carry on by hand. Never a loop.
  Future<void> _missed(String why) async {
    final l10n = AppLocalizations.of(context)!;
    _voiceMisses++;
    if (_voiceMisses > _kVoiceRetries || !_voiceFirst) {
      _voiceMisses = 0;
      await _say('$why ${l10n.homeVoiceGiveUp}');
      return;
    }
    await _say(why);
    if (mounted && _end == null && ModalRoute.of(context)?.isCurrent == true) {
      await _startListening(_handleSpoken);
    }
  }

  /// The Speak button: listens again, or stops listening. It never restarts
  /// anything else, which is how people got lost (D1).
  Future<void> _listenForDestination() async {
    if (_listening) {
      _voiceMisses = _kVoiceRetries + 1; // stopped on purpose: no retry
      await _speech.stop();
      return;
    }
    _voiceMisses = 0;
    await _startListening(_handleSpoken);
  }

  /// Opens the microphone once, with a felt and heard mark just before (the
  /// recognizer isn't on yet, so it doesn't take them as speech), and calls
  /// [onHeard] once with what was said, '' for nothing. False when there's
  /// no recognizer or microphone.
  Future<bool> _startListening(
    Future<void> Function(String heard) onHeard, {
    Duration listenFor = const Duration(seconds: 10),
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final language = Localizations.localeOf(context).languageCode;
    var answered = false;
    void finish(String heard) {
      if (answered || !mounted) return;
      answered = true;
      setState(() => _listening = false);
      onHeard(heard);
    }

    if (_verifiedAnchors.isEmpty) await _loadAnchors();
    if (_buildingNames.isEmpty) {
      try {
        _buildings = (await _mapApi.get('/buildings') as List)
            .cast<Map<String, dynamic>>();
        _buildingNames = {
          for (final b in _buildings)
            b['id'] as String: b['name'] as String? ?? '',
        };
      } on ApiException {
        // Building names only help tell same-named places apart.
      }
    }
    if (!mounted) return false;
    final available = await _speech.initialize(
      onStatus: (status) {
        if (!mounted) return;
        if (status == 'notListening') setState(() => _listening = false);
        // After the final result, if one came; otherwise what was heard.
        if (status == 'done') finish(_heard);
      },
      onError: (_) => finish(''),
    );
    if (!mounted) return false;
    if (!available) {
      // Said once; the buttons stay. Retrying can't bring a microphone back.
      _voiceMisses = 0;
      await _say(l10n.homeVoiceUnavailable);
      return false;
    }
    await _tts.stop(); // so the recognizer doesn't hear the app itself
    final localeId = await _speechLocale(language);
    if (!mounted) return false;
    setState(() {
      _listening = true;
      _heard = '';
      _voiceStatus = l10n.homeListeningShort;
    });
    // Felt and heard before the microphone opens: once it's on, anything
    // the app plays would be taken as speech.
    HapticFeedback.heavyImpact();
    await SystemSound.play(SystemSoundType.click);
    await _speech.listen(
      onResult: (result) {
        if (!mounted) return;
        setState(() => _heard = result.recognizedWords);
        if (result.finalResult) finish(result.recognizedWords);
      },
      listenOptions: SpeechListenOptions(
        localeId: localeId,
        listenFor: listenFor,
        pauseFor: const Duration(seconds: 3),
        partialResults: true,
        cancelOnError: true,
      ),
    );
    return true;
  }

  Future<void> _handleSpoken(String heard) async {
    final l10n = AppLocalizations.of(context)!;
    // Felt: listening has stopped.
    HapticFeedback.mediumImpact();
    if (heard.trim().isEmpty) {
      if (_voiceMisses > _kVoiceRetries) {
        _voiceMisses = 0; // the Speak button stopped it on purpose
        return;
      }
      await _missed(l10n.homeVoiceNothingHeard);
      return;
    }
    _voiceMisses = 0;
    final candidates = _destinationCandidates;
    // A place called exactly that first: there may be a "Cafetería central"
    // both as a place and as a building.
    final exact = exactPlaces(heard, candidates, buildingNames: _buildingNames);
    if (exact.isNotEmpty) {
      await _chooseFrom(
        nearestFirst([
          for (final place in exact) DestinationMatch(place, 1),
        ], _distanceFromUser).map((m) => m.anchor).toList(),
      );
      return;
    }
    // Then a building: "Edificio C" means its closest entrance. Saying more
    // than the building ("baño edificio C") is a place in it, below.
    final buildings = matchBuildings(heard, _campusBuildings);
    if (buildings.isNotEmpty) {
      final winner = clearWinner(buildings);
      await _chooseFrom(
        winner != null
            ? [_wholeBuilding(winner.anchor)]
            : [for (final match in buildings) _wholeBuilding(match.anchor)],
      );
      return;
    }
    final matches = nearestFirst(
      matchDestinations(heard, candidates, buildingNames: _buildingNames),
      _distanceFromUser,
    );
    if (matches.isEmpty) {
      await _missed(l10n.homeVoiceNoMatch(heard));
      return;
    }
    final winner = clearWinner(matches);
    await _chooseFrom(
      winner != null ? [winner.anchor] : matches.map((m) => m.anchor).toList(),
    );
  }

  /// One option goes straight to "Go to X?", several to a choice of the first
  /// few.
  Future<void> _chooseFrom(List<Map<String, dynamic>> found) async {
    if (found.length == 1) {
      _chooseVoiceDestination(found.single);
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final options = found.take(3).toList();
    _say(l10n.homeVoiceSeveralMatches(options.map(_spokenLabel).join('; ')));
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                l10n.homeVoiceChooseTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final option in options)
              ListTile(
                leading: const Icon(Icons.location_on, color: Colors.blue),
                title: Text(_destinationLabel(option)),
                onTap: () => Navigator.of(context).pop(option),
              ),
          ],
        ),
      ),
    );
    if (picked != null && mounted) _chooseVoiceDestination(picked);
  }

  void _chooseVoiceDestination(Map<String, dynamic> anchor) =>
      _confirmAndStart(anchor);

  /// A destination was chosen (by voice or from the list): "Go to X?" with
  /// one big Start route button, which starts the trip. In the first user
  /// test people expected the route to start once they'd said the place,
  /// and couldn't find the separate Find route button.
  Future<void> _confirmAndStart(Map<String, dynamic> anchor) async {
    setState(() {
      _end = anchor;
      _error = null;
      _voiceStatus = null;
    });
    final l10n = AppLocalizations.of(context)!;
    final title = l10n.homeGoToTitle(_destinationLabel(anchor));
    BuildContext? openDialog;
    if (!MediaQuery.of(context).accessibleNavigation) {
      final voiceFirst = _voiceFirst;
      () async {
        await _say(
          voiceFirst
              ? '${l10n.homeGoToTitle(_spokenLabel(anchor))} ${l10n.homeSayYesToStart}'
              : l10n.homeGoToTitle(_spokenLabel(anchor)),
        );
        // Saying "yes" starts it (D1): the buttons stay for everyone else.
        final dialog = openDialog;
        if (!voiceFirst || dialog == null || !dialog.mounted) return;
        await _startListening(listenFor: const Duration(seconds: 6), (
          heard,
        ) async {
          final answer = spokenAnswer(heard);
          final still = openDialog;
          if (answer == null || still == null || !still.mounted) return;
          Navigator.of(still).pop(answer == SpokenAnswer.start);
        });
      }();
    }
    final start = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Builder(
          builder: (context) {
            openDialog = dialogContext;
            return Text(title);
          },
        ),
        actionsAlignment: MainAxisAlignment.center,
        actionsOverflowDirection: VerticalDirection.up,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.homeChangeDestinationButton),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size(220, 64),
              textStyle: Theme.of(dialogContext).textTheme.titleLarge,
            ),
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.directions_walk),
            label: Text(l10n.homeStartRouteButton),
          ),
        ],
      ),
    );
    openDialog = null;
    await _speech.cancel();
    await _tts.stop();
    if (!mounted) return;
    if (start == true) {
      _findRoute();
    } else if (start == false) {
      // "Change destination": every tester was unsure how to (2026-11-03).
      _pickEnd();
    }
  }

  /// Verified, connected points in active buildings of active universities
  /// - the only ones offered as a start or a destination. An unconnected
  /// start made every route at Icesi fail (2026-11-03).
  Future<List<Map<String, dynamic>>> _fetchVerifiedAnchors() async {
    final results = await Future.wait([
      _mapApi.get('/places'),
      _mapApi.get('/buildings'),
      _mapApi.get('/anchor-points'),
    ]);
    final connected = await fetchConnectedAnchorIds(_mapApi);
    final buildings = (results[1] as List).cast<Map<String, dynamic>>();
    _buildings = buildings;
    _buildingNames = {
      for (final b in buildings) b['id'] as String: b['name'] as String? ?? '',
    };
    final active = activeBuildingIds(
      (results[0] as List).cast<Map<String, dynamic>>(),
      buildings,
    );
    _activeBuildingIds = active;
    return (results[2] as List)
        .cast<Map<String, dynamic>>()
        .where(
          (a) =>
              a['status'] == 'verified' &&
              active.contains(a['building_id']) &&
              (connected?.contains(a['id']) ?? true),
        )
        .toList();
  }

  /// Best-effort early load so the Start row can show a real anchor point
  /// before the user does anything - Find route re-fetches and surfaces
  /// any real failure.
  Future<void> _loadAnchors() async {
    try {
      final verified = await _fetchVerifiedAnchors();
      if (!mounted) return;
      _verifiedAnchors = verified;
      final position = _locationService.lastPosition;
      if (position != null) _recomputeStart(position);
    } on ApiException {
      // Shown later by _findRoute if it's still failing then.
    }
  }

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

  void _recomputeStart(Position position) {
    if (!mounted || _verifiedAnchors.isEmpty || _finding || _locatingStart) {
      return;
    }
    // Keep a camera-checked start until the user has actually moved away.
    final checkedFrom = _startCheckedFrom;
    if (checkedFrom != null &&
        haversineMeters(
              checkedFrom,
              LatLng(position.latitude, position.longitude),
            ) <
            _kStartCheckRadiusMeters) {
      return;
    }
    _startCheckedAt = null;
    _startCheckedFrom = null;
    final nearest = _nearestAnchor(
      _verifiedAnchors,
      LatLng(position.latitude, position.longitude),
    );
    if (nearest?['id'] != _start?['id']) setState(() => _start = nearest);
  }

  Future<void> _pickEnd() async {
    final picked = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => AnchorPointPickerScreen(
          title: AppLocalizations.of(context)!.homeWhereTo,
          excludeAnchorId: _start?['id'] as String?,
        ),
      ),
    );
    if (picked != null && mounted) _confirmAndStart(picked);
  }

  /// Photos taken by the start-point check, and the minimum gap between
  /// them. Each one goes through the same Kalman filter, so later photos
  /// refine earlier ones; one photo alone barely moved the position.
  static const int _kStartCheckPhotos = 6;
  static const Duration _kStartCheckInterval = Duration(milliseconds: 900);

  /// A checked start is kept (not replaced by the raw-GPS nearest point)
  /// until the user moves this far from where it was checked...
  static const double _kStartCheckRadiusMeters = 15;

  /// ...and Find route reuses it for this long instead of checking again.
  static const Duration _kStartCheckFreshFor = Duration(seconds: 60);

  /// Multi-photo position check for the start point. Each photo plus the
  /// current GPS fix goes to backend-positioning's session
  /// `POST /correct_position` under a throwaway key: that endpoint only
  /// uses session_id to key its in-memory filter (no DB lookup), so the
  /// photos accumulate in one filter and the result is the fused position.
  /// The filter expires on its own (the positioning service's session TTL).
  /// Without a camera, or if every photo fails, falls back to raw GPS.
  Future<({LatLng? position, int matched, int taken})>
  _checkStartPosition() async {
    final key =
        'start-check-${DateTime.now().microsecondsSinceEpoch}-'
        '${Random().nextInt(1 << 32)}';
    CameraController? controller;
    LatLng? fused;
    var matched = 0;
    var taken = 0;
    try {
      controller = await initCamera();
      if (controller != null) {
        for (var i = 0; i < _kStartCheckPhotos; i++) {
          if (!mounted) break;
          setState(() => _startCheckProgress = i + 1);
          final started = DateTime.now();
          final position = _locationService.lastPosition;
          if (position != null) {
            try {
              final image = await controller.takePicture();
              final bytes = await image.readAsBytes();
              if (!isFrameBlocked(bytes)) {
                final result =
                    await _positioningApi
                            .postMultipart(
                              '/correct_position',
                              fieldName: 'photo',
                              bytes: bytes,
                              filename: path.basename(image.path),
                              fields: {
                                'session_id': key,
                                'latitude': position.latitude.toString(),
                                'longitude': position.longitude.toString(),
                                'accuracy': position.accuracy.toString(),
                                // No compass here, and the GPS course is
                                // meaningless while turning on the spot, so
                                // no heading: the backend skips that gate.
                                'gps_time': position.timestamp
                                    .toUtc()
                                    .toIso8601String(),
                              },
                            )
                            .timeout(const Duration(seconds: 10))
                        as Map<String, dynamic>;
                fused = LatLng(
                  (result['corrected_lat'] as num).toDouble(),
                  (result['corrected_long'] as num).toDouble(),
                );
                taken++;
                if (result['anchor_match_id'] != null) matched++;
              }
            } catch (_) {
              // One bad photo or request just doesn't count.
            }
          }
          final elapsed = DateTime.now().difference(started);
          if (elapsed < _kStartCheckInterval) {
            await Future<void>.delayed(_kStartCheckInterval - elapsed);
          }
        }
      }
    } finally {
      await controller?.dispose();
    }
    final raw = _locationService.lastPosition;
    return (
      position:
          fused ?? (raw == null ? null : LatLng(raw.latitude, raw.longitude)),
      matched: matched,
      taken: taken,
    );
  }

  /// Runs the start-point check and picks the verified anchor nearest the
  /// result. Shared by Find route and tapping the Start row. Throws
  /// ApiException if the anchors can't be loaded.
  Future<Map<String, dynamic>?> _locateStart() async {
    final l10n = AppLocalizations.of(context)!;
    _verifiedAnchors = await _fetchVerifiedAnchors();
    if (!mounted) return null;
    setState(() {
      _locatingStart = true;
      _startCheckProgress = 0;
    });
    _say(l10n.homeCheckingStartPrompt);
    final check = await _checkStartPosition();
    if (!mounted) return null;
    final position = check.position;
    final start = position == null
        ? null
        : _nearestAnchor(_verifiedAnchors, position);
    setState(() {
      _locatingStart = false;
      _start = start;
      if (start != null) {
        _startCheckedAt = DateTime.now();
        _startCheckedFrom = position;
      }
    });
    if (start != null) {
      final description = (start['location_description'] as String? ?? '')
          .trim();
      _say(
        l10n.homeStartChecked(
          description.isNotEmpty ? description : l10n.homeStartNearestPoint,
          check.matched,
          _kStartCheckPhotos,
        ),
      );
    }
    return start;
  }

  /// Whether the last start check can be reused instead of running again.
  bool get _startCheckIsFresh {
    final checkedAt = _startCheckedAt;
    final from = _startCheckedFrom;
    final position = _locationService.lastPosition;
    if (_start == null || checkedAt == null || from == null) return false;
    if (DateTime.now().difference(checkedAt) > _kStartCheckFreshFor) {
      return false;
    }
    return position == null ||
        haversineMeters(from, LatLng(position.latitude, position.longitude)) <
            _kStartCheckRadiusMeters;
  }

  /// Tapping the Start row: run the check on demand.
  Future<void> _relocateStart() async {
    if (_locatingStart || _finding) return;
    setState(() => _error = null);
    try {
      await _locateStart();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _locatingStart = false;
        _error = AppLocalizations.of(
          context,
        )!.commonErrorLoadDataFailed(friendlyApiErrorMessage(context, e));
      });
    }
  }

  /// A trip left open by closing the app mid-route: offer to continue it
  /// or finish it, instead of it staying "active" forever.
  // v2: the 3-page tutorial, so the Icesi testers see it too.
  static const _kTutorialSeenKey = 'tutorial_seen_v2';

  /// First launch: the spoken tutorial once, on its own.
  Future<void> _showTutorialOnFirstRun() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_kTutorialSeenKey) ?? false) return;
      await prefs.setBool(_kTutorialSeenKey, true);
    } catch (_) {
      return; // No storage: don't nag on every launch.
    }
    if (mounted) await _showTutorial();
  }

  /// "How does it work?": what the app does and how to use it, a page at a
  /// time, each shown and spoken (TalkBack reads the dialog itself). The
  /// first user test had to explain every button by hand, and one long
  /// paragraph was too much to take in at Icesi (2026-11-03).
  Future<void> _showTutorial() async {
    final l10n = AppLocalizations.of(context)!;
    final pages = [
      l10n.homeTutorialPage1,
      l10n.homeTutorialPage2,
      l10n.homeTutorialPage3,
    ];
    for (var i = 0; i < pages.length && mounted; i++) {
      _say(pages[i], show: false);
      final next = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            '${l10n.homeTutorialTitle} '
            '(${l10n.homeTutorialProgress(i + 1, pages.length)})',
          ),
          content: SingleChildScrollView(
            child: Text(pages[i], style: const TextStyle(fontSize: 18)),
          ),
          actions: [
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(160, 56)),
              autofocus: true,
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(
                i == pages.length - 1
                    ? l10n.homeTutorialDone
                    : l10n.homeTutorialNext,
              ),
            ),
          ],
        ),
      );
      if (next != true) break;
    }
    await _tts.stop();
  }

  /// True when the user went back into an unfinished trip.
  Future<bool> _checkUnfinishedTrip() async {
    List<Map<String, dynamic>> sessions;
    try {
      sessions = (await _navigationApi.get('/sessions/active') as List)
          .cast<Map<String, dynamic>>();
    } on ApiException {
      return false; // Best effort - never blocks the home screen.
    }
    if (sessions.isEmpty || !mounted) return false;
    final latest = sessions.first;
    // Only the newest is offered; any older leftovers are just closed.
    for (final old in sessions.skip(1)) {
      _finishSession(old);
    }

    Map<String, dynamic>? route;
    final routeId = latest['route_id'] as String?;
    if (routeId != null) {
      try {
        route = await _routeApi.get('/routes/$routeId') as Map<String, dynamic>;
      } on ApiException {
        route = null;
      }
    }
    if (route == null) {
      // Nothing to resume onto.
      await _finishSession(latest);
      return false;
    }
    if (_verifiedAnchors.isEmpty) await _loadAnchors();
    if (!mounted) return false;

    final l10n = AppLocalizations.of(context)!;
    final end = _verifiedAnchors.where(
      (a) => a['id'] == route!['end_anchor_id'],
    );
    final destination =
        (end.isEmpty ? null : end.first['location_description'] as String?) ??
        l10n.navYourDestination;
    final startedAt = DateTime.tryParse(latest['start_time'] as String? ?? '');
    final time = startedAt == null
        ? '?'
        : TimeOfDay.fromDateTime(startedAt.toLocal()).format(context);

    final resume = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(l10n.homeUnfinishedTripTitle),
        content: Text(l10n.homeUnfinishedTripContent(destination, time)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.homeUnfinishedTripFinish),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.homeUnfinishedTripResume),
          ),
        ],
      ),
    );
    if (!mounted) return false;
    if (resume == true) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => NavigationScreen(
            route: route!,
            resumeSessionId: latest['id'] as String,
            adminPreview: widget.adminPreview,
          ),
        ),
      );
      return true;
    }
    await _finishSession(latest);
    return false;
  }

  /// Closes a session the user didn't finish as `abandoned` (not
  /// `completed` - they never arrived), so admins can tell them apart.
  Future<void> _finishSession(Map<String, dynamic> session) async {
    final position = _locationService.lastPosition;
    try {
      await _navigationApi.patch('/sessions/${session['id']}', {
        'status': 'abandoned',
        'end_time': DateTime.now().toUtc().toIso8601String(),
        if (position != null)
          'end_position': {
            'latitude': position.latitude,
            'longitude': position.longitude,
          },
      });
    } on ApiException {
      // Best effort; it will be offered again next launch.
    }
  }

  Map<String, dynamic>? _nearestAnchor(
    List<Map<String, dynamic>> anchors,
    LatLng from,
  ) {
    Map<String, dynamic>? nearest;
    double? nearestDistance;
    for (final anchor in anchors) {
      final lat = (anchor['latitude'] as num?)?.toDouble();
      final lng = (anchor['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      final distance = haversineMeters(from, LatLng(lat, lng));
      if (nearestDistance == null || distance < nearestDistance) {
        nearestDistance = distance;
        nearest = anchor;
      }
    }
    return nearest;
  }

  /// Which of [floors] the user is on: their earlier answer until they've
  /// moved [_kStartCheckRadiusMeters], else asked, spoken, with one big button
  /// per floor. Null if they back out.
  Future<int?> _startFloor(List<int> floors, LatLng here) async {
    final answered = _answeredFloor;
    final from = _answeredFloorFrom;
    if (answered != null &&
        from != null &&
        floors.contains(answered) &&
        haversineMeters(from, here) < _kStartCheckRadiusMeters) {
      return answered;
    }
    final l10n = AppLocalizations.of(context)!;
    _askingFloor = true;
    final labels = [for (final f in floors) l10n.commonFloorOption(f + 1)];
    _say('${l10n.homeWhichFloorTitle} ${labels.join(', ')}.', show: false);
    final floor = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.homeWhichFloorTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < floors.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(64),
                    textStyle: Theme.of(dialogContext).textTheme.titleLarge,
                  ),
                  onPressed: () => Navigator.of(dialogContext).pop(floors[i]),
                  child: Text(labels[i]),
                ),
              ),
          ],
        ),
      ),
    );
    _askingFloor = false;
    await _tts.stop();
    if (floor != null) {
      _answeredFloor = floor;
      _answeredFloorFrom = here;
    }
    return floor;
  }

  /// backend-route-management's 404 detail says which end isn't connected.
  String _noPathMessage(AppLocalizations l10n, String? detail) {
    if (detail == null) return l10n.homeErrorNoPath;
    if (detail.startsWith('Your starting point')) {
      return l10n.homeErrorNoPathStart;
    }
    if (detail.startsWith("The destination isn't")) {
      return l10n.homeErrorNoPathDestination;
    }
    return l10n.homeErrorNoPath;
  }

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
      if (mounted && _error == null) setState(() => _voiceStatus = null);
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
      _say(_error!, show: false);
      return;
    }

    try {
      // Users: the start comes straight from GPS - the camera check
      // ("photo 0 of 6, turn around") confused everyone in the first user
      // test, and navigation's own correction takes over from the first
      // ticks. Admins testing keep it (tapping Start, or Find route).
      Map<String, dynamic>? start;
      final here = LatLng(position.latitude, position.longitude);
      if (widget.adminPreview) {
        start = _startCheckIsFresh ? _start : await _locateStart();
      } else {
        _verifiedAnchors = await _fetchVerifiedAnchors();
        start = _nearestAnchor(_verifiedAnchors, here);
        if (mounted) setState(() => _start = start);
      }
      if (!mounted) return;
      // GPS can't tell floors apart: the nearest point may be overhead.
      final floors = floorsNear(_verifiedAnchors, here);
      if (start != null && floors.length > 1) {
        final floor = await _startFloor(floors, here);
        if (!mounted) return;
        if (floor == null) {
          setState(() {
            _finding = false;
            _voiceStatus = null;
          });
          return;
        }
        start = _nearestAnchor(
          _verifiedAnchors
              .where((a) => (a['floor'] as int? ?? 0) == floor)
              .toList(),
          here,
        );
        setState(() => _start = start);
      }
      if (start == null) {
        setState(() {
          _error = AppLocalizations.of(context)!.homeErrorNoVerifiedAnchors;
          _finding = false;
        });
        return;
      }
      if (start['id'] == end['id'] ||
          (end['whole_building'] == true &&
              start['building_id'] == end['building_id'])) {
        setState(() {
          _error = AppLocalizations.of(context)!.homeErrorAlreadyAtDestination(
            end['location_description'] as String? ?? end['id'] as String,
          );
          _finding = false;
        });
        return;
      }

      // Same pair, same answer: safe to send again after a dropped
      // connection.
      final route = await _routeApi.post('/routes/find_or_create', {
        'start_anchor_id': start['id'],
        if (end['whole_building'] == true)
          'end_building_id': end['building_id']
        else
          'end_anchor_id': end['id'],
      }, retry: true);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => NavigationScreen(
            route: route as Map<String, dynamic>,
            destinationName: _spokenLabel(end),
            adminPreview: widget.adminPreview,
          ),
        ),
      );
      setState(() => _finding = false);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _locatingStart = false;
        _error = e.statusCode == 404
            ? _noPathMessage(AppLocalizations.of(context)!, e.detail)
            : AppLocalizations.of(context)!.homeErrorFailedToFindRoute(
                friendlyApiErrorMessage(context, e),
              );
        _finding = false;
        _voiceStatus = null;
      });
      _say(_error!, show: false);
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

  Widget _body(AppLocalizations l10n) {
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
        ListTile(
          leading: const Icon(Icons.radio_button_checked, color: Colors.blue),
          title: Text(l10n.homeStartLabel),
          subtitle: Semantics(
            liveRegion: true,
            child: Text(
              _locatingStart
                  ? (_startCheckProgress > 0
                        ? l10n.homeCheckingStartProgress(
                            _startCheckProgress,
                            _kStartCheckPhotos,
                          )
                        : l10n.homeLocatingStart)
                  : _start != null
                  ? _startLabel(l10n, _start!)
                  : l10n.homeStartSubtitle,
            ),
          ),
          trailing: _locatingStart
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
          onTap: !widget.adminPreview || _locatingStart || _finding
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
        if (_listening && _heard.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '"$_heard"',
              style: const TextStyle(fontStyle: FontStyle.italic),
            ),
          ),
        if (!_listening && _voiceStatus != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Semantics(liveRegion: true, child: Text(_voiceStatus!)),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Semantics(
              liveRegion: true,
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          ),
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
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.help_outline),
          title: Text(l10n.homeTutorialButton),
          onTap: _showTutorial,
        ),
        ListTile(
          leading: const Icon(Icons.settings_outlined),
          title: Text(l10n.homeSettingsTooltip),
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.logout),
          title: Text(l10n.commonLogOut),
          onTap: () => Supabase.instance.client.auth.signOut(),
        ),
      ],
    );
  }
}
