import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../camera.dart';
import '../location.dart';
import '../map.dart';

/// The `user`-role home screen: the original single-screen prototype
/// (live location, camera capture, map). Route list / navigation-session
/// entry points are a separate follow-up.
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
