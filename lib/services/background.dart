import 'dart:io';

import 'package:workmanager/workmanager.dart';

import 'librelinkup_service.dart';
import 'live_activity_manager.dart';
import 'storage_service.dart';

const String refreshTask = 'com.datally.libreglance.refresh';

/// Runs in a background isolate: re-login, fetch, push to the Live Activity.
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, _) async {
    final storage = StorageService();
    if (!await storage.readLiveActivity()) return true;
    final creds = await storage.readCredentials();
    if (creds == null) return true;
    try {
      final service = LibreLinkUpService();
      await service.login(creds.email, creds.password);
      final patient = (await service.getConnections()).first;
      final m = (await service.getGraph(patient.patientId)).current;
      if (m != null) {
        await LiveActivityManager().update(
          m,
          await storage.readThresholds(),
          patient.name,
        );
      }
      return true;
    } on Exception {
      return false; // let the OS retry
    }
  });
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
