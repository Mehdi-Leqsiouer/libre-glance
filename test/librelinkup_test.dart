import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:libre_glance/models/glucose.dart';
import 'package:libre_glance/services/librelinkup_service.dart';

http.Response _json(Object data, [int code = 200]) =>
    http.Response(jsonEncode({'status': 0, 'data': data}), code);

Map<String, dynamic> _login(String id) => {
  'user': {'id': id},
  'authTicket': {'token': 'tok-$id', 'expires': 1},
};

const _m = {
  'Value': 126,
  'TrendArrow': 4,
  'Timestamp': '11/23/2026 4:05:09 PM',
};

void main() {
  test('parses LibreView timestamps (AM/PM, no zero padding)', () {
    expect(
      parseLibreTimestamp('11/23/2026 4:05:09 PM'),
      DateTime(2026, 11, 23, 16, 5, 9),
    );
    expect(
      parseLibreTimestamp('1/2/2026 12:00:00 AM'),
      DateTime(2026, 1, 2, 0, 0, 0),
    );
    expect(
      parseLibreTimestamp('1/2/2026 12:30:00 PM'),
      DateTime(2026, 1, 2, 12, 30, 0),
    );
  });

  test('trend mapping incl. unknown fallback', () {
    expect(Trend.fromApi(1), Trend.fallingFast);
    expect(Trend.fromApi(5).arrow, '↑↑');
    expect(Trend.fromApi(0), Trend.stable);
    expect(Trend.fromApi(null), Trend.stable);
  });

  test('Account-Id is lowercase sha256 hex', () {
    expect(
      LibreLinkUpService.accountIdHash('abc'),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  test(
    'login sends headers, follows region redirect, then sends Account-Id',
    () async {
      final seen = <http.Request>[];
      final svc = LibreLinkUpService(
        client: MockClient((req) async {
          seen.add(req);
          if (req.url.host == 'api-eu.libreview.io' &&
              req.url.path == '/llu/auth/login') {
            return _json({'redirect': true, 'region': 'fr'});
          }
          if (req.url.path == '/llu/auth/login') return _json(_login('abc'));
          return _json([
            {
              'patientId': 'p1',
              'firstName': 'Ada',
              'lastName': 'L',
              'glucoseMeasurement': _m,
            },
          ]);
        }),
      );
      await svc.login('a@b.c', 'pw');
      final conns = await svc.getConnections();

      expect(seen[1].url.host, 'api-fr.libreview.io');
      expect(seen[0].headers['product'], 'llu.ios');
      expect(seen[0].headers['version'], libreLinkUpVersion);
      expect(jsonDecode(seen[0].body), {'email': 'a@b.c', 'password': 'pw'});
      expect(seen.last.headers['Authorization'], 'Bearer tok-abc');
      expect(
        seen.last.headers['Account-Id'],
        LibreLinkUpService.accountIdHash('abc'),
      );
      expect(conns.single.name, 'Ada L');
      expect(conns.single.current!.value, 126);
      expect(conns.single.current!.trend, Trend.rising);
    },
  );

  test('login without authTicket throws', () {
    final svc = LibreLinkUpService(client: MockClient((_) async => _json({})));
    expect(svc.login('a', 'b'), throwsA(isA<LibreLinkUpException>()));
  });

  test('graph parsing sorts history and filters last 4h', () async {
    final svc = LibreLinkUpService(
      client: MockClient((req) async {
        if (req.url.path.endsWith('/login')) return _json(_login('u'));
        return _json({
          'connection': {'glucoseMeasurement': _m},
          'graphData': [
            {
              'Value': 100,
              'TrendArrow': 3,
              'Timestamp': '11/23/2026 3:00:00 PM',
            },
            {
              'Value': 90,
              'TrendArrow': 3,
              'Timestamp': '11/23/2026 10:00:00 AM',
            },
          ],
        });
      }),
    );
    await svc.login('a', 'b');
    final g = await svc.getGraph('p1');
    expect(g.current!.value, 126);
    expect(g.history.first.value, 90);
    final recent = g.last(
      const Duration(hours: 4),
      now: DateTime(2026, 11, 23, 16, 10),
    );
    expect(recent.map((e) => e.value), [100]);
  });

  test('silent re-login on 401 then retry', () async {
    var logins = 0;
    var gets = 0;
    final svc = LibreLinkUpService(
      client: MockClient((req) async {
        if (req.url.path.endsWith('/login')) {
          logins++;
          return _json(_login('u'));
        }
        return ++gets == 1 ? http.Response('', 401) : _json([]);
      }),
    );
    await svc.login('a', 'b');
    expect(await svc.getConnections(), isEmpty);
    expect(logins, 2);
  });
}
