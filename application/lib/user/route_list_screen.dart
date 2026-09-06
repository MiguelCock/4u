import 'package:flutter/material.dart';

import '../services/api_service.dart';
import 'navigation_screen.dart';

class RouteListScreen extends StatefulWidget {
  const RouteListScreen({super.key});

  @override
  State<RouteListScreen> createState() => _RouteListScreenState();
}

class _RouteListScreenState extends State<RouteListScreen> {
  final _routeApi = RouteManagementApi();
  late Future<List<Map<String, dynamic>>> _routesFuture;

  @override
  void initState() {
    super.initState();
    _routesFuture = _loadRoutes();
  }

  Future<List<Map<String, dynamic>>> _loadRoutes() async {
    final result = await _routeApi.get('/routes');
    if (result is List) return result.cast<Map<String, dynamic>>();
    return [];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Routes')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _routesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Failed to load routes: ${snapshot.error}'));
          }
          final routes = snapshot.data ?? [];
          if (routes.isEmpty) {
            return const Center(child: Text('No routes available yet.'));
          }
          return ListView.builder(
            itemCount: routes.length,
            itemBuilder: (context, index) {
              final route = routes[index];
              return ListTile(
                leading: const Icon(Icons.alt_route),
                title: Text(route['name'] as String? ?? route['id'] as String),
                trailing: ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => NavigationScreen(route: route)),
                    );
                  },
                  child: const Text('Start'),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
