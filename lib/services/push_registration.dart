import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'storage_service.dart';

/// Public URL of the registration API (infra/: `terraform output api_url`). Not a secret:
/// every call must carry the key derived from the LibreLinkUp credentials.
const String pushServerUrl = 'https://libreglance-api-xsq54deg2a-od.a.run.app';

/// Same formula as `derive_key` in server/libreglance/api.py.
String deriveKey(String email, String password) => sha256
    .convert(utf8.encode('libreglance:${email.trim().toLowerCase()}:$password'))
    .toString();

/// Tells the push server which Live Activity to update, and with which thresholds.
class PushRegistrar {
  PushRegistrar(
    this._storage, {
    http.Client? client,
    this.serverUrl = pushServerUrl,
  }) : _client = client ?? http.Client();
  final StorageService _storage;
  final http.Client _client;
  final String serverUrl;

  /// Called whenever iOS issues (or rotates) the Live Activity push token.
  Future<void> onToken(String token) async {
    if (token == await _storage.readActivityToken()) return;
    await _storage.saveActivityToken(token);
    await sync();
  }

  /// Null when registered or when there is nothing to register yet.
  Future<String?> sync() async {
    final credentials = await _storage.readCredentials();
    final token = await _storage.readActivityToken();
    if (credentials == null || token == null) return null;
    final thresholds = await _storage.readThresholds();
    try {
      final res = await _client.post(
        Uri.parse('$serverUrl/register'),
        headers: {
          'Content-Type': 'application/json',
          'X-Api-Key': deriveKey(credentials.email, credentials.password),
        },
        body: jsonEncode({
          'activity_token': token,
          'min_target': thresholds.min,
          'max_target': thresholds.max,
        }),
      );
      return res.statusCode == 200 ? null : 'Serveur : HTTP ${res.statusCode}';
    } on Exception catch (e) {
      return 'Serveur injoignable : $e';
    }
  }
}
