import 'package:flutter/material.dart';

import 'services/librelinkup_service.dart';
import 'services/live_activity_manager.dart';
import 'services/storage_service.dart';
import 'ui/home_screen.dart';
import 'ui/login_screen.dart';

void main() => runApp(const LibreGlanceApp());

class LibreGlanceApp extends StatefulWidget {
  const LibreGlanceApp({super.key});

  @override
  State<LibreGlanceApp> createState() => _LibreGlanceAppState();
}

class _LibreGlanceAppState extends State<LibreGlanceApp> {
  final _service = LibreLinkUpService();
  final _storage = StorageService();
  final _liveActivity = LiveActivityManager();
  bool? _loggedIn; // null = restoring session

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final c = await _storage.readCredentials();
    var ok = false;
    if (c != null) {
      try {
        await _service.login(c.email, c.password);
        ok = true;
      } on Exception {
        // Offline or rejected: fall back to the login screen.
      }
    }
    if (mounted) setState(() => _loggedIn = ok);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'LibreGlance',
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.teal,
      brightness: Brightness.dark,
      useMaterial3: true,
    ),
    home: switch (_loggedIn) {
      null => const Scaffold(body: Center(child: CircularProgressIndicator())),
      true => HomeScreen(
        service: _service,
        storage: _storage,
        liveActivity: _liveActivity,
        onLogout: () => setState(() => _loggedIn = false),
      ),
      false => LoginScreen(
        service: _service,
        storage: _storage,
        onLoggedIn: () => setState(() => _loggedIn = true),
      ),
    },
  );
}
