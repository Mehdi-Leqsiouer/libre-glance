import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'storage_service.dart';

/// Public URL of the API (infra/: `terraform output api_url`). Not a secret: every call
/// must carry the key derived from the LibreLinkUp credentials.
const String pushServerUrl = 'https://libreglance-api-xsq54deg2a-od.a.run.app';

/// Same formula as `derive_key` in server/libreglance/api.py.
String deriveKey(String email, String password) => sha256
    .convert(utf8.encode('libreglance:${email.trim().toLowerCase()}:$password'))
    .toString();

/// Everything the push server needs to know about this device: the Live Activity
/// tokens, the device token for alerts, the thresholds and the alert settings.
class PushRegistrar {
  PushRegistrar(
    this._storage, {
    http.Client? client,
    this.serverUrl = pushServerUrl,
  }) : _client = client ?? http.Client();
  final StorageService _storage;
  final http.Client _client;
  final String serverUrl;

  static const _channel = MethodChannel('libreglance/push');

  /// Asks iOS for the device token (delivered through the channel, or returned at once).
  Future<void> start() async {
    if (!Platform.isIOS) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'token') await onDeviceToken(call.arguments as String);
    });
    final token = await _channel.invokeMethod<String>('register');
    if (token != null) await onDeviceToken(token);
  }

  /// Live Activity push token: new activity, or token rotated by iOS.
  Future<void> onToken(String token) =>
      _store(token, _storage.readActivityToken, _storage.saveActivityToken);

  Future<void> onPushToStartToken(String token) => _store(
    token,
    _storage.readPushToStartToken,
    _storage.savePushToStartToken,
  );

  Future<void> onDeviceToken(String token) =>
      _store(token, _storage.readDeviceToken, _storage.saveDeviceToken);

  Future<void> _store(
    String token,
    Future<String?> Function() read,
    Future<void> Function(String) save,
  ) async {
    if (token == await read()) return;
    await save(token);
    await sync();
  }

  /// Null when registered or when there is nothing to register yet.
  Future<String?> sync() async {
    final activity = await _storage.readActivityToken();
    final pushToStart = await _storage.readPushToStartToken();
    final device = await _storage.readDeviceToken();
    if (activity == null && pushToStart == null && device == null) return null;
    final thresholds = await _storage.readThresholds();
    final error = await _post('/register', {
      'min_target': thresholds.min,
      'max_target': thresholds.max,
      'auto_restart': await _storage.readAutoRestart(),
      'settings': (await _storage.readAlertSettings()).toJson(),
      'activity_token': ?activity,
      'push_to_start_token': ?pushToStart,
      'device_token': ?device,
    });
    if (error == null && device != null) {
      await _storage.saveFlag(serverAlertsFlag, true);
    }
    return error;
  }

  /// The Dynamic Island switch is off: stop updating and restarting the Live Activity.
  Future<String?> unregister() async {
    await _storage.deleteActivityToken();
    return _post('/unregister', null);
  }

  /// Snooze the alerts on the server; null or zero clears it.
  Future<String?> snooze(Duration? duration) =>
      _post('/snooze', {'minutes': duration?.inMinutes ?? 0});

  Future<String?> _post(String path, Map<String, Object?>? body) async {
    final credentials = await _storage.readCredentials();
    if (credentials == null) return null;
    try {
      final res = await _client.post(
        Uri.parse('$serverUrl$path'),
        headers: {
          'Content-Type': 'application/json',
          'X-Api-Key': deriveKey(credentials.email, credentials.password),
        },
        body: body == null ? null : jsonEncode(body),
      );
      return res.statusCode == 200 ? null : 'Serveur : HTTP ${res.statusCode}';
    } on Exception catch (e) {
      return 'Serveur injoignable : $e';
    }
  }
}
