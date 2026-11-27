import 'package:intl/intl.dart';

/// LibreView timestamps look like "11/23/2026 4:05:09 PM" (en_US, device-local time).
final DateFormat _libreTimestamp = DateFormat('M/d/yyyy h:mm:ss a', 'en_US');

DateTime parseLibreTimestamp(String raw) => _libreTimestamp.parse(raw.trim());

/// `FactoryTimestamp` is the same format but in UTC: the only unambiguous instant.
DateTime parseLibreUtcTimestamp(String raw) =>
    _libreTimestamp.parseUtc(raw.trim()).toLocal();

/// LibreLinkUp trend: 1=falling fast, 2=falling, 3=stable, 4=rising, 5=rising fast.
enum Trend {
  fallingFast('↓↓'),
  falling('↓'),
  stable('→'),
  rising('↑'),
  risingFast('↑↑');

  const Trend(this.arrow);
  final String arrow;

  /// Unknown values fall back to [stable].
  static Trend fromApi(int? v) =>
      (v != null && v >= 1 && v <= 5) ? Trend.values[v - 1] : Trend.stable;
}

class GlucoseMeasurement {
  const GlucoseMeasurement({
    required this.value,
    required this.trend,
    required this.timestamp,
  });

  /// mg/dL
  final int value;
  final Trend trend;
  final DateTime timestamp;

  /// Null when the payload has no usable value / timestamp (e.g. sensor not reporting).
  static GlucoseMeasurement? tryFromJson(Map<String, dynamic> json) {
    final hasTime =
        json['FactoryTimestamp'] is String || json['Timestamp'] is String;
    if (json['Value'] is! num || !hasTime) return null;
    try {
      return GlucoseMeasurement.fromJson(json);
    } on FormatException {
      return null; // unparseable timestamp
    }
  }

  factory GlucoseMeasurement.fromJson(Map<String, dynamic> json) =>
      GlucoseMeasurement(
        value: (json['Value'] as num).round(),
        trend: Trend.fromApi((json['TrendArrow'] as num?)?.toInt()),
        timestamp: json['FactoryTimestamp'] is String
            ? parseLibreUtcTimestamp(json['FactoryTimestamp'] as String)
            : parseLibreTimestamp(json['Timestamp'] as String),
      );
}

/// A followed patient (one entry of `GET /llu/connections`).
class Connection {
  const Connection({required this.patientId, required this.name, this.current});

  final String patientId;
  final String name;
  final GlucoseMeasurement? current;

  factory Connection.fromJson(Map<String, dynamic> json) {
    final gm = json['glucoseMeasurement'] as Map<String, dynamic>?;
    return Connection(
      patientId: json['patientId'] as String,
      name: '${json['firstName'] ?? ''} ${json['lastName'] ?? ''}'.trim(),
      current: gm == null ? null : GlucoseMeasurement.tryFromJson(gm),
    );
  }
}

/// Alarm thresholds (mg/dL) set in the patient's LibreLink app (`connection.alarmRules`).
class LibreAlarms {
  const LibreAlarms({this.low, this.high, this.urgentLow});
  final int? low;
  final int? high;
  final int? urgentLow;

  /// Rules: low `l`, high `h`, fixed urgent low `f`, each with a threshold `th`.
  static LibreAlarms? fromRules(Object? rules) {
    if (rules is! Map<String, dynamic>) return null;
    int? threshold(String key) {
      final rule = rules[key];
      final th = rule is Map ? rule['th'] : null;
      return th is num ? th.round() : null;
    }

    final alarms = LibreAlarms(
      low: threshold('l'),
      high: threshold('h'),
      urgentLow: threshold('f'),
    );
    return (alarms.low ?? alarms.high ?? alarms.urgentLow) == null
        ? null
        : alarms;
  }
}

enum AlarmKind { low, high, other }

/// An alarm the patient's device raised (`GET /llu/connections/{id}/logbook`).
class AlarmEvent {
  const AlarmEvent(this.timestamp, this.value, this.kind);
  final DateTime timestamp;
  final int value;
  final AlarmKind kind;

  /// Null for entries that are not alarms (no `alarmType`) or have no usable value.
  /// Meaning of `alarmType` inferred from the values: 1 = low, 2 = high.
  static AlarmEvent? tryFromJson(Map<String, dynamic> json) {
    final type = json['alarmType'];
    final m = GlucoseMeasurement.tryFromJson(json);
    if (type is! int || m == null) return null;
    return AlarmEvent(m.timestamp, m.value, switch (type) {
      1 => AlarmKind.low,
      2 => AlarmKind.high,
      _ => AlarmKind.other,
    });
  }
}

/// Result of `GET /llu/connections/{patientId}/graph`.
class GlucoseGraph {
  const GlucoseGraph({
    required this.current,
    required this.history,
    this.sensorActivatedAt,
    this.sensorWarmup = const Duration(minutes: 60),
    this.alarms,
  });

  final GlucoseMeasurement? current;

  /// Oldest first.
  final List<GlucoseMeasurement> history;

  /// When the active sensor was started (`activeSensors[0].sensor.a`, unix seconds).
  final DateTime? sensorActivatedAt;

  /// The sensor reports nothing during its warm-up (`sensor.w` minutes).
  final Duration sensorWarmup;

  final LibreAlarms? alarms;

  /// Time left before the sensor delivers its first reading, null once it is ready.
  Duration? warmupLeft({DateTime? now}) {
    final start = sensorActivatedAt;
    if (start == null) return null;
    final left = start.add(sensorWarmup).difference(now ?? DateTime.now());
    return left.isNegative ? null : left;
  }

  factory GlucoseGraph.fromJson(Map<String, dynamic> data) {
    final connection = data['connection'] as Map<String, dynamic>?;
    final gm = connection?['glucoseMeasurement'] as Map<String, dynamic>?;
    final points =
        (data['graphData'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(GlucoseMeasurement.tryFromJson)
            .nonNulls
            .toList()
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return GlucoseGraph(
      current: gm == null ? null : GlucoseMeasurement.tryFromJson(gm),
      history: points,
      sensorActivatedAt: _sensorField(data, 'a', (a) {
        return DateTime.fromMillisecondsSinceEpoch(a.toInt() * 1000);
      }),
      sensorWarmup:
          _sensorField(data, 'w', (w) => Duration(minutes: w.toInt())) ??
          const Duration(minutes: 60),
      alarms: LibreAlarms.fromRules(connection?['alarmRules']),
    );
  }

  /// A field of `activeSensors[0].sensor` (the current sensor), null when absent.
  static T? _sensorField<T>(
    Map<String, dynamic> data,
    String key,
    T Function(num) convert,
  ) {
    final sensors = data['activeSensors'];
    if (sensors is! List || sensors.isEmpty) return null;
    final sensor = (sensors.first as Map<String, dynamic>)['sensor'];
    final value = sensor is Map ? sensor[key] : null;
    return value is num ? convert(value) : null;
  }

  /// Points from the last [window] relative to [now].
  List<GlucoseMeasurement> last(Duration window, {DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(window);
    return history.where((m) => m.timestamp.isAfter(cutoff)).toList();
  }
}
