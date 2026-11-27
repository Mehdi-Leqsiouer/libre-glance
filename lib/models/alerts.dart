enum AlertKind {
  urgentLow('Hypoglycémie urgente'),
  low('Hypoglycémie'),
  fastFall('Chute rapide'),
  high('Hyperglycémie'),
  stale('Perte de données'),
  sensorExpiry('Capteur bientôt expiré');

  const AlertKind(this.label);
  final String label;
}

/// User-tunable alerts. Every alert can be switched off independently.
class AlertSettings {
  const AlertSettings({
    this.urgentLowEnabled = true,
    this.urgentLow = 55,
    this.lowEnabled = true,
    this.fastFallEnabled = true,
    this.highEnabled = false,
    this.staleEnabled = true,
    this.staleMinutes = 15,
    this.criticalEnabled = false,
    this.sensorEnabled = true,
    this.sensorDays = 15,
    this.useLibreThresholds = false,
  });

  final bool urgentLowEnabled;
  final int urgentLow; // mg/dL
  final bool lowEnabled; // uses Thresholds.min
  final bool fastFallEnabled;
  final bool highEnabled; // uses Thresholds.max
  final bool staleEnabled;
  final int staleMinutes;

  /// Low alerts ring through silent mode and Do Not Disturb (needs the Apple entitlement).
  final bool criticalEnabled;

  /// Remind 24 h before the sensor ends; Libre 2 Plus lasts 15 days (older models 14).
  final bool sensorEnabled;
  final int sensorDays;

  /// Take the low, high and urgent low thresholds from the patient's LibreLink app
  /// instead of the ones set here.
  final bool useLibreThresholds;

  factory AlertSettings.fromJson(Map<String, dynamic> j) => AlertSettings(
    urgentLowEnabled: j['urgentLowEnabled'] as bool? ?? true,
    urgentLow: j['urgentLow'] as int? ?? 55,
    lowEnabled: j['lowEnabled'] as bool? ?? true,
    fastFallEnabled: j['fastFallEnabled'] as bool? ?? true,
    highEnabled: j['highEnabled'] as bool? ?? false,
    staleEnabled: j['staleEnabled'] as bool? ?? true,
    staleMinutes: j['staleMinutes'] as int? ?? 15,
    criticalEnabled: j['criticalEnabled'] as bool? ?? false,
    sensorEnabled: j['sensorEnabled'] as bool? ?? true,
    sensorDays: j['sensorDays'] as int? ?? 15,
    useLibreThresholds: j['useLibreThresholds'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'urgentLowEnabled': urgentLowEnabled,
    'urgentLow': urgentLow,
    'lowEnabled': lowEnabled,
    'fastFallEnabled': fastFallEnabled,
    'highEnabled': highEnabled,
    'staleEnabled': staleEnabled,
    'staleMinutes': staleMinutes,
    'criticalEnabled': criticalEnabled,
    'sensorEnabled': sensorEnabled,
    'sensorDays': sensorDays,
    'useLibreThresholds': useLibreThresholds,
  };

  /// Copy with some JSON keys overridden, e.g. `s.with_({'lowEnabled': false})`.
  AlertSettings with_(Map<String, dynamic> overrides) =>
      AlertSettings.fromJson({...toJson(), ...overrides});
}

/// Persisted between evaluations (foreground and background isolates).
class AlertState {
  const AlertState({this.lastFired = const {}, this.snoozeUntil});

  final Map<AlertKind, DateTime> lastFired;
  final DateTime? snoozeUntil;

  factory AlertState.fromJson(Map<String, dynamic> j) => AlertState(
    lastFired: {
      for (final e in (j['lastFired'] as Map<String, dynamic>? ?? {}).entries)
        AlertKind.values.byName(e.key): DateTime.fromMillisecondsSinceEpoch(
          e.value as int,
        ),
    },
    snoozeUntil: j['snoozeUntil'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(j['snoozeUntil'] as int),
  );

  Map<String, dynamic> toJson() => {
    'lastFired': {
      for (final e in lastFired.entries)
        e.key.name: e.value.millisecondsSinceEpoch,
    },
    'snoozeUntil': snoozeUntil?.millisecondsSinceEpoch,
  };
}

class AlertRecord {
  const AlertRecord(this.kind, this.value, this.time);
  final AlertKind kind;
  final int value;
  final DateTime time;

  factory AlertRecord.fromJson(Map<String, dynamic> j) => AlertRecord(
    AlertKind.values.byName(j['kind'] as String),
    j['value'] as int,
    DateTime.fromMillisecondsSinceEpoch(j['time'] as int),
  );

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'value': value,
    'time': time.millisecondsSinceEpoch,
  };
}
