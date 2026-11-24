import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libre_glance/models/alerts.dart';
import 'package:libre_glance/models/glucose.dart';
import 'package:libre_glance/models/stats.dart';
import 'package:libre_glance/models/thresholds.dart';
import 'package:libre_glance/services/alert_engine.dart';
import 'package:libre_glance/services/history_store.dart';

GlucoseMeasurement _m(int v, DateTime t) =>
    GlucoseMeasurement(value: v, trend: Trend.stable, timestamp: t);

void main() {
  final now = DateTime(2026, 1, 10, 12);

  test(
    'history: 15 min bins (latest wins), window filter, 30 day pruning',
    () async {
      final dir = Directory.systemTemp.createTempSync('hist');
      final store = HistoryStore(file: File('${dir.path}/h.json'));
      final t = DateTime(2026, 1, 10, 11, 0);
      await store.add([
        _m(100, t),
        _m(110, t.add(const Duration(minutes: 5))), // same bin: replaces 100
        _m(90, t.subtract(const Duration(days: 40))), // too old: pruned
        _m(120, t.subtract(const Duration(hours: 5))),
      ], now: now);
      final day = await store.since(const Duration(hours: 24), now: now);
      expect(day.map((r) => r.value), [120, 110]);
      expect(
        await store.since(const Duration(hours: 2), now: now),
        hasLength(1),
      );
      expect((await store.since(const Duration(days: 60), now: now)).length, 2);
      dir.deleteSync(recursive: true);
    },
  );

  test('stats: time in range, mean, coverage', () {
    final rs = <Reading>[
      for (final v in [60, 100, 120, 200]) (time: now, value: v),
    ];
    final s = computeStats(rs, const Thresholds(), const Duration(hours: 1))!;
    expect(s.mean, 120);
    expect(s.lowPct, 25);
    expect(s.inRangePct, 50);
    expect(s.highPct, 25);
    expect(s.min, 60);
    expect(s.max, 200);
    expect(s.coveragePct, 100); // 4 readings for 4 slots of 15 min
    expect(
      computeStats([], const Thresholds(), const Duration(hours: 1)),
      isNull,
    );
  });

  test('sensor expiry alert: only in the last 24 h, can be disabled', () {
    List<AlertKind> fire(
      Duration afterStart, {
      AlertSettings s = const AlertSettings(),
    }) {
      final start = DateTime(2026, 1, 1);
      final at = start.add(afterStart);
      return evaluate(
        m: _m(120, at.subtract(const Duration(minutes: 1))),
        thresholds: const Thresholds(),
        settings: s,
        state: const AlertState(),
        now: at,
        sensorStart: start,
      ).fire;
    }

    expect(fire(const Duration(days: 12)), isEmpty);
    expect(fire(const Duration(days: 13, hours: 1)), [AlertKind.sensorExpiry]);
    expect(fire(const Duration(days: 14, hours: 1)), [AlertKind.sensorExpiry]);
    expect(fire(const Duration(days: 14, hours: 13)), isEmpty);
    expect(
      fire(
        const Duration(days: 13, hours: 1),
        s: const AlertSettings(sensorEnabled: false),
      ),
      isEmpty,
    );
    expect(
      fire(
        const Duration(days: 13, hours: 1),
        s: const AlertSettings(sensorDays: 15),
      ),
      isEmpty,
    );
  });

  test('graph payload exposes the sensor activation date', () {
    final g = GlucoseGraph.fromJson({
      'activeSensors': [
        {
          'sensor': {'a': 1700000000},
        },
      ],
      'graphData': [],
    });
    expect(
      g.sensorActivatedAt,
      DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
    );
    expect(GlucoseGraph.fromJson({'graphData': []}).sensorActivatedAt, isNull);
  });
}
