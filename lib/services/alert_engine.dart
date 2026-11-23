import '../models/alerts.dart';
import '../models/glucose.dart';
import '../models/thresholds.dart';

/// Minutes before the same alert may fire again while its condition persists.
const Map<AlertKind, int> repeatEveryMinutes = {
  AlertKind.urgentLow: 5,
  AlertKind.low: 15,
  AlertKind.fastFall: 15,
  AlertKind.high: 60,
  AlertKind.stale: 30,
};

/// Pure decision: which alerts to fire now, and the new `lastFired` map.
///
/// - An urgent low supersedes the plain low alert.
/// - A condition that clears is forgotten, so its next occurrence fires at once.
/// - Snooze mutes everything except the urgent low.
({List<AlertKind> fire, Map<AlertKind, DateTime> lastFired}) evaluate({
  required GlucoseMeasurement m,
  required Thresholds thresholds,
  required AlertSettings settings,
  required AlertState state,
  required DateTime now,
}) {
  final active = <AlertKind>{
    if (settings.urgentLowEnabled && m.value < settings.urgentLow)
      AlertKind.urgentLow
    else if (settings.lowEnabled && m.value < thresholds.min)
      AlertKind.low,
    if (settings.fastFallEnabled &&
        m.trend == Trend.fallingFast &&
        m.value >= thresholds.min &&
        m.value <= thresholds.min + 30)
      AlertKind.fastFall,
    if (settings.highEnabled && m.value > thresholds.max) AlertKind.high,
    if (settings.staleEnabled &&
        now.difference(m.timestamp).inMinutes >= settings.staleMinutes)
      AlertKind.stale,
  };

  final snoozed = state.snoozeUntil != null && now.isBefore(state.snoozeUntil!);
  final fire = <AlertKind>[
    for (final k in active)
      if ((!snoozed || k == AlertKind.urgentLow) &&
          (state.lastFired[k] == null ||
              now.difference(state.lastFired[k]!).inMinutes >=
                  repeatEveryMinutes[k]!))
        k,
  ];

  return (
    fire: fire,
    lastFired: {
      for (final k in active)
        if (state.lastFired[k] != null) k: state.lastFired[k]!,
      for (final k in fire) k: now,
    },
  );
}
