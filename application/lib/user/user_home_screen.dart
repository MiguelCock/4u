import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../camera.dart';
import 'places_overview_map.dart';
import 'plan_trip_screen.dart';

/// The `user`-role home screen: a places overview (see #81's "see the
/// places" ask) with a prominent "Where to?" entry point into the
/// Uber-style trip-planning flow (PlanTripScreen), replacing the old flat,
/// pre-made route list. The original raw camera-capture prototype (sends
/// a photo straight to backend-data-collection - a distinct, still-real
/// feature, not superseded by trip planning) moved behind a secondary
/// app-bar action instead of disappearing.
class UserHomeScreen extends StatelessWidget {
  const UserHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('4u'),
        backgroundColor: Colors.blue,
        actions: [
          IconButton(
            icon: const Icon(Icons.camera_alt_outlined),
            tooltip: 'Data collection camera',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: const Text('Data collection')),
                    body: const SimpleCameraWidget(),
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => Supabase.instance.client.auth.signOut(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const PlanTripScreen()));
        },
        icon: const Icon(Icons.search),
        label: const Text('Where to?'),
      ),
      body: const PlacesOverviewMap(),
    );
  }
}
