import 'dart:async';

import 'package:flutter/material.dart';

import '../models/glucose.dart';
import '../models/thresholds.dart';
import '../services/live_activity_manager.dart';
import '../services/librelinkup_service.dart';
import '../services/storage_service.dart';
import '../widgets/glucose_card.dart';
import '../widgets/glucose_chart.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.service,
    required this.storage,
    required this.liveActivity,
    required this.onLogout,
  });
  final LibreLinkUpService service;
  final StorageService storage;
  final LiveActivityManager liveActivity;
  final VoidCallback onLogout;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const _window = Duration(hours: 4);

  Connection? _patient;
  GlucoseGraph? _graph;
  Thresholds _thresholds = const Thresholds();
  bool _liveOn = false;
  bool _loading = true;
  String? _error;
  Timer? _timer;

  GlucoseMeasurement? get _current => _graph?.current ?? _patient?.current;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
    // Foreground polling; background refresh comes with step 3.
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _init() async {
    _thresholds = await widget.storage.readThresholds();
    _liveOn = await widget.storage.readLiveActivity();
    await _refresh();
  }

  Future<void> _refresh() async {
    try {
      // Multi-profile picker: first connection for now.
      _patient ??= (await widget.service.getConnections()).first;
      _graph = await widget.service.getGraph(_patient!.patientId);
      _error = null;
      final m = _current;
      if (_liveOn && m != null) {
        await widget.liveActivity.update(m, _thresholds, _patient!.name);
      }
    } on Exception catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _toggleLive(bool on) async {
    final m = _current;
    setState(() => _liveOn = on);
    await widget.storage.saveLiveActivity(on);
    if (on && m != null) {
      await widget.liveActivity.start(m, _thresholds, _patient?.name ?? '');
    } else {
      await widget.liveActivity.stop();
    }
  }

  Future<void> _setThresholds(Thresholds t) async {
    setState(() => _thresholds = t);
    await widget.storage.saveThresholds(t);
    final m = _current;
    if (_liveOn && m != null) {
      await widget.liveActivity.update(m, t, _patient?.name ?? '');
    }
  }

  Future<void> _logout() async {
    await widget.liveActivity.stop();
    await widget.storage.clearCredentials();
    widget.onLogout();
  }

  @override
  Widget build(BuildContext context) {
    final m = _current;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _patient?.name.isNotEmpty == true ? _patient!.name : 'LibreGlance',
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (m != null) GlucoseCard(m: m, thresholds: _thresholds),
                SwitchListTile(
                  title: const Text('Afficher dans la Dynamic Island'),
                  value: _liveOn,
                  onChanged: _toggleLive,
                ),
                if (_graph != null)
                  GlucoseChart(
                    points: _graph!.last(_window),
                    thresholds: _thresholds,
                  ),
                const SizedBox(height: 8),
                _ThresholdRow(
                  thresholds: _thresholds,
                  onChanged: _setThresholds,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Rafraîchir maintenant'),
                ),
                TextButton(
                  onPressed: _logout,
                  child: const Text('Déconnexion'),
                ),
              ],
            ),
    );
  }
}

class _ThresholdRow extends StatelessWidget {
  const _ThresholdRow({required this.thresholds, required this.onChanged});
  final Thresholds thresholds;
  final ValueChanged<Thresholds> onChanged;

  Widget _stepper(String label, int value, ValueChanged<int> set) => Expanded(
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          onPressed: () => set(value - 5),
          icon: const Icon(Icons.remove),
        ),
        Text('$label $value'),
        IconButton(
          onPressed: () => set(value + 5),
          icon: const Icon(Icons.add),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Row(
    children: [
      _stepper('Min', thresholds.min, (v) {
        {
          onChanged(Thresholds(min: v, max: thresholds.max));
        }
        onChanged(Thresholds(min: v, max: thresholds.max));
      }),
      _stepper('Max', thresholds.max, (v) {
        if (v <= 400 && v > thresholds.min) {
          onChanged(Thresholds(min: thresholds.min, max: v));
        }
      }),
    ],
  );
}
