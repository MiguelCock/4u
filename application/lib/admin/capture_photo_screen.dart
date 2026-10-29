import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/anchor_indexing.dart';
import '../services/api_error_messages.dart';

class _PhotoEntry {
  final String? id;
  final String? imageUrl;

  /// The image itself while it's new (camera or file), shown until the
  /// uploaded copy takes over. Bytes, not a file: the web app has no files.
  final Uint8List? localBytes;
  final double? heading;
  final bool uploading;

  /// Tells an upload's own placeholder apart from the others.
  final int? uploadKey;

  const _PhotoEntry({
    this.id,
    this.imageUrl,
    this.localBytes,
    this.heading,
    this.uploading = false,
    this.uploadKey,
  });
}

/// Compass directions an admin can give a photo picked from a file in the
/// web app, which has no compass. Null is "unknown": such a photo is never
/// refused for facing the wrong way.
const _kDirections = <(String, double?)>[
  ('N', 0),
  ('NE', 45),
  ('E', 90),
  ('SE', 135),
  ('S', 180),
  ('SW', 225),
  ('W', 270),
  ('NW', 315),
  ('?', null),
];

/// Multi-photo capture loop for a single `anchor_points` row - one physical
/// point typically ends up with ~4-8 photos facing different directions, so
/// this screen is reached both right after creating a point (`CaptureScreen`)
/// and later via `AdminHomeScreen`'s "Add photo" action on an existing one.
class CapturePhotoScreen extends StatefulWidget {
  final String anchorPointId;
  final String anchorPointDescription;

  const CapturePhotoScreen({
    super.key,
    required this.anchorPointId,
    required this.anchorPointDescription,
  });

  @override
  State<CapturePhotoScreen> createState() => _CapturePhotoScreenState();
}

class _CapturePhotoScreenState extends State<CapturePhotoScreen> {
  final _mapApi = MapManagementApi();
  final _aiTrainingApi = AiTrainingApi();

  CameraController? _controller;
  StreamSubscription<CompassEvent>? _compassSubscription;
  double? _liveHeading;

