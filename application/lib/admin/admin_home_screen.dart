import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/api_service.dart';
import 'capture_screen.dart';

/// `admin`-role home screen: a read-only list of captured anchor points plus
/// an entry point into `CaptureScreen`.
class AdminHomeScreen extends StatefulWidget {
  const AdminHomeScreen({super.key});

  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends State<AdminHomeScreen> {
  final _mapApi = MapManagementApi();
  late Future<List<Map<String, dynamic>>> _anchorPointsFuture;

  @override
  void initState() {
    super.initState();
    _anchorPointsFuture = _loadAnchorPoints();
  }

  Future<List<Map<String, dynamic>>> _loadAnchorPoints() async {
    final result = await _mapApi.get('/anchor-points');
    if (result is List) return result.cast<Map<String, dynamic>>();
    return [];
  }

  void _refresh() => setState(() => _anchorPointsFuture = _loadAnchorPoints());

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
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const CaptureScreen()),
          );
          _refresh();
        },
        child: const Icon(Icons.add_a_photo),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _anchorPointsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Failed to load anchor points: ${snapshot.error}'));
          }
          final anchorPoints = snapshot.data ?? [];
          if (anchorPoints.isEmpty) {
            return const Center(child: Text('No anchor points captured yet.'));
          }
          return ListView.builder(
            itemCount: anchorPoints.length,
            itemBuilder: (context, index) {
              final point = anchorPoints[index];
              return ListTile(
                leading: const Icon(Icons.location_pin),
                title: Text(point['location_description'] as String? ?? point['id'] as String),
                subtitle: Text('Status: ${point['status'] ?? 'unknown'}'),
              );
            },
          );
        },
      ),
    );
  }
}
