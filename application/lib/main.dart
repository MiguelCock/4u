import 'package:flutter/material.dart';
import 'package:application/camera.dart';
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
        body: SingleChildScrollView(
          child: Column(
            children: [
              const LocationInfo(),
              SizedBox(
                height: 300,
                child: const SimpleCameraWidget(),
              ),
              SizedBox(
                height: 400,
                child: const SimpleMapWidget(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}