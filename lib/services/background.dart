import 'dart:io';

import 'package:workmanager/workmanager.dart';

import '../models/glucose.dart';
import '../models/thresholds.dart';
import 'alert_service.dart';
import 'history_store.dart';
import 'librelinkup_service.dart';
import 'live_activity_manager.dart';
import 'notification_service.dart';
import 'storage_service.dart';

const String refreshTask = 'com.datally.libreglance.refresh';

/// Runs in a background isolate: re-login, fetch, check alerts, update the Live Activity.
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, _) async {
    // Nothing may escape from here. workmanager's iOS side force-casts the error
    // details sent back to it, and a PlatformException whose details are not a
    // String (a keychain error code while the phone is locked, ...) aborts the app.
    try {
      final storage = StorageService();
      final creds = await storage.readCredentials();
      if (creds == null) return true;
      final service = LibreLinkUpService();
      await service.login(creds.email, creds.password);
      final patient = await service.firstConnection();
      final graph = await service.getGraph(patient.patientId);
      final m = graph.current;
      if (m != null) {
        final thresholds = await storage.readThresholds();
        await AlertService(storage, NotificationService.instance.show).check(
          m,
          thresholds,
          patient.name,
          sensorStart: graph.sensorActivatedAt,
        );
        if (await storage.readLiveActivity()) {
          await _keepLiveActivity(storage, m, thresholds, patient.name);
        }
      }
      await HistoryStore().add([...graph.history, ?m]);
      return true;
    } catch (_) {
      return false; // let the OS retry
    }
  });
}

/// iOS only lets an app *start* a Live Activity while it is in the foreground, so
/// once iOS has ended it (8 h limit, dismissed) all we can do here is ask the
/// user to reopen the app, once.
Future<void> _keepLiveActivity(
  StorageService storage,
  GlucoseMeasurement m,
  Thresholds thresholds,
  String patient,
) async {
  final activity = LiveActivityManager();
  if (Platform.isIOS && !await activity.isActive()) {
    if (!await storage.readFlag(endedReminderFlag)) {
      await NotificationService.instance.showInfo(
        100,
        'Live Activity arrêtée',
        "iOS l'a arrêtée. Ouvre LibreGlance pour la relancer.",
      );
      await storage.saveFlag(endedReminderFlag, true);
    }
    return;
  }
  await activity.update(m, thresholds, patient);
  await storage.saveFlag(endedReminderFlag, false);
}

/// iOS runs this on its own schedule (best effort); Android minimum is 15 min.
Future<void> scheduleBackgroundRefresh() async {
  if (!Platform.isIOS && !Platform.isAndroid) return;
  await Workmanager().initialize(backgroundDispatcher);
  await Workmanager().registerPeriodicTask(
    refreshTask,
    refreshTask,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
  );
}
