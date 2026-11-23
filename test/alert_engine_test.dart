import 'package:flutter_test/flutter_test.dart';
import 'package:libre_glance/models/alerts.dart';
import 'package:libre_glance/models/glucose.dart';
import 'package:libre_glance/models/thresholds.dart';
import 'package:libre_glance/services/alert_engine.dart';

final _now = DateTime(2026, 1, 1, 12);

GlucoseMeasurement _m(
  int v, {
  Trend t = Trend.stable,
  int ageMin = 1,
  DateTime? at,
}) => GlucoseMeasurement(
  value: v,
  trend: t,
  timestamp: (at ?? _now).subtract(Duration(minutes: ageMin)),
);

List<AlertKind> _fire(
  GlucoseMeasurement m, {
  AlertSettings s = const AlertSettings(),
  AlertState st = const AlertState(),
  DateTime? now,
}) => evaluate(
  m: m,
  thresholds: const Thresholds(),
  settings: s,
  state: st,
  now: now ?? _now,
).fire;

void main() {
  test('in range fires nothing', () => expect(_fire(_m(120)), isEmpty));

  test('low fires; urgent low supersedes low', () {
    expect(_fire(_m(65)), [AlertKind.low]);
    expect(_fire(_m(50)), [AlertKind.urgentLow]);
  });

  test('with urgent low disabled, a very low value is a plain low', () {
    expect(_fire(_m(50), s: const AlertSettings(urgentLowEnabled: false)), [
      AlertKind.low,
    ]);
  });

  test('each alert can be disabled', () {
    expect(_fire(_m(65), s: const AlertSettings(lowEnabled: false)), isEmpty);
    expect(_fire(_m(200)), isEmpty); // high is off by default
    expect(_fire(_m(200), s: const AlertSettings(highEnabled: true)), [
      AlertKind.high,
    ]);
    expect(
      _fire(_m(120, ageMin: 30), s: const AlertSettings(staleEnabled: false)),
      isEmpty,
    );
  });

  test('stale data alert uses the configured delay', () {
    expect(_fire(_m(120, ageMin: 14)), isEmpty);
    expect(_fire(_m(120, ageMin: 15)), [AlertKind.stale]);
  });

  test('fast fall only when approaching the low threshold', () {
    expect(_fire(_m(95, t: Trend.fallingFast)), [AlertKind.fastFall]);
    expect(_fire(_m(150, t: Trend.fallingFast)), isEmpty);
  });

  test('repeats only after the cooldown, and resets when back in range', () {
    final first = evaluate(
      m: _m(65),
      thresholds: const Thresholds(),
      settings: const AlertSettings(),
      state: const AlertState(),
      now: _now,
    );
    final st = AlertState(lastFired: first.lastFired);
    expect(
      _fire(
        _m(65, at: _now.add(const Duration(minutes: 10))),
        st: st,
        now: _now.add(const Duration(minutes: 10)),
      ),
      isEmpty,
    );
    expect(
      _fire(
        _m(65, at: _now.add(const Duration(minutes: 15))),
        st: st,
        now: _now.add(const Duration(minutes: 15)),
      ),
      [AlertKind.low],
    );

    final back = evaluate(
      m: _m(120),
      thresholds: const Thresholds(),
      settings: const AlertSettings(),
      state: st,
      now: _now.add(const Duration(minutes: 5)),
    );
    expect(back.lastFired, isEmpty);
  });

  test('snooze mutes everything except urgent low', () {
    final st = AlertState(snoozeUntil: _now.add(const Duration(minutes: 30)));
    expect(_fire(_m(65), st: st), isEmpty);
    expect(_fire(_m(50), st: st), [AlertKind.urgentLow]);
    expect(
      _fire(
        _m(65, at: _now.add(const Duration(minutes: 31))),
        st: st,
        now: _now.add(const Duration(minutes: 31)),
      ),
      [AlertKind.low],
    );
  });

  test('state and settings survive a JSON round trip', () {
    final s = const AlertSettings().with_({
      'staleMinutes': 25,
      'highEnabled': true,
    });
    expect(AlertSettings.fromJson(s.toJson()).staleMinutes, 25);
    final st = AlertState(lastFired: {AlertKind.low: _now}, snoozeUntil: _now);
    expect(AlertState.fromJson(st.toJson()).lastFired[AlertKind.low], _now);
  });
}
