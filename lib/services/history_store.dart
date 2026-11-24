import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/glucose.dart';

typedef Reading = ({DateTime time, int value});

/// Local glucose history, kept 30 days. Not a secret, so a plain file (also
/// usable from the background isolate), not the Keychain.
///
/// Readings are binned per 15 min (latest wins): the API graph points and the
/// per-minute "current" reading then weigh the same in the statistics.
// ponytail: whole file rewritten on each add (~3k points max), no locking;
// switch to sqlite if it ever needs to be larger or written concurrently.
class HistoryStore {
  HistoryStore({this._file});
  File? _file;

  static const keepDays = 30;
  static const binSeconds = 15 * 60;

  Future<File> _open() async => _file ??= File(
    '${(await getApplicationSupportDirectory()).path}/history.json',
  );

  /// bin index -> value
  Future<Map<int, int>> _read() async {
    final f = await _open();
    if (!await f.exists()) return {};
    final flat = (jsonDecode(await f.readAsString()) as List<dynamic>)
        .cast<int>();
    return {for (var i = 0; i + 1 < flat.length; i += 2) flat[i]: flat[i + 1]};
  }

  Future<void> add(Iterable<GlucoseMeasurement> ms, {DateTime? now}) async {
    final bins = await _read();
    // Oldest first so that the latest reading of a bin wins.
    for (final m
        in ms.toList()..sort((a, b) => a.timestamp.compareTo(b.timestamp))) {
      bins[m.timestamp.millisecondsSinceEpoch ~/ 1000 ~/ binSeconds] = m.value;
    }
    final oldest =
        (now ?? DateTime.now())
            .subtract(const Duration(days: keepDays))
            .millisecondsSinceEpoch ~/
        1000 ~/
        binSeconds;
    bins.removeWhere((bin, _) => bin < oldest);
    final f = await _open();
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(
      jsonEncode([
        for (final e in bins.entries) ...[e.key, e.value],
      ]),
    );
    await tmp.rename(f.path);
  }

  /// Readings of the last [window], oldest first.
  Future<List<Reading>> since(Duration window, {DateTime? now}) async {
    final cutoff = (now ?? DateTime.now()).subtract(window);
    return [
      for (final e in (await _read()).entries)
        (
          time: DateTime.fromMillisecondsSinceEpoch(e.key * binSeconds * 1000),
          value: e.value,
        ),
    ].where((r) => r.time.isAfter(cutoff)).toList()..sort(
      (a, b) => a.time.compareTo(b.time),
    );
  }
}
