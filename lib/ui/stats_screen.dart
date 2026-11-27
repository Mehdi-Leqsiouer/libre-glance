import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/glucose.dart';
import '../models/stats.dart';
import '../models/thresholds.dart';
import '../services/history_store.dart';
import '../services/librelinkup_service.dart';

class StatsScreen extends StatefulWidget {
  const StatsScreen({
    super.key,
    required this.history,
    required this.thresholds,
    required this.service,
    required this.patientId,
  });
  final HistoryStore history;
  final Thresholds thresholds;
  final LibreLinkUpService service;
  final String? patientId;

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  static const _periods = {'24 h': 1, '7 j': 7, '14 j': 14, '30 j': 30};
  int _days = 1;
  GlucoseStats? _stats;
  DateTime? _oldest;
  bool _loaded = false;
  List<AlarmEvent>? _alarms;
  String? _alarmsError;

  @override
  void initState() {
    super.initState();
    _load();
    _loadAlarms();
  }

  Future<void> _loadAlarms() async {
    final id = widget.patientId;
    if (id == null) return;
    try {
      final events = await widget.service.getAlarmEvents(id);
      if (mounted) setState(() => _alarms = events);
    } catch (e) {
      if (mounted) setState(() => _alarmsError = '$e');
    }
  }

  /// Alarms the patient's device raised over the selected period (LibreLink keeps ~10 days).
  Widget _alarmSection() {
    final events = _alarms;
    if (events == null && _alarmsError == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    if (events == null) {
      return Text(
        _alarmsError!,
        style: TextStyle(color: theme.colorScheme.error),
      );
    }
    final cutoff = DateTime.now().subtract(Duration(days: _days));
    final shown = events.where((e) => e.timestamp.isAfter(cutoff)).toList();
    final lows = shown.where((e) => e.kind == AlarmKind.low).length;
    final highs = shown.where((e) => e.kind == AlarmKind.high).length;
    final format = DateFormat('d/M HH:mm');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        Text('Alarmes du capteur', style: theme.textTheme.titleMedium),
        Text(
          '$lows basses · $highs hautes (journal LibreLink, environ 10 jours)',
          style: theme.textTheme.bodySmall,
        ),
        if (shown.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Aucune alarme sur cette période.'),
          ),
        for (final e in shown.take(15))
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(switch (e.kind) {
              AlarmKind.low => 'Alarme basse',
              AlarmKind.high => 'Alarme haute',
              AlarmKind.other => 'Alarme',
            }),
            subtitle: Text(format.format(e.timestamp)),
            trailing: Text(
              '${e.value} mg/dL',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
      ],
    );
  }

  Future<void> _load() async {
    final window = Duration(days: _days);
    final readings = await widget.history.since(window);
    final all = await widget.history.since(
      const Duration(days: HistoryStore.keepDays),
    );
    if (!mounted) return;
    setState(() {
      _stats = computeStats(readings, widget.thresholds, window);
      _oldest = all.isEmpty ? null : all.first.time;
      _loaded = true;
    });
  }

  Widget _bar(GlucoseStats s) {
    Widget seg(double pct, Color c) => Expanded(
      flex: (pct * 10).round().clamp(0, 1000),
      child: Container(height: 18, color: c),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: Row(
        children: [
          seg(s.lowPct, GlucoseStatus.low.color),
          seg(s.inRangePct, GlucoseStatus.inRange.color),
          seg(s.highPct, GlucoseStatus.high.color),
        ],
      ),
    );
  }

  Widget _row(String label, String value) => ListTile(
    dense: true,
    title: Text(label),
    trailing: Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
  );

  @override
  Widget build(BuildContext context) {
    final s = _stats;
    final t = widget.thresholds;
    return Scaffold(
      appBar: AppBar(title: const Text('Statistiques')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 8,
            children: [
              for (final e in _periods.entries)
                ChoiceChip(
                  label: Text(e.key),
                  selected: _days == e.value,
                  onSelected: (_) {
                    setState(() => _days = e.value);
                    _load();
                  },
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (!_loaded)
            const Center(child: CircularProgressIndicator())
          else if (s == null)
            const Text(
              'Pas encore de données : l\'historique se remplit à chaque rafraîchissement.',
            )
          else ...[
            _bar(s),
            const SizedBox(height: 8),
            Text(
              'Bas ${s.lowPct.toStringAsFixed(0)} %  ·  '
              'Dans la cible ${s.inRangePct.toStringAsFixed(0)} %  ·  '
              'Élevé ${s.highPct.toStringAsFixed(0)} %',
              textAlign: TextAlign.center,
            ),
            Text(
              'Cible ${t.min}-${t.max} mg/dL',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            _row('Moyenne', '${s.mean.toStringAsFixed(0)} mg/dL'),
            _row('Écart-type', '${s.sd.toStringAsFixed(0)} mg/dL'),
            _row('Variabilité (CV)', '${s.cv.toStringAsFixed(0)} %'),
            _row('Min / Max', '${s.min} / ${s.max} mg/dL'),
            _row('Mesures', '${s.count}'),
            _row('Couverture', '${s.coveragePct.toStringAsFixed(0)} %'),
            if (_oldest != null && s.coveragePct < 90)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Historique enregistré depuis le '
                  '${_oldest!.day}/${_oldest!.month}. Les trous correspondent aux '
                  'périodes où l\'app n\'a pas pu se rafraîchir.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
          _alarmSection(),
        ],
      ),
    );
  }
}
