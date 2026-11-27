import 'dart:convert';

import 'package:http/http.dart' as http;

import 'storage_service.dart';

/// Tells the push server which Live Activity to update, and with which thresholds.
class PushRegistrar {
  PushRegistrar(this._storage, [http.Client? client])
    : _client = client ?? http.Client();
  final StorageService _storage;
  final http.Client _client;

  /// Called whenever iOS issues (or rotates) the Live Activity push token.
  Future<void> onToken(String token) async {
    await _storage.saveActivityToken(token);
    await sync();
  }

  /// Null when registered or when there is nothing to register yet.
  Future<String?> sync() async {
    final server = await _storage.readServer();
    final token = await _storage.readActivityToken();
    if (server == null || token == null) return null;
    final thresholds = await _storage.readThresholds();
    final base = server.url.replaceAll(RegExp(r'/+$'), '');
    try {
      final res = await _client.post(
        Uri.parse('$base/register'),
        headers: {
          'Content-Type': 'application/json',
          'X-Api-Key': server.apiKey,
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
