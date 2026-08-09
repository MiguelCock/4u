import 'package:flutter/material.dart';
import 'package:front_collection/camera.dart';
import 'services/location_service.dart';
import 'map.dart';
import 'location.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocationService().initialize();
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Flutter Map Test'),
          backgroundColor: Colors.blue,
        ),
        body: Column(
          children: [
            const LocationInfo(),
            Expanded(child: const SimpleCameraWidget()),
            Expanded(child: const SimpleMapWidget()),
          ],
        ),
      ),
    );
  }
}