  /// Web: the direction given to the next photos picked from files.
  double? _webHeading;
  int _nextUploadKey = 0;
  final List<_PhotoEntry> _photos = [];
  Map<String, dynamic>? _anchorPoint;
  bool _loadingExisting = true;
  bool _capturing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAnchorPoint();
    _loadExistingPhotos();
    // The web app uploads photos from files instead (_pickFiles).
    if (kIsWeb) return;
    _initCamera();
    _compassSubscription = FlutterCompass.events?.listen((event) {
      if (mounted) {
        // `heading` is what the Android plugin actually computes from the
        // device's sensors - `headingForCameraMode` is a real iOS feature
        // but the Android implementation never populates it (stays 0.0,
        // not null, so `??` never falls through) and this app is
        // Android-only today (no ios/ directory in the repo).
        setState(
          () => _liveHeading = event.heading ?? event.headingForCameraMode,
        );
      }
    });
  }

  Future<void> _initCamera() async {
    if (await Permission.camera.request() != PermissionStatus.granted) return;
    try {
      final cameras = await availableCameras();
      _controller = CameraController(
        cameras.first,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await _controller!.initialize();
      if (mounted) setState(() {});
    } catch (_) {
      // Camera unavailable (e.g. emulator/CI) - the rest of the form still works.
    }
  }

  Future<void> _loadAnchorPoint() async {
    try {
      final result = await _mapApi.get(
        '/anchor-points/${widget.anchorPointId}',
      );
      if (!mounted) return;
      if (result is Map) {
        setState(() => _anchorPoint = result.cast<String, dynamic>());
      }
    } on ApiException {
      // Only needed to decide whether to auto-index new photos below - not
      // required for the rest of this screen to work.
    }
  }

  Future<void> _loadExistingPhotos() async {
    try {
      final result = await _mapApi.get(
        '/anchor-points/${widget.anchorPointId}/photos',
      );
      if (!mounted) return;
      if (result is List) {
        setState(() {
          _photos.addAll(
            result.cast<Map<String, dynamic>>().map(
              (p) => _PhotoEntry(
                id: p['id'] as String,
                imageUrl: p['image_url'] as String?,
                heading: (p['heading'] as num?)?.toDouble(),
              ),
            ),
          );
        });
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(
        () => _error = AppLocalizations.of(context)!
            .capturePhotoErrorLoadExistingFailed(
              friendlyApiErrorMessage(context, e),
            ),
      );
    } finally {
      if (mounted) setState(() => _loadingExisting = false);
    }
  }

  Future<void> _takePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    setState(() => _capturing = true);
    try {
      final heading = _liveHeading;
      final image = await _controller!.takePicture();
      await _upload(await image.readAsBytes(), heading);
    } catch (e) {
      _showSaveError(e);
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  /// Web: one or more photos picked from files, all with [_webHeading].
  Future<void> _pickFiles() async {
    final files = await ImagePicker().pickMultiImage(imageQuality: 90);
    if (files.isEmpty || !mounted) return;
    setState(() => _capturing = true);
    try {
      for (final file in files) {
        await _upload(await file.readAsBytes(), _webHeading);
      }
    } catch (e) {
      _showSaveError(e);
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  void _showSaveError(Object e) {
    if (!mounted) return;
    setState(
      () => _error = AppLocalizations.of(
        context,
      )!.capturePhotoErrorSaveFailed(friendlyApiErrorMessage(context, e)),
    );
  }

  /// Uploads one photo, records it on this point, and indexes it if the
  /// point is verified. Throws on failure, after removing its placeholder
  /// and any file uploaded but never recorded.
  Future<void> _upload(Uint8List bytes, double? heading) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      setState(() => _error = AppLocalizations.of(context)!.commonNotSignedIn);
      return;
    }
    final key = _nextUploadKey++;
    setState(() {
      _error = null;
      _photos.add(
        _PhotoEntry(
          localBytes: bytes,
          heading: heading,
          uploading: true,
          uploadKey: key,
        ),
      );
    });
    // Set once the file is in Storage; cleared once its photo row exists.
    String? unrecordedUpload;
    try {
      final uploadResult = await _mapApi.postMultipart(
        '/anchor-points/upload-image',
        fieldName: 'file',
        bytes: bytes,
        // Random suffix: two admins in the same millisecond used to collide
        // on the file name and fail the upload.
        filename:
            '${DateTime.now().microsecondsSinceEpoch}-'
            '${Random().nextInt(1 << 32).toRadixString(16)}.jpg',
      );
      final imageUrl = (uploadResult as Map<String, dynamic>)['url'] as String;
      unrecordedUpload = imageUrl;

      final photoResult = await _mapApi.post(
        '/anchor-points/${widget.anchorPointId}/photos',
        {'image_url': imageUrl, 'heading': heading, 'captured_by': userId},
      );
      final id = (photoResult as List).first['id'] as String;
      unrecordedUpload = null;

      if (!mounted) return;
      setState(() {
        final index = _photos.indexWhere((p) => p.uploadKey == key);
        if (index != -1) {
          _photos[index] = _PhotoEntry(
            id: id,
            imageUrl: imageUrl,
            localBytes: bytes,
            heading: heading,
          );
        }
      });

      // Only confirmed-good anchor points are searchable - if this point is
      // already verified, keep it that way by indexing the new photo too,
      // instead of only re-indexing on the next edit-screen save.
      // Its details may have failed to load at first; without them a new
      // photo on a verified point was silently never indexed.
      if (_anchorPoint == null) await _loadAnchorPoint();
      if (_anchorPoint?['status'] == 'verified') {
        try {
          await _aiTrainingApi.post(
            '/index_anchor',
            indexAnchorPayload(
              anchorPointId: widget.anchorPointId,
              latitude: _anchorPoint!['latitude'] as num,
              longitude: _anchorPoint!['longitude'] as num,
              buildingId: _anchorPoint!['building_id'] as String?,
              photos: [
                {'id': id, 'image_url': imageUrl, 'heading': heading},
              ],
            ),
          );
        } on ApiException catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  AppLocalizations.of(
                    context,
                  )!.capturePhotoSnackbarIndexingFailed(
                    friendlyApiErrorMessage(context, e),
                  ),
                ),
              ),
            );
          }
        }
      }
    } catch (_) {
      final orphan = unrecordedUpload;
      if (orphan != null) {
        // Uploaded but never recorded: don't leave it in Storage forever.
        _mapApi
            .delete(
              '/anchor-points/upload-image?url=${Uri.encodeQueryComponent(orphan)}',
            )
            .then((_) {}, onError: (_) {});
      }
      if (mounted) {
        setState(() => _photos.removeWhere((p) => p.uploadKey == key));
      }
      rethrow;
    }
  }

  Future<void> _deletePhoto(_PhotoEntry photo) async {
    if (photo.id == null) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.capturePhotoDeleteDialogTitle),
        content: Text(l10n.commonCannotBeUndone),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _mapApi.delete('/anchor-point-photos/${photo.id}');
      if (mounted) setState(() => _photos.remove(photo));
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.commonErrorDeleteFailed(friendlyApiErrorMessage(context, e)),
            ),
          ),
        );
      }
      return;
    }

    // Best-effort - cheap no-op if this photo was never indexed (e.g. the
    // anchor point isn't verified), doesn't affect the delete above either way.
    try {
      await _aiTrainingApi.delete('/index_photo/${photo.id}');
    } on ApiException {
      // Nothing to show the admin - the photo is already gone either way.
    }

    // A verified point with no photos can never be recognised: put it back
    // to pending so it isn't offered as if it worked.
    final noPhotosLeft = !_photos.any((p) => p.id != null);
    if (noPhotosLeft && _anchorPoint?['status'] == 'verified') {
      try {
        await _mapApi.patch('/anchor-points/${widget.anchorPointId}', {
          'status': 'pending',
        });
        if (!mounted) return;
        setState(() => _anchorPoint = {..._anchorPoint!, 'status': 'pending'});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.capturePhotoSnackbarBackToPending)),
        );
      } on ApiException {
        // The photo is gone; the status can still be fixed in the edit screen.
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _compassSubscription?.cancel();
    super.dispose();
  }

  /// Web: which way the photos face, and a button to pick them from files.
  Widget _webUploadBar(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(l10n.capturePhotoWebDirectionLabel),
          SegmentedButton<double?>(
            segments: [
              for (final (label, degrees) in _kDirections)
                ButtonSegment(
                  value: degrees,
                  label: Text(
                    degrees == null
                        ? l10n.capturePhotoWebDirectionUnknown
                        : label,
                  ),
                ),
            ],
            selected: {_webHeading},
            showSelectedIcon: false,
            onSelectionChanged: (value) =>
                setState(() => _webHeading = value.first),
          ),
          FilledButton.icon(
            onPressed: _capturing ? null : _pickFiles,
            icon: _capturing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.upload_file),
            label: Text(
              _capturing
                  ? l10n.capturePhotoSavingLabel
                  : l10n.capturePhotoWebUploadButton(_photos.length),
            ),
          ),
          Text(
            l10n.capturePhotoWebHint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.capturePhotoTitle(widget.anchorPointDescription)),
        actions: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.check),
            tooltip: l10n.capturePhotoDoneTooltip,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (kIsWeb)
              _webUploadBar(l10n)
            else ...[
              Stack(
                children: [
                  SizedBox(
                    height: 300,
                    width: double.infinity,
                    child:
                        (_controller != null &&
                            _controller!.value.isInitialized)
                        ? CameraPreview(_controller!)
                        : const Center(child: CircularProgressIndicator()),
                  ),
                  if (_liveHeading != null)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          l10n.capturePhotoFacingLabel(_liveHeading!.round()),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: ElevatedButton.icon(
                  onPressed: _capturing ? null : _takePhoto,
                  icon: _capturing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.camera_alt),
                  label: Text(
                    _capturing
                        ? l10n.capturePhotoSavingLabel
                        : l10n.capturePhotoTakeButton(_photos.length),
                  ),
                ),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12.0),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            const Divider(height: 1),
            Expanded(
              child: _loadingExisting
                  ? const Center(child: CircularProgressIndicator())
                  : _photos.isEmpty
                  ? Center(child: Text(l10n.capturePhotoNoPhotosYet))
                  : GridView.builder(
                      padding: const EdgeInsets.all(8),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 6,
                            mainAxisSpacing: 6,
                          ),
                      itemCount: _photos.length,
                      itemBuilder: (context, index) {
                        final photo = _photos[index];
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            photo.localBytes != null
                                ? Image.memory(
                                    photo.localBytes!,
                                    fit: BoxFit.cover,
                                  )
                                : Image.network(
                                    photo.imageUrl!,
                                    fit: BoxFit.cover,
                                  ),
                            if (photo.uploading)
                              const ColoredBox(
                                color: Colors.black45,
                                child: Center(
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation(
                                      Colors.white,
                                    ),
                                  ),
                                ),
                              )
                            else
                              Positioned(
                                top: 0,
                                right: 0,
                                child: IconButton(
                                  icon: const Icon(
                                    Icons.delete,
                                    color: Colors.white,
                                  ),
                                  onPressed: () => _deletePhoto(photo),
                                ),
                              ),
                            if (photo.heading != null)
                              Positioned(
                                bottom: 0,
                                left: 0,
                                child: Container(
                                  color: Colors.black54,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                  ),
                                  child: Text(
                                    '${photo.heading!.round()}°',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
