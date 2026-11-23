import 'package:flutter_test/flutter_test.dart';
import 'package:libre_glance/models/thresholds.dart';
import 'package:libre_glance/widgets/glucose_card.dart';

void main() {
  test('status boundaries are inclusive of the target range', () {
    const t = Thresholds();
    expect(t.statusOf(69), GlucoseStatus.low);
    expect(t.statusOf(70), GlucoseStatus.inRange);
    expect(t.statusOf(180), GlucoseStatus.inRange);
    expect(t.statusOf(181), GlucoseStatus.high);
  });

  test('age label', () {
    final now = DateTime(2026, 1, 1, 12);
    expect(ageLabel(now, now: now), "à l'instant");
    expect(
      ageLabel(now.subtract(const Duration(minutes: 3)), now: now),
      'il y a 3 min',
    );
    expect(
      ageLabel(now.subtract(const Duration(minutes: 75)), now: now),
      'il y a 1 h 15 min',
    );
  });
}
