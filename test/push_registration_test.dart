import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:libre_glance/models/alerts.dart';
import 'package:libre_glance/models/glucose.dart';
import 'package:libre_glance/models/thresholds.dart';
import 'package:libre_glance/services/alert_service.dart';
import 'package:libre_glance/services/push_registration.dart';
import 'package:libre_glance/services/storage_service.dart';

void main() {
  Future<StorageService> storage(Map<String, String> initial) async {
    // A copy: the mock keeps the map and would mutate the shared fixtures.
    FlutterSecureStorage.setMockInitialValues({...initial});
    return StorageService();
  }

  final registered = {
    'email': 'Ada@Example.com',
    'password': 'pw',
    'activity_token': 'tok123',
    'min': '65',
    'max': '170',
  };

  /// A registrar whose HTTP calls are recorded; every call answers [status].
  (PushRegistrar, List<http.Request>) registrarOf(
    StorageService s, {
    int status = 200,
  }) {
    final sent = <http.Request>[];
    final registrar = PushRegistrar(
      s,
      client: MockClient((req) async {
        sent.add(req);
        return http.Response('{}', status);
      }),
      serverUrl: 'https://api.example.run.app',
    );
    return (registrar, sent);
  }

  test('derived key matches the server formula (sha256, normalized email)', () {
    // printf 'libreglance:ada@example.com:pw' | shasum -a 256; same input as server/tests/test_api.py
    const expected =
        'df4365b6456ca98cc2d147c6f7ab9f73b6bc733af409aa86076091787f3ef5e2';
    expect(deriveKey(' Ada@Example.com ', 'pw'), expected);
    expect(deriveKey('ada@example.com', 'other'), isNot(expected));
  });

  test(
    'registers tokens, thresholds, settings and the restart choice',
    () async {
      final s = await storage({
        ...registered,
        'push_to_start_token': 'pts456',
        'device_token': 'dev789',
        'auto_restart': '0',
        'alert_settings': jsonEncode(
          const AlertSettings(staleMinutes: 25, criticalEnabled: true).toJson(),
        ),
      });
      final (registrar, sent) = registrarOf(s);

      expect(await registrar.sync(), isNull);

      final req = sent.single;
      expect(req.url.toString(), 'https://api.example.run.app/register');
      expect(req.headers['X-Api-Key'], deriveKey('ada@example.com', 'pw'));
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['activity_token'], 'tok123');
      expect(body['push_to_start_token'], 'pts456');
      expect(body['device_token'], 'dev789');
      expect(body['min_target'], 65);
      expect(body['max_target'], 170);
      expect(body['auto_restart'], false);
      expect((body['settings'] as Map)['staleMinutes'], 25);
      expect((body['settings'] as Map)['criticalEnabled'], true);
    },
  );

  test('only sends the tokens it has', () async {
    final s = await storage({
      'email': 'a@b.c',
      'password': 'pw',
      'device_token': 'dev789',
    });
    final (registrar, sent) = registrarOf(s);

    await registrar.sync();

    final body = jsonDecode(sent.single.body) as Map<String, dynamic>;
    expect(body.containsKey('activity_token'), isFalse);
    expect(body.containsKey('push_to_start_token'), isFalse);
    expect(body['device_token'], 'dev789');
  });

  test('does nothing until credentials and a token are known', () async {
    final (registrar, sent) = registrarOf(
      await storage({'email': 'a@b.c', 'password': 'pw'}),
    );
    expect(await registrar.sync(), isNull);
    expect(sent, isEmpty);

    final (noCredentials, sentWithout) = registrarOf(
      await storage({'device_token': 'dev789'}),
    );
    expect(await noCredentials.sync(), isNull);
    expect(sentWithout, isEmpty);
  });

  test('each token is registered once, and again when it changes', () async {
    final s = await storage({'email': 'a@b.c', 'password': 'pw'});
    final (registrar, sent) = registrarOf(s);

    await registrar.onToken('activity-one-1');
    await registrar.onToken('activity-one-1');
    await registrar.onToken('activity-two-2');
    await registrar.onPushToStartToken('pts-one-1');
    await registrar.onDeviceToken('device-one-1');

    expect(sent, hasLength(4));
    expect(await s.readPushToStartToken(), 'pts-one-1');
    expect(await s.readDeviceToken(), 'device-one-1');
  });

  test('server alerts take over once the device token is registered', () async {
    final s = await storage({'email': 'a@b.c', 'password': 'pw'});
    final (registrar, _) = registrarOf(s);

    await registrar.onToken('activity-one-1');
    expect(await s.readFlag(serverAlertsFlag), isFalse);

    await registrar.onDeviceToken('device-one-1');
    expect(await s.readFlag(serverAlertsFlag), isTrue);
  });

  test('a rejected registration does not hand the alerts over', () async {
    final s = await storage({'email': 'a@b.c', 'password': 'pw'});
    final (registrar, _) = registrarOf(s, status: 401);

    await registrar.onDeviceToken('device-one-1');

    expect(await s.readFlag(serverAlertsFlag), isFalse);
  });

  test('unregister forgets the activity token and tells the server', () async {
    final s = await storage(registered);
    final (registrar, sent) = registrarOf(s);

    expect(await registrar.unregister(), isNull);

    expect(sent.single.url.path, '/unregister');
    expect(await s.readActivityToken(), isNull);
  });

  test('snooze sends the minutes, and zero to clear it', () async {
    final (registrar, sent) = registrarOf(await storage(registered));

    await registrar.snooze(const Duration(minutes: 30));
    await registrar.snooze(null);

    expect(sent.map((r) => r.url.path), ['/snooze', '/snooze']);
    expect(jsonDecode(sent[0].body), {'minutes': 30});
    expect(jsonDecode(sent[1].body), {'minutes': 0});
  });

  test('reports a rejected key and an unreachable server', () async {
    final (rejected, _) = registrarOf(await storage(registered), status: 401);
    expect(await rejected.sync(), contains('401'));

    final offline = PushRegistrar(
      await storage(registered),
      client: MockClient((_) async => throw http.ClientException('no route')),
    );
    expect(await offline.sync(), contains('injoignable'));
  });

  group('local alerts', () {
    final low = GlucoseMeasurement(
      value: 50,
      trend: Trend.stable,
      timestamp: DateTime.now(),
    );

    Future<int> shown(Map<String, String> values) async {
      var count = 0;
      final service = AlertService(
        await storage(values),
        (kind, title, body, {critical = false}) async => count++,
      );
      await service.check(low, const Thresholds(), 'Ada');
      return count;
    }

    test('fire in the app until the server takes over', () async {
      expect(await shown({}), greaterThan(0));
    });

    test('stay silent once the server sends the alerts', () async {
      expect(await shown({serverAlertsFlag: '1'}), 0);
    });
  });
}
