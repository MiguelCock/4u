import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'l10n/app_localizations.dart';
import 'services/location_service.dart';

class LocationInfo extends StatefulWidget {
  const LocationInfo({super.key});

  @override
  State<LocationInfo> createState() => _LocationInfoState();
}

class _LocationInfoState extends State<LocationInfo> {
  final _service = LocationService();
  StreamSubscription<Position>? _subscription;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _subscription = _service.positionStream.listen(
      (_) => mounted ? setState(() {}) : null,
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _retry() async {
    setState(() => _retrying = true);
    await _service.initialize();
    if (mounted) setState(() => _retrying = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final position = _service.lastPosition;
    final error = _service.lastError;

    if (position == null && error == null) {
      return const Padding(
        padding: EdgeInsets.all(16.0),
        child: CircularProgressIndicator(),
      );
    }

    if (position == null && error != null) {
      final (message, actionLabel, action) = switch (error) {
        LocationError.serviceDisabled => (
          l10n.locationServiceDisabledError,
          l10n.locationOpenLocationSettings,
          Geolocator.openLocationSettings,
        ),
        LocationError.permissionDeniedForever => (
          l10n.locationPermissionDeniedForeverError,
          l10n.commonOpenSettings,
          Geolocator.openAppSettings,
        ),
        LocationError.permissionDenied => (
          l10n.locationPermissionDeniedError,
          l10n.commonTryAgain,
          _retry,
        ),
      };
      return Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(Icons.location_off, color: Colors.red),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    message,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _retrying ? null : action,
              child: _retrying
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(actionLabel),
            ),
          ],
        ),
      );
    }

    // This container's background is a fixed light grey regardless of
    // theme - in dark mode (or the high-contrast dark scheme) the ambient
    // text color defaults to near-white, which is invisible against it.
    // An explicit dark color here keeps this always readable no matter
    // which theme is active.
    const textStyle = TextStyle(color: Colors.black87);
    return Container(
      padding: const EdgeInsets.all(16.0),
      color: Colors.grey[200],
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          const Icon(Icons.location_on, color: Colors.blue),
          Text(
            l10n.locationLat(position!.latitude.toStringAsFixed(6)),
            style: textStyle,
          ),
          Text(
            l10n.locationLng(position.longitude.toStringAsFixed(6)),
            style: textStyle,
          ),
          Text(
            l10n.locationAccuracy(position.accuracy.toStringAsFixed(2)),
            style: textStyle,
          ),
        ],
      ),
    );
  }
}
