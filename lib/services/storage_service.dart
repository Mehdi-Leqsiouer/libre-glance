import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/alerts.dart';
import '../models/thresholds.dart';

/// Set once the server holds this device's alert settings and notifies it itself: the
/// app then stops evaluating alerts locally (they would be duplicated).
const String serverAlertsFlag = 'server_alerts';

/// Credentials and settings, all in the platform secure storage (KISS: one store).
class StorageService {
  // first_unlock: readable by the background task while the phone is locked
  // (the default, `unlocked`, makes every background read fail).
  StorageService([FlutterSecureStorage? s])
    : _s =
          s ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
          );
  final FlutterSecureStorage _s;

  Future<({String email, String password})?> readCredentials() async {
    final email = await _s.read(key: 'email');
    final password = await _s.read(key: 'password');
    return (email == null || password == null)
        ? null
        : (email: email, password: password);
  }

  Future<void> saveCredentials(String email, String password) async {
    await _s.write(key: 'email', value: email);
    await _s.write(key: 'password', value: password);
  }

  Future<void> clearCredentials() async {
    await _s.delete(key: 'email');
    await _s.delete(key: 'password');
  }

  Future<Thresholds> readThresholds() async {
    final min = int.tryParse(await _s.read(key: 'min') ?? '');
    final max = int.tryParse(await _s.read(key: 'max') ?? '');
    return Thresholds(min: min ?? 70, max: max ?? 180);
  }

  Future<void> saveThresholds(Thresholds t) async {
    await _s.write(key: 'min', value: '${t.min}');
    await _s.write(key: 'max', value: '${t.max}');
  }

  Future<String?> readActivityToken() => _s.read(key: 'activity_token');

  Future<void> saveActivityToken(String token) =>
      _s.write(key: 'activity_token', value: token);

  Future<void> deleteActivityToken() => _s.delete(key: 'activity_token');

  Future<String?> readPushToStartToken() => _s.read(key: 'push_to_start_token');

  Future<void> savePushToStartToken(String token) =>
      _s.write(key: 'push_to_start_token', value: token);

  Future<String?> readDeviceToken() => _s.read(key: 'device_token');

  Future<void> saveDeviceToken(String token) =>
      _s.write(key: 'device_token', value: token);

  /// Restart the Live Activity remotely when iOS ends it (default on).
  Future<bool> readAutoRestart() async =>
      await _s.read(key: 'auto_restart') != '0';

  Future<void> saveAutoRestart(bool on) =>
      _s.write(key: 'auto_restart', value: on ? '1' : '0');

  Future<bool> readLiveActivity() async =>
      await _s.read(key: 'live_activity') == '1';

  Future<void> saveLiveActivity(bool on) =>
      _s.write(key: 'live_activity', value: on ? '1' : '0');

  /// Items written by older builds are only readable while the phone is unlocked.
  /// Re-write them once with the `first_unlock` accessibility. Foreground only.
  Future<void> migrateAccessibility() async {
    if (await _s.read(key: 'kc_first_unlock') == '1') return;
    for (final e in (await _s.readAll()).entries) {
      await _s.delete(key: e.key);
      await _s.write(key: e.key, value: e.value);
    }
    await _s.write(key: 'kc_first_unlock', value: '1');
  }

  /// Small boolean flags (e.g. "Live Activity ended reminder already sent").
  Future<bool> readFlag(String key) async => await _s.read(key: key) == '1';

  Future<void> saveFlag(String key, bool on) =>
      _s.write(key: key, value: on ? '1' : '0');

  Future<Map<String, dynamic>> _readJson(String key) async {
    final raw = await _s.read(key: key);
    return raw == null ? {} : jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<AlertSettings> readAlertSettings() async =>
      AlertSettings.fromJson(await _readJson('alert_settings'));

  Future<void> saveAlertSettings(AlertSettings s) =>
      _s.write(key: 'alert_settings', value: jsonEncode(s.toJson()));

  Future<AlertState> readAlertState() async =>
      AlertState.fromJson(await _readJson('alert_state'));

  Future<void> saveAlertState(AlertState s) =>
      _s.write(key: 'alert_state', value: jsonEncode(s.toJson()));

  /// Newest first, capped at [historyLimit].
  Future<List<AlertRecord>> readAlertHistory() async {
    final raw = await _s.read(key: 'alert_history');
    if (raw == null) return [];
    return (jsonDecode(raw) as List<dynamic>)
        .map((e) => AlertRecord.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static const historyLimit = 50;

  Future<void> addAlertHistory(List<AlertRecord> added) async {
    final all = [...added, ...await readAlertHistory()].take(historyLimit);
    await _s.write(
      key: 'alert_history',
      value: jsonEncode([for (final r in all) r.toJson()]),
    );
  }
}
