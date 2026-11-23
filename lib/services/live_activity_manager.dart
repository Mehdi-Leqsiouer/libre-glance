import '../models/glucose.dart';
import '../models/thresholds.dart';

/// Entry point for the iOS Live Activity / Dynamic Island.
// ponytail: no-op until step 3 wires the `live_activities` package and the
// native extension. The UI already calls these, so only this file changes.
class LiveActivityManager {
  Future<void> start(
    GlucoseMeasurement m,
    Thresholds t,
    String patient,
  ) async {}
  Future<void> update(
    GlucoseMeasurement m,
    Thresholds t,
    String patient,
  ) async {}
  Future<void> stop() async {}
}
