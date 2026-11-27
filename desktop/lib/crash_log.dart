import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'settings.dart';

final crashLog = CrashLog(
  Directory('${SettingsStore(null).directory.path}/crash-reports'),
);

class CrashLog {
  CrashLog(this.directory);

  static const maximumEvents = 50;
  static const retention = Duration(days: 30);
  static const _appVersion = String.fromEnvironment('TREESCAN_VERSION');
  static const _build = int.fromEnvironment('TREESCAN_BUILD_NUMBER');
  static const _sources = {
    'flutter-framework',
    'dart-unhandled',
    'scanner-isolate',
    'windows-native',
  };
  static final _versionTag = RegExp(r'^\d+\.\d+\.\d+(?:\+\d+)?$');
  static final _errorType = RegExp(r'^[A-Za-z0-9_.$]{1,128}$');
  static final _projectFrame = RegExp(
    r'package:treescan_desktop/(?:[A-Za-z0-9_-]+/)*'
    r'[A-Za-z0-9_.-]+\.dart:\d+(?::\d+)?',
  );

  final Directory directory;
  String version = _appVersion.isEmpty ? 'unknown' : '$_appVersion+$_build';
  int _sequence = 0;

  void record(String source, String type, StackTrace? stack) {
    try {
      directory.createSync(recursive: true);
      final now = DateTime.now().millisecondsSinceEpoch;
      final name = '${directory.path}/dart-$now-$pid-${_sequence++}';
      final pending = File('$name.tmp');
      try {
        final frame = stack == null
            ? null
            : _projectFrame.firstMatch(stack.toString())?.group(0);
        pending.writeAsStringSync(
          jsonEncode({
            'schemaVersion': 1,
            'timestampMs': now,
            'platform': Platform.operatingSystem,
            'version': version,
            'source': source,
            'type': type,
            if (frame != null) 'frame': frame,
          }),
          flush: true,
        );
        pending.renameSync('$name.json');
      } finally {
        if (pending.existsSync()) pending.deleteSync();
      }
      report();
    } on Exception {
      // Preserve the original error even if the report cannot be written.
    }
  }

  Map<String, Object> report() {
    final now = DateTime.now();
    final oldest = now.subtract(retention).millisecondsSinceEpoch;
    final rows = <({File file, Map<String, Object> event})>[];
    try {
      for (final file
          in directory.listSync(followLinks: false).whereType<File>()) {
        final name = file.uri.pathSegments.last;
        if (!(name.startsWith('dart-') || name.startsWith('native-'))) continue;
        if (!name.endsWith('.json')) continue;
        try {
          if (file.lengthSync() > 4096) continue;
          final data = jsonDecode(file.readAsStringSync());
          if (data is! Map<String, dynamic> ||
              data['schemaVersion'] != 1 ||
              data['timestampMs'] is! int ||
              data['source'] is! String ||
              data['type'] is! String ||
              data['version'] is! String) {
            continue;
          }
          if ((data['timestampMs'] as int) < oldest) {
            file.deleteSync();
            continue;
          }
          final storedFrame = data['frame'];
          final frame = storedFrame is String
              ? _projectFrame.firstMatch(storedFrame)?.group(0)
              : null;
          final version = data['version'] as String;
          final source = data['source'] as String;
          final type = data['type'] as String;
          rows.add((
            file: file,
            event: {
              'schemaVersion': 1,
              'timestampMs': data['timestampMs'] as int,
              'platform': Platform.operatingSystem,
              'version': _versionTag.hasMatch(version) ? version : 'unknown',
              'source': _sources.contains(source) ? source : 'unknown',
              'type': _errorType.hasMatch(type) ? type : 'unknown',
              if (frame != null) 'frame': frame,
            },
          ));
        } on Exception {
          // Ignore an incomplete, invalid, or concurrently pruned event.
        }
      }
    } on FileSystemException {
      // A fresh installation may not have a report directory yet.
    }
    rows.sort(
      (a, b) => (b.event['timestampMs'] as int).compareTo(
        a.event['timestampMs'] as int,
      ),
    );
    for (final row in rows.skip(maximumEvents)) {
      try {
        row.file.deleteSync();
      } on FileSystemException {
        // A second instance may have pruned the same file.
      }
    }
    final events = rows.take(maximumEvents).map((row) => row.event).toList();
    final groups = <(String, String, String, String?), Map<String, Object>>{};
    for (final event in events) {
      final key = (
        event['source'] as String,
        event['type'] as String,
        event['version'] as String,
        event['frame'] as String?,
      );
      final group = groups.putIfAbsent(
        key,
        () => {
          'source': key.$1,
          'type': key.$2,
          'version': key.$3,
          if (key.$4 != null) 'frame': key.$4!,
          'lastSeenMs': event['timestampMs']!,
          'count': 0,
        },
      );
      group['count'] = (group['count'] as int) + 1;
    }
    return {
      'format': 'treescan-crash-report',
      'schemaVersion': 1,
      'generatedAtMs': now.millisecondsSinceEpoch,
      'events': events,
      'groups': groups.values.toList(),
    };
  }

  Future<Map<String, Object>> reportAsync() {
    final path = directory.path;
    final currentVersion = version;
    return Isolate.run(
      () => (CrashLog(Directory(path))..version = currentVersion).report(),
    );
  }
}
