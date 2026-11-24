import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/glucose.dart';

/// Version header expected by LibreLinkUp; bump here if the API rejects it.
const String libreLinkUpVersion = '4.16.0';
const String libreLinkUpProduct = 'llu.ios';
const String defaultBaseUrl = 'https://api-eu.libreview.io';

class LibreLinkUpException implements Exception {
  LibreLinkUpException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'LibreLinkUpException($statusCode): $message';
}

class LibreLinkUpService {
  LibreLinkUpService({http.Client? client, this._baseUrl = defaultBaseUrl})
    : _client = client ?? http.Client();

  final http.Client _client;
  String _baseUrl;
  String? _token;
  String? _accountId;
  String? _email;
  String? _password;

  bool get isLoggedIn => _token != null;

  /// SHA-256 hex (lowercase) of the user id, sent as `Account-Id`.
  static String accountIdHash(String userId) =>
      sha256.convert(utf8.encode(userId)).toString();

  Map<String, String> get _headers => {
    'product': libreLinkUpProduct,
    'version': libreLinkUpVersion,
    'Content-Type': 'application/json',
    'Authorization': ?(_token == null ? null : 'Bearer $_token'),
    'Account-Id': ?_accountId,
  };

  /// Logs in and remembers credentials in memory for silent re-login.
  Future<void> login(String email, String password) async {
    _email = email;
    _password = password;
    _token = null;
    _accountId = null;
    var data = await _postLogin();
    if (data['redirect'] == true) {
      _baseUrl = 'https://api-${data['region']}.libreview.io';
      data = await _postLogin();
    }
    final ticket = data['authTicket'] as Map<String, dynamic>?;
    final userId = (data['user'] as Map<String, dynamic>?)?['id'] as String?;
    if (ticket == null || userId == null) {
      throw LibreLinkUpException(
        'Login rejected (bad credentials or terms not accepted)',
      );
    }
    _token = ticket['token'] as String;
    _accountId = accountIdHash(userId);
  }

  Future<Map<String, dynamic>> _postLogin() async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/llu/auth/login'),
      headers: _headers,
      body: jsonEncode({'email': _email, 'password': _password}),
    );
    final data = _decode(res);
    return data is Map<String, dynamic> ? data : {};
  }

  Future<List<Connection>> getConnections() async {
    final data = await _get('/llu/connections');
    if (data is! List) throw _unexpected('/llu/connections', data);
    return data
        .whereType<Map<String, dynamic>>()
        .map(Connection.fromJson)
        .toList();
  }

  /// The followed patient, or a readable error when the account follows nobody.
  Future<Connection> firstConnection() async {
    final connections = await getConnections();
    if (connections.isEmpty) {
      throw LibreLinkUpException(
        'Aucun profil suivi sur ce compte LibreLinkUp',
      );
    }
    return connections.first;
  }

  LibreLinkUpException _unexpected(String path, Object? data) =>
      LibreLinkUpException('Réponse inattendue de $path : $data');

  Future<GlucoseGraph> getGraph(String patientId) async {
    final data = await _get('/llu/connections/$patientId/graph');
    if (data is! Map<String, dynamic>) throw _unexpected('graph', data);
    return GlucoseGraph.fromJson(data);
  }

  /// GET with one silent re-login on 401/403.
  Future<dynamic> _get(String path) async {
    var res = await _client.get(Uri.parse('$_baseUrl$path'), headers: _headers);
    if ((res.statusCode == 401 || res.statusCode == 403) && _email != null) {
      await login(_email!, _password!);
      res = await _client.get(Uri.parse('$_baseUrl$path'), headers: _headers);
    }
    return _decode(res);
  }

  /// Returns `data` from the response envelope.
  dynamic _decode(http.Response res) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final body = res.body.length > 200
          ? res.body.substring(0, 200)
          : res.body;
      throw LibreLinkUpException(
        '${res.request?.method} ${res.request?.url.path} -> HTTP ${res.statusCode} $body',
        statusCode: res.statusCode,
      );
    }
    final body = jsonDecode(res.body);
    return body is Map<String, dynamic> ? body['data'] : null;
  }
}
