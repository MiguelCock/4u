import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth/auth_gate.dart';
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
    anonKey: dotenv.env['SUPABASE_PUBLISHABLE_KEY'] ?? 'placeholder-key',
  );

  await LocationService().initialize();
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: '4u',
      home: AuthGate(),
    );
  }
}
