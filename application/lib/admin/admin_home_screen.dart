import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Placeholder `admin`-role home screen. The real anchor-point capture flow
/// (camera + building/location-type pickers + upload to
/// backend-map-management) is a separate follow-up; this just proves the
/// role-based routing in AuthGate reaches an admin-only screen.
class AdminHomeScreen extends StatelessWidget {
  const AdminHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => Supabase.instance.client.auth.signOut(),
          ),
        ],
      ),
      body: const Center(
        child: Text('Anchor point capture screen coming soon.'),
      ),
    );
  }
}
