# LibreGlance

Minimal Flutter app (iOS + Android) that reads real-time glucose from the **LibreLinkUp** API and shows it in the iOS **Dynamic Island / Live Activity**, in the app, and in a home-screen widget.

> Unofficial. Not affiliated with Abbott. Not a medical device: never use it for treatment decisions.

## Status

| Step | Scope | State |
|------|-------|-------|
| 1 | Flutter project, LibreLinkUp client, models, parsing tests | done |
| 2 | Main screen (login, live value, 4h chart, thresholds, Live Activity toggle) | todo |
| 3 | iOS ActivityKit / Dynamic Island + widget, Android notification / widget | todo |

## Layout

```
lib/models/     data models + LibreView timestamp / trend parsing
lib/services/   LibreLinkUp API client (storage and Live Activity manager to come)
lib/ui/         screens (step 2)
lib/widgets/    reusable widgets (step 2)
```

## Develop

```
flutter pub get
flutter analyze
flutter test
```

Credentials are entered in the app and kept in the platform secure storage. Never commit them.
The API `version` header is the constant `libreLinkUpVersion` in `lib/services/librelinkup_service.dart`.

## iOS setup (step 3 reference)

1. **App Group**: enable `group.com.datally.libreglance` on both the `Runner` and `LibreGlanceLiveActivity` targets (Signing & Capabilities).
2. **Live Activities**: add `NSSupportsLiveActivities = YES` to `ios/Runner/Info.plist`.
3. **Background**: enable Background Modes (Background fetch, Background processing) and register the task identifiers in `Info.plist` (`BGTaskSchedulerPermittedIdentifiers`). iOS decides when tasks run; ~5 min refresh is best effort. Remote push updates of the Live Activity would need an APNs server and are out of scope.
4. Widget extension target `LibreGlanceLiveActivity` defines `LibreGlanceAttributes` (value, trend, timestamp, min/max target, patient name).

## TestFlight

1. Set a unique bundle id and team in Xcode.
2. `flutter build ipa --release`
3. Upload `build/ios/ipa/*.ipa` with Transporter (or `xcrun altool`), then add testers in App Store Connect > TestFlight.
