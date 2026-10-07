import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/app_preferences.dart';

/// #85 + #107: lets the signed-in user configure verbosity, high contrast,
/// and language, backed by the already-existing `profiles.preferences`
/// JSONB column and `PATCH /profiles/{id}`. Deliberately does NOT include
/// a voice/text "feedback_type" toggle - see application/CLAUDE.md for why
/// (no TTS exists to back it; real screen-reader support is #82, not a
/// per-user app preference).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// The only selectable font-scale values - `_nearestFontScale` snaps any
/// other value (e.g. an ambient OS text-scale signal like 1.1) to the
/// closest one of these, since `SegmentedButton` only highlights a segment
/// whose value matches `selected` exactly.
const List<double> _kFontScales = [0.85, 1.0, 1.15, 1.3];

double _nearestFontScale(double value) {
  return _kFontScales.reduce(
    (closest, candidate) => (candidate - value).abs() < (closest - value).abs()
        ? candidate
        : closest,
  );
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _userApi = UserManagementApi();
  bool _loading = true;
  bool _saving = false;
  String? _error;

  String _verbosity = 'medium';
  bool _highContrast = false;
  String? _language; // null = auto (device)
  double _fontScale = 1.0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      setState(() {
        _error = AppLocalizations.of(context)!.commonNotSignedIn;
        _loading = false;
      });
      return;
    }
    try {
      final profile =
          await _userApi.get('/profiles/$userId') as Map<String, dynamic>;
      final prefs = profile['preferences'] as Map<String, dynamic>? ?? {};
      setState(() {
        _verbosity = prefs['verbosity'] as String? ?? 'medium';
        _highContrast =
            prefs['high_contrast'] as bool? ??
            MediaQuery.of(context).highContrast;
        _language = prefs['language'] as String?;
        _fontScale = _nearestFontScale(
          (prefs['font_scale'] as num?)?.toDouble() ??
              MediaQuery.of(context).textScaler.scale(1.0),
        );
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = AppLocalizations.of(
          context,
        )!.settingsErrorLoadFailed(e.toString());
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _userApi.patch('/profiles/$userId', {
        'preferences': {
          'verbosity': _verbosity,
          'high_contrast': _highContrast,
          if (_language != null) 'language': _language,
          'font_scale': _fontScale,
        },
      });
      applyPreferences(
        {
          'verbosity': _verbosity,
          'high_contrast': _highContrast,
          'language': _language,
          'font_scale': _fontScale,
        },
        defaultHighContrast: _highContrast,
        defaultTextScale: _fontScale,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context)!.settingsSavedConfirmation,
            ),
          ),
        );
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(
        () => _error = AppLocalizations.of(
          context,
        )!.settingsErrorSaveFailed(e.toString()),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l10n.settingsVerbosityLabel,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    SegmentedButton<String>(
                      segments: [
                        ButtonSegment(
                          value: 'low',
                          label: Text(l10n.settingsVerbosityLow),
                        ),
                        ButtonSegment(
                          value: 'medium',
                          label: Text(l10n.settingsVerbosityMedium),
                        ),
                        ButtonSegment(
                          value: 'high',
                          label: Text(l10n.settingsVerbosityHigh),
                        ),
                      ],
                      selected: {_verbosity},
                      onSelectionChanged: (selection) =>
                          setState(() => _verbosity = selection.first),
                    ),
                    const SizedBox(height: 16),
                    SwitchListTile(
                      title: Text(l10n.settingsHighContrastLabel),
                      subtitle: Text(l10n.settingsHighContrastSubtitle),
                      value: _highContrast,
                      onChanged: (value) =>
                          setState(() => _highContrast = value),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.settingsLanguageLabel,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    SegmentedButton<String?>(
                      segments: [
                        ButtonSegment(
                          value: null,
                          label: Text(l10n.settingsLanguageAuto),
                        ),
                        ButtonSegment(
                          value: 'en',
                          label: Text(l10n.settingsLanguageEnglish),
                        ),
                        ButtonSegment(
                          value: 'es',
                          label: Text(l10n.settingsLanguageSpanish),
                        ),
                      ],
                      selected: {_language},
                      onSelectionChanged: (selection) =>
                          setState(() => _language = selection.first),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.settingsFontSizeLabel,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    SegmentedButton<double>(
                      segments: [
                        ButtonSegment(
                          value: 0.85,
                          label: Text(l10n.settingsFontSizeSmall),
                        ),
                        ButtonSegment(
                          value: 1.0,
                          label: Text(l10n.settingsFontSizeNormal),
                        ),
                        ButtonSegment(
                          value: 1.15,
                          label: Text(l10n.settingsFontSizeLarge),
                        ),
                        ButtonSegment(
                          value: 1.3,
                          label: Text(l10n.settingsFontSizeExtraLarge),
                        ),
                      ],
                      selected: {_fontScale},
                      onSelectionChanged: (selection) =>
                          setState(() => _fontScale = selection.first),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                    ],
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(l10n.settingsSaveButton),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
