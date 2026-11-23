# LibreGlance

Minimal Flutter app (iOS + Android) that reads real-time glucose from the **LibreLinkUp** API and shows it in the iOS **Dynamic Island / Live Activity**, in the app, and in a home-screen widget.

> Unofficial. Not affiliated with Abbott. Not a medical device: never use it for treatment decisions.

## Status

| Step | Scope | State |
|------|-------|-------|
| 1 | Flutter project, LibreLinkUp client, models, parsing tests | done |
| 2 | Main screen (login, live value, 4h chart, thresholds, Live Activity toggle) | done |
| 3 | iOS ActivityKit / Dynamic Island, Android notification, background refresh | done (iOS device test pending) |

## Layout

```
lib/models/     data models + LibreView timestamp / trend parsing
lib/services/   LibreLinkUp API client (storage and Live Activity manager to come)
lib/ui/         login + home screens
lib/widgets/    glucose card, 4h chart
```

## Develop

```
flutter pub get
flutter analyze
flutter test
```

Credentials are entered in the app and kept in the platform secure storage. Never commit them.
The API `version` header is the constant `libreLinkUpVersion` in `lib/services/librelinkup_service.dart`.

## iOS setup (already applied in the repo)

- **Extension target** `LibreGlanceLiveActivity` (`ios/LibreGlanceLiveActivity/`), embedded in `Runner`, iOS 16.2+.
- **App Group** `group.com.datally.libreglance` on both targets (`Runner.entitlements`, `LibreGlanceLiveActivity.entitlements`). Enable it for your team in Signing & Capabilities and keep the id in sync with `appGroupId` in `lib/services/live_activity_manager.dart`.
- **`NSSupportsLiveActivities = YES`** in `Runner/Info.plist` and the extension `Info.plist`.
- **Background**: `UIBackgroundModes` (`fetch`, `processing`) and `BGTaskSchedulerPermittedIdentifiers` (`com.datally.libreglance.refresh`) in `Info.plist`. iOS decides when the task runs, so the ~5 min refresh is best effort (the app also refreshes every minute in the foreground and on resume). No APNs: remote updates are disabled (`iOSEnableRemoteUpdates: false`) and the Push Notifications capability is not needed.
- The `live_activities` plugin requires the attributes type to be named `LiveActivitiesAppAttributes`; values are passed through the App Group `UserDefaults` (keys: `glucose`, `trend`, `timestamp`, `min`, `max`, `patient`).
- Test on a real iPhone (14 Pro or later for the Dynamic Island): toggle the switch, then check the lock screen and the island.

## Android

The same toggle shows a silent, persistent, low-priority notification (`CustomLiveActivityManager.kt`) with value + trend arrow. Notification permission is requested on first use. Periodic refresh via WorkManager (15 min minimum on Android).

## Xcode Cloud (push on `main` -> TestFlight)

`ios/ci_scripts/ci_post_clone.sh` installs Flutter (pinned `FLUTTER_VERSION`, keep it equal to `flutter --version` locally), sets the build number from `CI_BUILD_NUMBER` and generates the gitignored iOS files. The workflow itself (start condition, archive, TestFlight post-action) is configured in Xcode (Report navigator > Cloud).

## TestFlight

1. Set a unique bundle id and team in Xcode.
2. `flutter build ipa --release`
3. Upload `build/ios/ipa/*.ipa` with Transporter (or `xcrun altool`), then add testers in App Store Connect > TestFlight.
