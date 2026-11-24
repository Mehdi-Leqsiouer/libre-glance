import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/alerts.dart';
import 'alert_service.dart';
import 'storage_service.dart';

const _category = 'glucose_alert';
const _snoozeActions = {'snooze_15': 15, 'snooze_30': 30};

/// Runs in a separate isolate when the user taps a notification action.
@pragma('vm:entry-point')
void handleNotificationResponse(NotificationResponse r) {
  final minutes = _snoozeActions[r.actionId];
  if (minutes != null) {
    AlertService.snooze(StorageService(), Duration(minutes: minutes));
  }
}

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// Also asks for the notification permission the first time.
  Future<void> init() async {
    if (_ready) return;
    await _plugin.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          notificationCategories: [
            DarwinNotificationCategory(
              _category,
              actions: [
                DarwinNotificationAction.plain('snooze_15', 'Reporter 15 min'),
                DarwinNotificationAction.plain('snooze_30', 'Reporter 30 min'),
              ],
            ),
          ],
        ),
      ),
      onDidReceiveNotificationResponse: handleNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: handleNotificationResponse,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    _ready = true;
  }

  /// Asks iOS for the critical alert permission. False if refused, or if the app
  /// lacks Apple's critical alerts entitlement (the prompt is then not offered).
  Future<bool> requestCritical() async {
    await init();
    return await _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
              critical: true,
            ) ??
        false;
  }

  /// Informational notification, outside the alert machinery.
  Future<void> showInfo(int id, String title, String body) async {
    await init();
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails('info', 'Informations'),
        iOS: DarwinNotificationDetails(),
      ),
    );
  }

  Future<void> show(
    AlertKind kind,
    String title,
    String body, {
    bool critical = false,
  }) async {
    await init();
    await _plugin.show(
      id: kind.index,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'glucose_alerts',
          'Alertes glycémie',
          importance: Importance.max,
          priority: Priority.high,
          category: AndroidNotificationCategory.alarm,
          actions: const [
            AndroidNotificationAction('snooze_15', 'Reporter 15 min'),
            AndroidNotificationAction('snooze_30', 'Reporter 30 min'),
          ],
        ),
        iOS: DarwinNotificationDetails(
          categoryIdentifier: _category,
          interruptionLevel: critical
              ? InterruptionLevel.critical
              : InterruptionLevel.timeSensitive,
          criticalSoundVolume: critical ? 1.0 : null,
        ),
      ),
    );
  }
}
