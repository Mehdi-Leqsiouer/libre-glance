import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/alerts.dart';
import '../services/alert_service.dart';
import '../services/notification_service.dart';
import '../services/push_registration.dart';
import '../services/storage_service.dart';

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({
    super.key,
    required this.storage,
    required this.registrar,
  });
  final StorageService storage;
  final PushRegistrar registrar;

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  AlertSettings _s = const AlertSettings();
  AlertState _state = const AlertState();
  List<AlertRecord> _history = [];
  final _serverUrl = TextEditingController();
  final _serverKey = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _serverUrl.dispose();
    _serverKey.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = await widget.storage.readAlertSettings();
    final st = await widget.storage.readAlertState();
    final h = await widget.storage.readAlertHistory();
    final server = await widget.storage.readServer();
    if (mounted) {
      setState(() {
        _s = s;
        _state = st;
        _history = h;
        _serverUrl.text = server?.url ?? '';
        _serverKey.text = server?.apiKey ?? '';
      });
    }
  }

  Future<void> _saveServer() async {
    final messenger = ScaffoldMessenger.of(context);
    await widget.storage.saveServer(
      _serverUrl.text.trim(),
      _serverKey.text.trim(),
    );
    final error = await widget.registrar.sync();
    messenger.showSnackBar(
      SnackBar(content: Text(error ?? 'Serveur enregistré')),
    );
  }

  Future<void> _set(Map<String, dynamic> overrides) async {
    setState(() => _s = _s.with_(overrides));
    await widget.storage.saveAlertSettings(_s);
  }

  Future<void> _snooze(Duration? d) async {
    d == null
        ? await AlertService.clearSnooze(widget.storage)
        : await AlertService.snooze(widget.storage, d);
    await _load();
  }

  Widget _stepper(
    String label,
    int value,
    String key,
    int step,
    int lo,
    int hi,
  ) => Padding(
    padding: const EdgeInsets.only(left: 16),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        IconButton(
          icon: const Icon(Icons.remove),
          onPressed: value - step >= lo
              ? () => _set({key: value - step})
              : null,
        ),
        Text('$value'),
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: value + step <= hi
              ? () => _set({key: value + step})
              : null,
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final snoozed =
        _state.snoozeUntil != null &&
        _state.snoozeUntil!.isAfter(DateTime.now());
    final time = DateFormat('d/M HH:mm');
    return Scaffold(
      appBar: AppBar(title: const Text('Alertes')),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Les alertes sont évaluées à chaque rafraîchissement : app ouverte, '
              'et en arrière-plan quand iOS le permet (environ toutes les 15 min, '
              'non garanti). Laisse l\'app ouverte ou le téléphone en charge pour '
              'plus de fiabilité.',
            ),
          ),
          SwitchListTile(
            title: const Text('Mode critique (hypoglycémies)'),
            subtitle: const Text(
              'Sonne même en silencieux ou Ne pas déranger. Nécessite '
              "l'autorisation Apple des alertes critiques.",
            ),
            value: _s.criticalEnabled,
            onChanged: (v) async {
              final messenger = ScaffoldMessenger.of(context);
              await _set({'criticalEnabled': v});
              if (!v) return;
              final granted = await NotificationService.instance
                  .requestCritical();
              if (!granted) {
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Alertes critiques non autorisées : les alertes restent '
                      'urgentes mais respectent le mode silencieux.',
                    ),
                  ),
                );
              }
            },
          ),
          SwitchListTile(
            title: const Text('Hypoglycémie urgente'),
            subtitle: const Text('Ignore le report'),
            value: _s.urgentLowEnabled,
            onChanged: (v) => _set({'urgentLowEnabled': v}),
          ),
          if (_s.urgentLowEnabled)
            _stepper(
              'Seuil urgent (mg/dL)',
              _s.urgentLow,
              'urgentLow',
              5,
              40,
              80,
            ),
          SwitchListTile(
            title: const Text('Hypoglycémie'),
            subtitle: const Text('Sous le seuil min de l\'écran principal'),
            value: _s.lowEnabled,
            onChanged: (v) => _set({'lowEnabled': v}),
          ),
          SwitchListTile(
            title: const Text('Chute rapide'),
            subtitle: const Text('Flèche ↓↓ près du seuil min'),
            value: _s.fastFallEnabled,
            onChanged: (v) => _set({'fastFallEnabled': v}),
          ),
          SwitchListTile(
            title: const Text('Hyperglycémie'),
            subtitle: const Text('Au-dessus du seuil max'),
            value: _s.highEnabled,
            onChanged: (v) => _set({'highEnabled': v}),
          ),
          SwitchListTile(
            title: const Text('Perte de données'),
            subtitle: const Text(
              'Aucune mesure récente (Bluetooth du téléphone de la maison ?)',
            ),
            value: _s.staleEnabled,
            onChanged: (v) => _set({'staleEnabled': v}),
          ),
          if (_s.staleEnabled)
            _stepper('Délai (min)', _s.staleMinutes, 'staleMinutes', 5, 5, 120),
          SwitchListTile(
            title: const Text('Expiration du capteur'),
            subtitle: const Text('Rappel 24 h avant la fin du capteur'),
            value: _s.sensorEnabled,
            onChanged: (v) => _set({'sensorEnabled': v}),
          ),
          if (_s.sensorEnabled)
            _stepper(
              'Durée du capteur (jours)',
              _s.sensorDays,
              'sensorDays',
              1,
              10,
              21,
            ),
          const Divider(),
          ListTile(
            title: Text(
              snoozed
                  ? 'Alertes reportées jusqu\'à ${DateFormat.Hm().format(_state.snoozeUntil!)}'
                  : 'Reporter les alertes',
            ),
            subtitle: const Text('Sauf hypoglycémie urgente'),
          ),
          Wrap(
            spacing: 8,
            children:
                [
                      for (final m in [15, 30, 60])
                        OutlinedButton(
                          onPressed: () => _snooze(Duration(minutes: m)),
                          child: Text('$m min'),
                        ),
                      if (snoozed)
                        TextButton(
                          onPressed: () => _snooze(null),
                          child: const Text('Annuler le report'),
                        ),
                    ]
                    .map(
                      (w) => Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: w,
                      ),
                    )
                    .toList(),
          ),
          const Divider(),
          const ListTile(
            title: Text('Serveur de push'),
            subtitle: Text(
              'Met la Live Activity à jour app fermée. Active d\'abord '
              '« Afficher dans la Dynamic Island » sur l\'écran principal.',
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                TextField(
                  controller: _serverUrl,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'URL du serveur',
                  ),
                ),
                TextField(
                  controller: _serverKey,
                  obscureText: true,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Clé d\'API'),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _saveServer,
                  child: const Text('Enregistrer le serveur'),
                ),
              ],
            ),
          ),
          const Divider(),
          const ListTile(title: Text('Historique')),
          if (_history.isEmpty)
            const ListTile(subtitle: Text('Aucune alerte pour le moment')),
          for (final r in _history)
            ListTile(
              dense: true,
              title: Text('${r.kind.label} · ${r.value} mg/dL'),
              trailing: Text(time.format(r.time)),
            ),
        ],
      ),
    );
  }
}
