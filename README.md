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
lib/services/   LibreLinkUp client, storage, Live Activity, alerts, background refresh
lib/ui/         login, home and alerts screens
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
- **Background**: `UIBackgroundModes` (`fetch`, `processing`) and `BGTaskSchedulerPermittedIdentifiers` (`com.datally.libreglance.refresh`) in `Info.plist`. iOS decides when the task runs and it is rare, so background refreshes are best effort (the app also refreshes every minute in the foreground and on resume). Reliable updates with the app closed come from the push server below.
- **Push**: `aps-environment` in `Runner.entitlements` and `NSSupportsLiveActivitiesFrequentUpdates` in `Info.plist` (Push Notifications is enabled on the App ID by automatic signing).
- The `live_activities` plugin requires the attributes type to be named `LiveActivitiesAppAttributes`. The app passes values through the App Group `UserDefaults` (keys: `glucose`, `trend`, `timestamp`, `min`, `max`, `patient`); the server's pushes fill `ContentState` instead (same fields, see `server/libreglance/poll.py`). The extension shows whichever holds the newest reading.
- Test on a real iPhone (14 Pro or later for the Dynamic Island): toggle the switch, then check the lock screen and the island.

## Alerts

Local notifications, evaluated after every refresh (app open, and the iOS background task when iOS allows it). Each alert is a switch in the in-app Alerts screen (bell icon): urgent low (own threshold, ignores snooze), low (uses the min threshold), rapid fall, high (off by default), data loss (no recent reading, configurable delay). Cooldowns avoid repeats, snooze is available from the notification actions and the app, and the last 50 alerts are kept in a history. The decision logic is the pure function in `lib/services/alert_engine.dart` (tested).

Sensor expiry: a reminder 24 h before the end of the sensor (activation date from the graph payload, `activeSensors[0].sensor.a`; lifetime configurable, 14 days by default, 15 for the Plus models). The remaining time is also shown on the main screen.

**Live Activity ended by iOS** (8 h limit): iOS only lets an app start a Live Activity in the foreground, so the background task can only send one notification asking to reopen the app, which recreates it. Silent restarts would need a server and push-to-start.

**Server alerts (reliable)**: once the app has registered with the push server (see below), the server evaluates the same alerts every minute and sends them as APNs notifications, even with the app closed. The app then stops evaluating them locally (no duplicates). Every setting of the Alerts screen (thresholds, urgent low, rapid fall, high, data loss delay, sensor expiry, critical mode) is sent to the server whenever it changes, and the snooze buttons (in the app and on the notification) reach it too. The logic lives in `server/libreglance/alerts.py`, a port of `alert_engine.dart` with the same test cases: change both together. Server alerts are not in the in-app history.

**Local alerts (fallback)**: until the device is registered, or on a phone without the server, alerts run in the app at each refresh, and in the iOS background task, which runs at its own pace (about every 15 min at best): a low can be detected late, or not at all if the app stays closed for long.

**Critical alerts (opt-in, off by default)**: ring through silent mode and Do Not Disturb for the two low alerts. The code is ready (`criticalEnabled`, interruption level `critical`) but it needs Apple's Critical Alerts entitlement:
1. Request it with Apple's "Critical Alerts entitlement request" form.
2. Once granted, enable the capability on the App ID `com.datally.libreGlance`.
3. Add `com.apple.developer.usernotifications.critical-alerts` = `true` to `ios/Runner/Runner.entitlements`. Do not add it before approval: signing would fail.

Other alerts use time-sensitive notifications, which pass Focus modes but not the silent switch.

## History and statistics

Every refresh (app and background task) stores the readings locally for 30 days, in 15 min bins (`HistoryStore`, a plain JSON file in the app support directory). The Statistics screen (bar chart icon) shows 24 h / 7 / 14 / 30 days: time below / in / above the target range, mean, standard deviation, CV, min / max and coverage. The history starts when this feature is installed, and gaps are periods where nothing could refresh.

## Push server (Live Activity updates with the app closed)

