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
      current: gm == null ? null : GlucoseMeasurement.fromJson(gm),
    );
  }
}

/// Result of `GET /llu/connections/{patientId}/graph`.
class GlucoseGraph {
  const GlucoseGraph({
    required this.current,
    required this.history,
    this.sensorActivatedAt,
  });

  final GlucoseMeasurement? current;

  /// Oldest first.
  final List<GlucoseMeasurement> history;

  /// When the active sensor was started (`activeSensors[0].sensor.a`, unix seconds).
  final DateTime? sensorActivatedAt;

  factory GlucoseGraph.fromJson(Map<String, dynamic> data) {
    final gm =
        (data['connection'] as Map<String, dynamic>?)?['glucoseMeasurement']
            as Map<String, dynamic>?;
    final points =
        (data['graphData'] as List<dynamic>? ?? const [])
            .map((e) => GlucoseMeasurement.fromJson(e as Map<String, dynamic>))
            .toList()
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return GlucoseGraph(
      current: gm == null ? null : GlucoseMeasurement.fromJson(gm),
      history: points,
      sensorActivatedAt: _sensorStart(data),
    );
  }

  static DateTime? _sensorStart(Map<String, dynamic> data) {
    final sensors = data['activeSensors'];
    if (sensors is! List || sensors.isEmpty) return null;
    final sensor = (sensors.first as Map<String, dynamic>)['sensor'];
    final a = sensor is Map ? sensor['a'] : null;
    return a is num
        ? DateTime.fromMillisecondsSinceEpoch(a.toInt() * 1000)
        : null;
  }

  /// Points from the last [window] relative to [now].
  List<GlucoseMeasurement> last(Duration window, {DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(window);
    return history.where((m) => m.timestamp.isAfter(cutoff)).toList();
  }
}
