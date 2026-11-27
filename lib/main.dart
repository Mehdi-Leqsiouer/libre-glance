import 'dart:async';

import 'package:flutter/material.dart';

import 'services/background.dart';
import 'services/librelinkup_service.dart';
import 'services/live_activity_manager.dart';
import 'services/notification_service.dart';
import 'services/push_registration.dart';
import 'services/storage_service.dart';
import 'ui/home_screen.dart';
import 'ui/login_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = StorageService();
  final registrar = PushRegistrar(storage);
  final liveActivity = LiveActivityManager(
    onToken: registrar.onToken,
    onPushToStartToken: registrar.onPushToStartToken,
  );
  runApp(
    LibreGlanceApp(
      storage: storage,
      registrar: registrar,
      liveActivity: liveActivity,
    ),
  );
  // After runApp and not awaited: a hang or failure here must never block the UI.
  unawaited(scheduleBackgroundRefresh().catchError((Object _) {}));
  unawaited(NotificationService.instance.init().catchError((Object _) {}));
  // Early on purpose: iOS can launch the app in the background when the server
  // restarts the Live Activity, and the new activity's token is only seen if we listen.
  unawaited(liveActivity.listen().catchError((Object _) {}));
  unawaited(registrar.start().catchError((Object _) {}));
}

class LibreGlanceApp extends StatefulWidget {
  const LibreGlanceApp({
    super.key,
    required this.storage,
    required this.registrar,
    required this.liveActivity,
  });
  final StorageService storage;
  final PushRegistrar registrar;
  final LiveActivityManager liveActivity;

  @override
  State<LibreGlanceApp> createState() => _LibreGlanceAppState();
}

class _LibreGlanceAppState extends State<LibreGlanceApp> {
  final _service = LibreLinkUpService();
  StorageService get _storage => widget.storage;
  PushRegistrar get _registrar => widget.registrar;
  LiveActivityManager get _liveActivity => widget.liveActivity;
  bool? _loggedIn; // null = restoring session

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      await _storage.migrateAccessibility();
    } catch (_) {
      // Retried on the next launch; credentials stay readable while unlocked.
    }
    final c = await _storage.readCredentials();
    if (c != null) {
      try {
        await _service.login(c.email, c.password);
      } catch (_) {
        // Offline or rejected: stay logged in. login() already kept the credentials
        // in memory, the home screen retries and shows the error, and "Déconnexion"
        // stays available. Never throw the user back to the login form for a network blip.
      }
    }
    if (mounted) setState(() => _loggedIn = c != null);
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
        registrar: _registrar,
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
