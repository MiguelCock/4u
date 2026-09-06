import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../camera.dart';
import '../location.dart';
import '../map.dart';
import 'route_list_screen.dart';

/// The `user`-role home screen: the original single-screen prototype
/// (live location, camera capture, map), plus an entry point into the
/// route list / navigation-session flow.
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
            icon: const Icon(Icons.logout),
            onPressed: () => Supabase.instance.client.auth.signOut(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const RouteListScreen()),
          );
        },
        icon: const Icon(Icons.alt_route),
        label: const Text('Navigate'),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            const LocationInfo(),
            const SizedBox(
              height: 300,
              child: SimpleCameraWidget(),
            ),
            const SizedBox(
              height: 400,
              child: SimpleMapWidget(),
            ),
          ],
        ),
      ),
    );
  }
}
