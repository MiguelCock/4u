import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth/auth_gate.dart';
import 'l10n/app_localizations.dart';
import 'services/app_preferences.dart';
import 'services/location_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    // No .env present (e.g. a fresh checkout, or a test run) - fall back to
    // an empty environment rather than crashing at startup. ApiService's
    // base URLs default to '' and Supabase.initialize below needs a
    // non-empty URL, so this path only supports offline/local dev without
    // a real backend/Supabase project configured yet.
    dotenv.testLoad(fileInput: '');
  }

  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL'] ?? 'https://placeholder.supabase.co',
    publishableKey: dotenv.env['SUPABASE_PUBLISHABLE_KEY'] ?? 'placeholder-key',
  );

  await LocationService().initialize();
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: highContrastNotifier,
      builder: (context, highContrast, _) {
        return ValueListenableBuilder<Locale?>(
          valueListenable: localeNotifier,
          builder: (context, locale, _) {
            return ValueListenableBuilder<double>(
              valueListenable: textScaleNotifier,
              builder: (context, textScale, _) {
                return MaterialApp(
                  title: '4u',
                  locale: locale,
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  theme: ThemeData(
                    colorScheme: highContrast
                        ? const ColorScheme.highContrastLight()
                        : ColorScheme.fromSeed(seedColor: Colors.blue),
                  ),
                  darkTheme: ThemeData(
                    colorScheme: highContrast
                        ? const ColorScheme.highContrastDark()
                        : ColorScheme.fromSeed(
                            seedColor: Colors.blue,
                            brightness: Brightness.dark,
                          ),
                  ),
                  builder: (context, child) {
                    return MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.linear(textScale)),
                      child: child!,
                    );
                  },
                  home: const AuthGate(),
                );
              },
            );
          },
        );
      },
    );
  }
}