`server/` (Python, `uv`) and `infra/` (Terraform, GCP project `libre-glance`, `europe-west9`). A Cloud Scheduler job calls the private Cloud Run service `libreglance-poll` (`POST /poll`, OIDC, only the scheduler's service account may invoke it) every minute, which keeps the instance warm: it reads the latest LibreLinkUp measurement, sends the due alerts as APNs `alert` notifications to the device token, and, when the reading is new, an APNs `liveactivity` update to the registered activity. The app registers its tokens (Live Activity, push-to-start, device), the thresholds and the alert settings on the small Cloud Run API (`POST /register`, plus `/unregister` when the Dynamic Island switch goes off and `/snooze`; public URL hardcoded in `lib/services/push_registration.dart`; authenticated with a key derived from the LibreLinkUp credentials, sha256 of `libreglance:<email>:<password>`, computed identically by the app and by `server/libreglance/api.py`, so there is nothing to enter or manage). State lives in Firestore, secrets in Secret Manager (never in Terraform state or the repo). Production and sandbox APNs are both tried, so TestFlight and Xcode builds work.

Deploy (first time):

```
cd infra && terraform init && terraform apply          # APIs, registry, Firestore, secret shells, service accounts

# Secret values, added out of band:
printf '%s' 'LIBRELINKUP_EMAIL'    | gcloud secrets versions add llu-email    --data-file=- --project libre-glance
printf '%s' 'LIBRELINKUP_PASSWORD' | gcloud secrets versions add llu-password --data-file=- --project libre-glance
gcloud secrets versions add apns-key-p8 --data-file=/path/to/AuthKey_9583USS5C2.p8 --project libre-glance

IMAGE=europe-west9-docker.pkg.dev/libre-glance/libreglance/server:v1
gcloud builds submit server --tag $IMAGE --project libre-glance
terraform apply -var image=$IMAGE                       # Cloud Run API + private poll service + scheduler
terraform output api_url
```

If `api_url` ever changes, update `pushServerUrl` in the app. Nothing else to configure in the app: turn on the Dynamic Island switch and it registers itself. If you change the LibreLinkUp password, update the `llu-password` secret too (the registration key follows it). To ship a new server version, rebuild the image with a new tag and re-apply with it.

**Automatic restart** (iOS 17.2+, switch "Relancer automatiquement" under the Dynamic Island switch, on by default): the app also registers its push-to-start token. About 7 h 40 after an activity was registered, the server starts a new one remotely and ends the old one, and it starts one when the current token is rejected (the user dismissed it, or iOS ended it). The new activity gets the same id as the plugin's `glucose` activity (`ACTIVITY_ID` in `poll.py`), so reopening the app updates it instead of creating a duplicate. The app must be woken by iOS to report the new activity's token: it listens to the token streams from `main()` for that. A restart is retried every 10 min at most. Turning the Dynamic Island switch off calls `/unregister` and stops the restarts.

Limits: restarting works only if iOS launches the app for the remotely started activity, which depends on iOS. The notification actions (snooze) need the category the app registers at launch.

Develop: `cd server && uv run ruff check . && uv run pytest`.

## Android

The same toggle shows a silent, persistent, low-priority notification (`CustomLiveActivityManager.kt`) with value + trend arrow. Notification permission is requested on first use. Periodic refresh via WorkManager (15 min minimum on Android).

## Xcode Cloud (push on `main` -> TestFlight)

`ios/ci_scripts/ci_post_clone.sh` installs Flutter (pinned `FLUTTER_VERSION`, keep it equal to `flutter --version` locally), sets the build number from `CI_BUILD_NUMBER` and generates the gitignored iOS files. The workflow itself (start condition, archive, TestFlight post-action) is configured in Xcode (Report navigator > Cloud).

## TestFlight

1. Set a unique bundle id and team in Xcode.
2. `flutter build ipa --release`
3. Upload `build/ios/ipa/*.ipa` with Transporter (or `xcrun altool`), then add testers in App Store Connect > TestFlight.
