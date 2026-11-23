import '../models/alerts.dart';
import '../models/glucose.dart';
import '../models/thresholds.dart';
import '../widgets/glucose_card.dart' show ageLabel;
import 'alert_engine.dart';
import 'storage_service.dart';

typedef ShowAlert =
    Future<void> Function(
      AlertKind kind,
      String title,
      String body, {
      bool critical,
    });

/// Evaluates the latest reading, notifies, and persists cooldown / history.
/// Safe to call from the foreground and from the background isolate.
class AlertService {
  AlertService(this._storage, this._show);
  final StorageService _storage;
  final ShowAlert _show;

  Future<void> check(
    GlucoseMeasurement m,
    Thresholds thresholds,
    String patient, {
    DateTime? now,
  }) async {
    now ??= DateTime.now();
    final settings = await _storage.readAlertSettings();
    final result = evaluate(
      m: m,
      thresholds: thresholds,
      settings: settings,
      state: await _storage.readAlertState(),
      now: now,
    );
    // Re-read: a snooze may have been written from a notification action meanwhile.
    final current = await _storage.readAlertState();
    await _storage.saveAlertState(
      AlertState(lastFired: result.lastFired, snoozeUntil: current.snoozeUntil),
    );
    for (final kind in result.fire) {
      await _show(
        kind,
        kind.label,
        _body(kind, m, patient, now),
        // Only hypoglycemia is worth waking someone up through silent mode.
        critical:
            settings.criticalEnabled &&
            (kind == AlertKind.urgentLow || kind == AlertKind.low),
      );
    }
    if (result.fire.isNotEmpty) {
      await _storage.addAlertHistory([
        for (final k in result.fire) AlertRecord(k, m.value, now),
      ]);
    }
  }

  static String _body(
    AlertKind kind,
    GlucoseMeasurement m,
    String patient,
    DateTime now,
  ) {
    final who = patient.isEmpty ? '' : '$patient : ';
    final age = ageLabel(m.timestamp, now: now);
    return switch (kind) {
      AlertKind.stale =>
        '${who}aucune mesure récente ($age). Le téléphone de la maison est-il '
            'connecté au capteur ?',
      _ => '$who${m.value} mg/dL ${m.trend.arrow} ($age)',
    };
  }

  static Future<void> snooze(
    StorageService storage,
    Duration d, {
    DateTime? now,
  }) async {
    final state = await storage.readAlertState();
    await storage.saveAlertState(
      AlertState(
        lastFired: state.lastFired,
        snoozeUntil: (now ?? DateTime.now()).add(d),
      ),
    );
  }

  static Future<void> clearSnooze(StorageService storage) async {
    final state = await storage.readAlertState();
    await storage.saveAlertState(AlertState(lastFired: state.lastFired));
  }
}
