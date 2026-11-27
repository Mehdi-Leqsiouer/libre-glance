import 'package:flutter/material.dart';

import 'alerts.dart';
import 'glucose.dart';

enum GlucoseStatus {
  low('Bas', Colors.red),
  inRange('Dans la cible', Colors.green),
  high('Élevé', Colors.orange);

  const GlucoseStatus(this.label, this.color);
  final String label;
  final Color color;
}

class Thresholds {
  const Thresholds({this.min = 70, this.max = 180});
  final int min;
  final int max;

  GlucoseStatus statusOf(int value) => value < min
      ? GlucoseStatus.low
      : value > max
      ? GlucoseStatus.high
      : GlucoseStatus.inRange;
}

/// The thresholds actually in force: the user's own, or LibreLink's when chosen and known.
/// A value LibreLink does not give falls back to the user's own.
({Thresholds thresholds, AlertSettings settings}) effectiveAlerts(
  Thresholds own,
  AlertSettings settings,
  LibreAlarms? libre,
) {
  if (!settings.useLibreThresholds || libre == null) {
    return (thresholds: own, settings: settings);
  }
  return (
    thresholds: Thresholds(
      min: libre.low ?? own.min,
      max: libre.high ?? own.max,
    ),
    settings: libre.urgentLow == null
        ? settings
        : settings.with_({'urgentLow': libre.urgentLow}),
  );
}
