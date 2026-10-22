import 'dart:async';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as path;
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

  @override
  void initState() {
    super.initState();
    _positionSub = _locationService.positionStream.listen(_recomputeStart);
    _loadAnchors();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkUnfinishedTrip());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final language = Localizations.localeOf(context).languageCode;
    if (language != _ttsLanguage) {
      _ttsLanguage = language;
      _ttsReady = configureTts(_tts, language);
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _speech.cancel();
    _tts.stop();
    super.dispose();
  }

  /// Shows [text] as the voice-search status (a live region) and, unless a
  /// screen reader is already reading that live region aloud, speaks it.
  Future<void> _say(String text) async {
    setState(() => _voiceStatus = text);
    if (!voiceGuidanceNotifier.value ||
        MediaQuery.of(context).accessibleNavigation) {
      return;
    }
    await _ttsReady;
    await _tts.stop();
    await _tts.speak(text);
  }

  List<Map<String, dynamic>> get _destinationCandidates => _verifiedAnchors
      .where((a) => isDestinationAnchor(a) && a['id'] != _start?['id'])
      .toList();

  String _destinationLabel(Map<String, dynamic> anchor) {
    final name = anchor['location_description'] as String? ?? '';
    final building = _buildingNames[anchor['building_id']];
    return building == null || building.isEmpty ? name : '$name · $building';
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

  Future<void> _listenForDestination() async {
    final l10n = AppLocalizations.of(context)!;
    final language = Localizations.localeOf(context).languageCode;
    if (_listening) {
      await _speech.stop();
      return;
    }
    if (_verifiedAnchors.isEmpty) await _loadAnchors();
    if (_buildingNames.isEmpty) {
      try {
        final buildings = await _mapApi.get('/buildings') as List;
        _buildingNames = {
          for (final b in buildings.cast<Map<String, dynamic>>())
            b['id'] as String: b['name'] as String? ?? '',
        };
      } on ApiException {
        // Building names only help tell same-named places apart.
      }
    }
    if (!mounted) return;
    final available = await _speech.initialize(
      onStatus: (status) {
        if ((status == 'done' || status == 'notListening') && mounted) {
          setState(() => _listening = false);
        }
      },
      onError: (_) {
        if (!mounted) return;
        setState(() => _listening = false);
        _say(l10n.homeVoiceNothingHeard);
      },
    );
    if (!mounted) return;
    if (!available) {
      await _say(l10n.homeVoiceUnavailable);
      return;
    }
    await _tts.stop(); // so the recognizer doesn't hear the app itself
    final localeId = await _speechLocale(language);
    if (!mounted) return;
    setState(() {
      _listening = true;
      _heard = '';
      _voiceStatus = null;
    });
    await _speech.listen(
      onResult: (result) {
        if (!mounted) return;
        setState(() => _heard = result.recognizedWords);
        if (result.finalResult) _handleSpoken(result.recognizedWords);
      },
      listenOptions: SpeechListenOptions(
        localeId: localeId,
        listenFor: const Duration(seconds: 10),
        pauseFor: const Duration(seconds: 3),
        partialResults: true,
        cancelOnError: true,
      ),
    );
  }

  Future<void> _handleSpoken(String heard) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _listening = false);
    if (heard.trim().isEmpty) {
      await _say(l10n.homeVoiceNothingHeard);
      return;
    }
    final matches = matchDestinations(
      heard,
      _destinationCandidates,
      buildingNames: _buildingNames,
    );
    final winner = clearWinner(matches);
    if (winner != null) {
      _chooseVoiceDestination(winner.anchor);
      return;
    }
    if (matches.isEmpty) {
      await _say(l10n.homeVoiceNoMatch(heard));
      return;
    }
    final options = matches.take(3).map((m) => m.anchor).toList();
    _say(
      l10n.homeVoiceSeveralMatches(options.map(_destinationLabel).join(', ')),
    );
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

  void _chooseVoiceDestination(Map<String, dynamic> anchor) {
    setState(() {
      _end = anchor;
      _error = null;
    });
    _say(
      AppLocalizations.of(
        context,
      )!.homeVoiceDestinationSet(_destinationLabel(anchor)),
    );
  }

  /// Verified points in active buildings of active universities - the only
  /// ones offered as a start or a destination.
  Future<List<Map<String, dynamic>>> _fetchVerifiedAnchors() async {
    final results = await Future.wait([
      _mapApi.get('/places'),
      _mapApi.get('/buildings'),
      _mapApi.get('/anchor-points'),
    ]);
    final buildings = (results[1] as List).cast<Map<String, dynamic>>();
    _buildingNames = {
      for (final b in buildings) b['id'] as String: b['name'] as String? ?? '',
    };
    final active = activeBuildingIds(
      (results[0] as List).cast<Map<String, dynamic>>(),
      buildings,
    );
    return (results[2] as List)
        .cast<Map<String, dynamic>>()
        .where(
          (a) => a['status'] == 'verified' && active.contains(a['building_id']),
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
      return l10n.homeStartNearestSubtitle(description);
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
    if (picked != null) setState(() => _end = picked);
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
                                'heading': position.heading.toString(),
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
  Future<void> _checkUnfinishedTrip() async {
    List<Map<String, dynamic>> sessions;
    try {
      sessions = (await _navigationApi.get('/sessions/active') as List)
          .cast<Map<String, dynamic>>();
    } on ApiException {
      return; // Best effort - never blocks the home screen.
    }
    if (sessions.isEmpty || !mounted) return;
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
      return;
    }
    if (_verifiedAnchors.isEmpty) await _loadAnchors();
    if (!mounted) return;

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
    if (!mounted) return;
    if (resume == true) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => NavigationScreen(
            route: route!,
            resumeSessionId: latest['id'] as String,
          ),
        ),
      );
    } else {
      await _finishSession(latest);
    }
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

  Future<void> _findRoute() async {
    final end = _end;
    if (end == null) return;
    setState(() {
      _finding = true;
      _error = null;
    });

    final position = _locationService.lastPosition;
    if (position == null) {
      setState(() {
        _error = AppLocalizations.of(context)!.homeErrorLocationUnavailable;
        _finding = false;
      });
      return;
    }

    try {
      // A start checked moments ago (tapping Start) isn't checked again.
      final start = _startCheckIsFresh ? _start : await _locateStart();
      if (!mounted) return;
      if (start == null) {
        setState(() {
          _error = AppLocalizations.of(context)!.homeErrorNoVerifiedAnchors;
          _finding = false;
        });
        return;
      }
      if (start['id'] == end['id']) {
        setState(() {
          _error = AppLocalizations.of(context)!.homeErrorAlreadyAtDestination(
            end['location_description'] as String? ?? end['id'] as String,
          );
          _finding = false;
        });
        return;
      }

      final route = await _routeApi.post('/routes/find_or_create', {
        'start_anchor_id': start['id'],
        'end_anchor_id': end['id'],
      });
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              NavigationScreen(route: route as Map<String, dynamic>),
        ),
      );
      setState(() => _finding = false);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _locatingStart = false;
        _error = e.statusCode == 404
            ? AppLocalizations.of(context)!.homeErrorNoPath
            : AppLocalizations.of(context)!.homeErrorFailedToFindRoute(
                friendlyApiErrorMessage(context, e),
              );
        _finding = false;
      });
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
      appBar: AppBar(
        title: Text(l10n.appTitle),
        backgroundColor: Colors.blue,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: l10n.homeSettingsTooltip,
            onPressed: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: l10n.commonLogOut,
            onPressed: () => Supabase.instance.client.auth.signOut(),
          ),
        ],
      ),
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
              : Icon(
                  Icons.my_location,
                  semanticLabel: l10n.homeCheckStartTooltip,
                ),
          onTap: (_locatingStart || _finding) ? null : _relocateStart,
        ),
        const Divider(height: 1),
        ListTile(
          leading: Icon(
            _end == null ? Icons.radio_button_unchecked : Icons.location_on,
            color: _end == null ? Colors.grey : Colors.blue,
          ),
          title: Text(l10n.homeWhereTo),
          subtitle: Text(
            _end == null
                ? l10n.homeTapToChooseDestination
                : (_end!['location_description'] as String? ??
                      _end!['id'] as String),
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
          child: ElevatedButton(
            onPressed: (_end != null && !_finding) ? _findRoute : null,
            child: _finding
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.homeFindRouteButton),
          ),
        ),
      ],
    );
  }
}
