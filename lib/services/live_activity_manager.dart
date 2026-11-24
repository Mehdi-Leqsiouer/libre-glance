import 'package:live_activities/live_activities.dart';

import '../models/glucose.dart';
import '../models/thresholds.dart';

const String appGroupId = 'group.com.datally.libreglance';
const String _activityId = 'glucose';

/// Set once we told the user that iOS ended the Live Activity (avoids repeats).
const String endedReminderFlag = 'la_ended_reminder';

/// iOS Live Activity / Dynamic Island (and Android ongoing notification) via
/// the `live_activities` plugin. Keys below are read by the Swift extension
/// and by `CustomLiveActivityManager.kt`: keep them in sync.
class LiveActivityManager {
  final LiveActivities _plugin = LiveActivities();
  bool _ready = false;

  Future<void> _init() async {
    if (_ready) return;
    await _plugin.init(appGroupId: appGroupId);
    _ready = true;
  }

  Future<void> start(GlucoseMeasurement m, Thresholds t, String patient) =>
      update(m, t, patient);

  /// Creates the activity if needed, otherwise updates it.
  Future<void> update(
    GlucoseMeasurement m,
    Thresholds t,
    String patient,
  ) async {
    await _init();
    await _plugin.createOrUpdateActivity(
      _activityId,
      {
        'glucose': m.value,
        'trend': m.trend.index + 1,
        'timestamp': m.timestamp.millisecondsSinceEpoch,
        'min': t.min,
        'max': t.max,
        'patient': patient,
      },
      iOSEnableRemoteUpdates: false, // no APNs server
    );
  }

  /// False once iOS ended it (8 h limit, user dismissed it, ...).
  Future<bool> isActive() async {
    await _init();
    return (await _plugin.getAllActivitiesIds()).contains(_activityId);
  }

  Future<void> stop() async {
    await _init();
    await _plugin.endActivity(_activityId);
  }
}
