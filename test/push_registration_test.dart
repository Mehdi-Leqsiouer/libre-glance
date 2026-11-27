import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:libre_glance/services/push_registration.dart';
import 'package:libre_glance/services/storage_service.dart';

void main() {
  Future<StorageService> storage(Map<String, String> initial) async {
    FlutterSecureStorage.setMockInitialValues(initial);
    return StorageService();
  }

  test('registers the token with the thresholds and the API key', () async {
    late http.Request sent;
    final registrar = PushRegistrar(
      await storage({
        'server_url': 'https://api.example.run.app/',
        'server_key': 'secret',
        'activity_token': 'tok123',
        'min': '65',
        'max': '170',
      }),
      MockClient((req) async {
        sent = req;
        return http.Response('{}', 200);
      }),
    );

    expect(await registrar.sync(), isNull);
    expect(sent.url.toString(), 'https://api.example.run.app/register');
    expect(sent.headers['X-Api-Key'], 'secret');
    expect(jsonDecode(sent.body), {
      'activity_token': 'tok123',
      'min_target': 65,
      'max_target': 170,
    });
  });

  test('does nothing until both a server and a token are known', () async {
    var calls = 0;
    final registrar = PushRegistrar(
      await storage({'server_url': 'https://x', 'server_key': 'k'}),
      MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    expect(await registrar.sync(), isNull);
    expect(calls, 0);
  });

  test('reports a rejected key and an unreachable server', () async {
    final values = {
      'server_url': 'https://x',
      'server_key': 'bad',
      'activity_token': 'tok',
    };
    final rejected = PushRegistrar(
      await storage(values),
      MockClient((_) async => http.Response('', 401)),
    );
    expect(await rejected.sync(), contains('401'));

    final offline = PushRegistrar(
      await storage(values),
      MockClient((_) async => throw http.ClientException('no route')),
    );
    expect(await offline.sync(), contains('injoignable'));
  });
}
