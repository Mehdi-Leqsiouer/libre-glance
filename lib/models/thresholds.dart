import 'package:flutter/material.dart';

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
