import Flutter
import UIKit
import UserNotifications
import flutter_local_notifications
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // BGTaskScheduler requires launch handlers to be registered before launch finishes
    // (otherwise iOS raises an exception and the app crashes on open).
    WorkmanagerPlugin.registerPeriodicTask(withIdentifier: "com.datally.libreglance.refresh")
    // Lets the background isolate (workmanager) use plugins such as live_activities.
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    // Show alerts while the app is open, and let notification actions (snooze) run in a background isolate.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    FlutterLocalNotificationsPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
