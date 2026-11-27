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

  final registered = {
    'email': 'Ada@Example.com',
    'password': 'pw',
    'activity_token': 'tok123',
    'min': '65',
    'max': '170',
  };

  test('derived key matches the server formula (sha256, normalized email)', () {
    // printf 'libreglance:ada@example.com:pw' | shasum -a 256; same input as server/tests/test_api.py
    const expected =
        'df4365b6456ca98cc2d147c6f7ab9f73b6bc733af409aa86076091787f3ef5e2';
    expect(deriveKey(' Ada@Example.com ', 'pw'), expected);
    expect(deriveKey('ada@example.com', 'other'), isNot(expected));
  });

  test('registers the token with the thresholds and the derived key', () async {
    late http.Request sent;
    final registrar = PushRegistrar(
      await storage(registered),
      client: MockClient((req) async {
        sent = req;
        return http.Response('{}', 200);
      }),
      serverUrl: 'https://api.example.run.app',
    );

    expect(await registrar.sync(), isNull);
    expect(sent.url.toString(), 'https://api.example.run.app/register');
    expect(sent.headers['X-Api-Key'], deriveKey('ada@example.com', 'pw'));
    expect(jsonDecode(sent.body), {
      'activity_token': 'tok123',
      'min_target': 65,
      'max_target': 170,
    });
  });

  test('does nothing until credentials and a token are known', () async {
    var calls = 0;
    final registrar = PushRegistrar(
      await storage({'email': 'a@b.c', 'password': 'pw'}),
      client: MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    expect(await registrar.sync(), isNull);
    expect(calls, 0);
  });

  test('onToken registers once per token', () async {
    var calls = 0;
    final registrar = PushRegistrar(
      await storage({'email': 'a@b.c', 'password': 'pw'}),
      client: MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    await registrar.onToken('tok-one-12345');
    await registrar.onToken('tok-one-12345');
    await registrar.onToken('tok-two-12345');
    expect(calls, 2);
  });

  test('reports a rejected key and an unreachable server', () async {
    final rejected = PushRegistrar(
      await storage(registered),
      client: MockClient((_) async => http.Response('', 401)),
    );
    expect(await rejected.sync(), contains('401'));

    final offline = PushRegistrar(
      await storage(registered),
      client: MockClient((_) async => throw http.ClientException('no route')),
    );
    expect(await offline.sync(), contains('injoignable'));
  });
}
