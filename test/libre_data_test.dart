import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:libre_glance/models/alerts.dart';
import 'package:libre_glance/models/glucose.dart';
import 'package:libre_glance/models/thresholds.dart';
import 'package:libre_glance/services/alert_service.dart';
import 'package:libre_glance/services/librelinkup_service.dart';
import 'package:libre_glance/services/storage_service.dart';

const _rules = {
  'l': {'th': 60},
  'h': {'th': 240},
  'f': {'th': 55},
  'c': true,
};

void main() {
  group('LibreLink alarm thresholds', () {
    test('are read from alarmRules, defensively', () {
      final a = LibreAlarms.fromRules(_rules)!;
      expect((a.low, a.high, a.urgentLow), (60, 240, 55));
      expect(LibreAlarms.fromRules({'c': true}), isNull);
      expect(LibreAlarms.fromRules(null), isNull);
      expect(
        LibreAlarms.fromRules({
          'l': {'th': 60.4},
        })!.low,
        60,
      );
    });

    test('replace the own thresholds only when chosen', () {
      const own = Thresholds(min: 70, max: 180);
      const libre = LibreAlarms(low: 60, high: 240, urgentLow: 55);

      final off = effectiveAlerts(own, const AlertSettings(), libre);
      expect((off.thresholds.min, off.thresholds.max), (70, 180));

      final on = effectiveAlerts(
        own,
        const AlertSettings(useLibreThresholds: true),
        libre,
      );
      expect((on.thresholds.min, on.thresholds.max), (60, 240));
      expect(on.settings.urgentLow, 55);
    });

    test('fall back to the own values for what LibreLink does not give', () {
      const own = Thresholds(min: 70, max: 180);
      const settings = AlertSettings(useLibreThresholds: true, urgentLow: 50);

      final unknown = effectiveAlerts(own, settings, null);
      expect((unknown.thresholds.min, unknown.settings.urgentLow), (70, 50));

      final partial = effectiveAlerts(
        own,
        settings,
        const LibreAlarms(low: 65),
      );
      expect((partial.thresholds.min, partial.thresholds.max), (65, 180));
      expect(partial.settings.urgentLow, 50);
    });

    test('change what the local alerts consider low', () async {
      var shown = 0;
      Future<int> alertsAt({required bool libreChosen}) async {
        FlutterSecureStorage.setMockInitialValues({
          if (libreChosen) 'alert_settings': '{"useLibreThresholds":true}',
        });
        shown = 0;
        final service = AlertService(
          StorageService(),
          (kind, title, body, {critical = false}) async => shown++,
        );
        final reading = GlucoseMeasurement(
          value: 65,
          trend: Trend.stable,
          timestamp: DateTime.now(),
        );
        await service.check(
          reading,
          const Thresholds(),
          'Ada',
          libre: const LibreAlarms(low: 60, high: 240, urgentLow: 55),
        );
        return shown;
      }

      expect(await alertsAt(libreChosen: false), greaterThan(0)); // 65 < 70
      expect(await alertsAt(libreChosen: true), 0); // 65 >= LibreLink's 60
    });
  });

  group('sensor warm-up', () {
    GlucoseGraph graphWith({
      required DateTime activated,
      int? warmupMinutes,
      bool withMeasurement = false,
    }) => GlucoseGraph.fromJson({
      'connection': {
        'glucoseMeasurement': ?(withMeasurement
            ? {
                'Value': 100,
                'Timestamp': '11/23/2026 4:05:09 PM',
                'FactoryTimestamp': '11/23/2026 3:05:09 PM',
              }
            : null),
        'alarmRules': _rules,
      },
      'activeSensors': [
        {
          'sensor': {
            'a': activated.millisecondsSinceEpoch ~/ 1000,
            'w': ?warmupMinutes,
          },
        },
      ],
      'graphData': <dynamic>[],
    });

    test('counts down from the activation, 60 minutes by default', () {
      final now = DateTime(2026, 11, 27, 12);
      final g = graphWith(activated: now.subtract(const Duration(minutes: 20)));
      expect(g.warmupLeft(now: now), const Duration(minutes: 40));
      expect(g.alarms!.low, 60);
    });

    test('ends after sensor.w minutes', () {
      final now = DateTime(2026, 11, 27, 12);
      final done = graphWith(
        activated: now.subtract(const Duration(minutes: 61)),
      );
      expect(done.warmupLeft(now: now), isNull);

      final custom = graphWith(
        activated: now.subtract(const Duration(minutes: 61)),
        warmupMinutes: 90,
      );
      expect(custom.warmupLeft(now: now), const Duration(minutes: 29));
    });

    test('is unknown without a sensor date', () {
      final g = GlucoseGraph.fromJson({'graphData': <dynamic>[]});
      expect(g.warmupLeft(), isNull);
    });
  });

  group('alarm journal', () {
    Map<String, dynamic> entry(int value, {int? alarmType, String? time}) => {
      'Value': value,
      'TrendArrow': 3,
      'Timestamp': time ?? '11/20/2026 4:05:09 PM',
      'FactoryTimestamp': time ?? '11/20/2026 3:05:09 PM',
      'alarmType': ?alarmType,
    };

    test('keeps the alarms, newest first, and tells low from high', () {
      final events = [
        AlarmEvent.tryFromJson(entry(64, alarmType: 1)),
        AlarmEvent.tryFromJson(entry(300, alarmType: 2)),
        AlarmEvent.tryFromJson(entry(100)), // not an alarm
        AlarmEvent.tryFromJson(entry(80, alarmType: 9)),
      ];
      expect(events[0]!.kind, AlarmKind.low);
      expect(events[1]!.kind, AlarmKind.high);
      expect(events[2], isNull);
      expect(events[3]!.kind, AlarmKind.other);
    });

    LibreLinkUpService serviceReturning(Object data) => LibreLinkUpService(
      client: MockClient((req) async {
        if (req.url.path.endsWith('/login')) {
          return http.Response(
            '{"data":{"user":{"id":"u"},"authTicket":{"token":"t"}}}',
            200,
          );
        }
        return http.Response(jsonEncode({'data': data}), 200);
      }),
    );

    test('is fetched from the logbook, as a map or a list', () async {
      final newer = entry(60, alarmType: 1, time: '11/25/2026 3:05:09 PM');
      final older = entry(250, alarmType: 2);
      for (final data in [
        {
          'entries': [older, entry(100), newer],
        },
        [older, entry(100), newer],
      ]) {
        final service = serviceReturning(data);
        await service.login('a', 'b');
        final events = await service.getAlarmEvents('p');
        expect(events.map((e) => e.value), [60, 250]);
      }
    });

    test('an unexpected payload is a readable error', () async {
      final service = serviceReturning(<String, dynamic>{'oops': 1});
      await service.login('a', 'b');
      expect(service.getAlarmEvents('p'), throwsA(isA<LibreLinkUpException>()));
    });
  });
}
