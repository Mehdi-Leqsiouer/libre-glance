import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/glucose.dart';
import '../models/thresholds.dart';

/// Last 4h curve; x = hours before now (-4..0), green band = target range.
class GlucoseChart extends StatelessWidget {
  const GlucoseChart({
    super.key,
    required this.points,
    required this.thresholds,
  });
  final List<GlucoseMeasurement> points;
  final Thresholds thresholds;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final spots = [
      for (final p in points)
        FlSpot(
          -now.difference(p.timestamp).inSeconds / 3600,
          p.value.toDouble(),
        ),
    ];
    final maxY = [
      thresholds.max + 40,
      ...points.map((p) => p.value + 20),
    ].reduce((a, b) => a > b ? a : b).toDouble();
    return AspectRatio(
      aspectRatio: 1.7,
      child: LineChart(
        LineChartData(
          minX: -4,
          maxX: 0,
          minY: 40,
          maxY: maxY,
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: 1,
                getTitlesWidget: (v, _) => Text(
                  v == 0 ? 'now' : '${v.toInt()}h',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ),
            leftTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: true, reservedSize: 36),
            ),
          ),
          rangeAnnotations: RangeAnnotations(
            horizontalRangeAnnotations: [
              HorizontalRangeAnnotation(
                y1: thresholds.min.toDouble(),
                y2: thresholds.max.toDouble(),
                color: Colors.green.withValues(alpha: 0.15),
              ),
            ],
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              barWidth: 3,
              dotData: const FlDotData(show: false),
            ),
          ],
        ),
      ),
    );
  }
}
