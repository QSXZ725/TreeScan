import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:treescan_desktop/crash_log.dart';

void main() {
  test('groups repeat errors and omits paths outside project frames', () {
    final directory = Directory.systemTemp.createTempSync(
      'treescan-diagnostics-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final log = CrashLog(directory)..version = '0.1.0+7';
    final stack = StackTrace.fromString(
      '#0 internal (file:///private/folder.txt)\n'
      '#1 update (package:treescan_desktop/main.dart:18:3)',
    );
    log.record('dart-unhandled', 'StateError', stack);
    log.record('dart-unhandled', 'StateError', stack);
    final expired = File('${directory.path}/native-expired.json')
      ..writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'timestampMs': 1,
          'version': '0.1.0+6',
          'source': 'windows-native',
          'type': '0xC0000005',
        }),
      );
    final report = log.report();
    final group = (report['groups'] as List<Map<String, Object>>).single;
    expect(group['count'], 2);
    expect(group['frame'], 'package:treescan_desktop/main.dart:18:3');
    expect(jsonEncode(report), isNot(contains('/private/')));
    expect(expired.existsSync(), isFalse);
  });

  test('redacts private data in older diagnostic files', () {
    final directory = Directory.systemTemp.createTempSync(
      'treescan-diagnostics-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    File('${directory.path}/dart-old.json').writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'timestampMs': DateTime.now().millisecondsSinceEpoch,
        'version': 'file:///private/build',
        'source': 'file:///private/scanner',
        'type': 'Could not read /private/data',
        'frame': 'package:treescan_desktop/../../private/data.dart:1',
        'message': 'Could not read /private/data',
      }),
    );

    final report = CrashLog(directory).report();
    final event = (report['events'] as List<Map<String, Object>>).single;
    expect(event['version'], 'unknown');
    expect(event['source'], 'unknown');
    expect(event['type'], 'unknown');
    expect(jsonEncode(report), isNot(contains('/private/')));
  });
}
