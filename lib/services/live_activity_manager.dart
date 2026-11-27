import 'package:live_activities/live_activities.dart';
import 'package:live_activities/models/live_activity_state.dart';

import '../models/glucose.dart';
import '../models/thresholds.dart';

const String appGroupId = 'group.com.datally.libreglance';
const String _activityId = 'glucose';

/// Without a fresh update after this delay iOS flags the activity as stale and the
/// widget dims it: background refreshes are rare, so a quiet value must not look live.
const Duration staleAfter = Duration(minutes: 10);

/// Set once we told the user that iOS ended the Live Activity (avoids repeats).
const String endedReminderFlag = 'la_ended_reminder';

/// iOS Live Activity / Dynamic Island (and Android ongoing notification) via
/// the `live_activities` plugin. Keys below are read by the Swift extension
/// and by `CustomLiveActivityManager.kt`: keep them in sync.
class LiveActivityManager {
  LiveActivityManager({this.onToken, this.onPushToStartToken});

  /// Called with the activity's push token (new activity, or token rotated by iOS).
  final void Function(String token)? onToken;

  /// Called with the push-to-start token that lets the server start an activity (iOS 17.2+).
  final void Function(String token)? onPushToStartToken;
  final LiveActivities _plugin = LiveActivities();
  bool _ready = false;

  /// Subscribes to the token streams. Call it as early as possible: the plugin only
  /// observes activities (including those the server starts) once something listens.
  Future<void> listen() => _init();

  Future<void> _init() async {
    if (_ready) return;
    _ready = true;
    await _plugin.init(appGroupId: appGroupId);
    _plugin.activityUpdateStream.listen(
      (update) =>
          update.mapOrNull(active: (a) => onToken?.call(a.activityToken)),
      onError: (Object _) {},
    );
    _plugin.pushToStartTokenUpdateStream.listen(
      (token) => onPushToStartToken?.call(token),
      onError: (Object _) {}, // not available on Android
    );
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
    await _plugin.createOrUpdateActivity(_activityId, {
      'glucose': m.value,
      'trend': m.trend.index + 1,
      'timestamp': m.timestamp.millisecondsSinceEpoch,
      'min': t.min,
      'max': t.max,
      'patient': patient,
    }, staleIn: staleAfter);
  }

  /// False once iOS ended it (8 h limit, user dismissed it, ...).
  Future<bool> isActive() async {
    await _init();
    // getAllActivitiesIds() returns native ids, not ours: ask by custom id instead.
    final state = await _plugin.getActivityState(_activityId);
    return state == LiveActivityState.active ||
        state == LiveActivityState.stale;
  }

  Future<void> stop() async {
    await _init();
    await _plugin.endActivity(_activityId);
  }
}
