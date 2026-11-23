import 'package:flutter/material.dart';

import '../models/glucose.dart';
import '../models/thresholds.dart';

String ageLabel(DateTime t, {DateTime? now}) {
  final m = (now ?? DateTime.now()).difference(t).inMinutes;
  if (m < 1) return "à l'instant";
  if (m < 60) return 'il y a $m min';
  return 'il y a ${m ~/ 60} h ${m % 60} min';
}

class GlucoseCard extends StatelessWidget {
  const GlucoseCard({super.key, required this.m, required this.thresholds});
  final GlucoseMeasurement m;
  final Thresholds thresholds;

  @override
  Widget build(BuildContext context) {
    final status = thresholds.statusOf(m.value);
    return Card(
      color: status.color.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '${m.value}',
                  style: TextStyle(
                    fontSize: 72,
                    fontWeight: FontWeight.bold,
                    color: status.color,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  m.trend.arrow,
                  style: TextStyle(fontSize: 48, color: status.color),
                ),
              ],
            ),
            const Text('mg/dL'),
            const SizedBox(height: 8),
            Text('${status.label} · ${ageLabel(m.timestamp)}'),
          ],
        ),
      ),
    );
  }
}
