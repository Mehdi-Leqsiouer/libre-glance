import 'dart:math';

import '../services/history_store.dart';
import 'thresholds.dart';

class GlucoseStats {
  const GlucoseStats({
    required this.count,
    required this.mean,
    required this.sd,
    required this.min,
    required this.max,
    required this.lowPct,
    required this.inRangePct,
    required this.highPct,
    required this.coveragePct,
  });

  final int count;
  final double mean;
  final double sd;
  final int min;
  final int max;
  final double lowPct;
  final double inRangePct;
  final double highPct;

  /// Share of the 15 min slots of the window that have a reading.
  final double coveragePct;

  /// Coefficient of variation, in %.
  double get cv => mean == 0 ? 0 : sd / mean * 100;
}

GlucoseStats? computeStats(
  List<Reading> readings,
  Thresholds t,
  Duration window,
) {
  if (readings.isEmpty) return null;
  final values = [for (final r in readings) r.value];
  final n = values.length;
  final mean = values.reduce((a, b) => a + b) / n;
  final variance = values.fold<double>(0, (s, v) => s + pow(v - mean, 2)) / n;
  double pct(bool Function(int) test) => values.where(test).length / n * 100;
  final slots = window.inMinutes / 15;
  return GlucoseStats(
    count: n,
    mean: mean,
    sd: sqrt(variance),
    min: values.reduce(min),
    max: values.reduce(max),
    lowPct: pct((v) => v < t.min),
    inRangePct: pct((v) => v >= t.min && v <= t.max),
    highPct: pct((v) => v > t.max),
    coveragePct: min(100, n / slots * 100),
  );
}
