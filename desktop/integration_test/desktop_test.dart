import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:treescan_desktop/main.dart';
import 'package:treescan_desktop/scanner.dart';
import 'package:treescan_desktop/settings.dart';
import 'package:treescan_desktop/treemap.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('administrator scanning exposes only the scan workspace', (
    tester,
  ) async {
    final fixture = testFolder();
    Directory('${fixture.path}/read-only-fixture').createSync();
    await tester.pumpWidget(
      TreeScanApp(initialDirectory: fixture.path, readOnlyScan: true),
    );
    await untilVisible(tester, find.text('read-only-fixture'));

    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(find.byKey(const ValueKey('choose-folder')), findsOneWidget);
    expect(find.byKey(const ValueKey('open-settings')), findsNothing);
    expect(find.byKey(const ValueKey('open-about')), findsNothing);
    expect(find.byKey(const ValueKey('open-smart')), findsNothing);
    expect(find.text('导出快照'), findsNothing);
    expect(find.text('Export snapshot'), findsNothing);
  });

  testWidgets('scans, displays both metrics, and refreshes one directory', (
    tester,
  ) async {
    final notices = <String>[];
    final testNotices = <String>[];
    const shell = MethodChannel('org.treescan/windows');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(shell, (call) async {
      if (call.method == 'scanCompleteNotification') {
        notices.add(call.arguments as String);
        return true;
      }
      if (call.method == 'testScanNotification') {
        testNotices.add(call.arguments as String);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(shell, null));
    final fixture = testFolder();
    final sub = Directory('${fixture.path}/selected-directory')..createSync();
    File('${sub.path}/large.bin').writeAsBytesSync(List.filled(20001, 1));
    File('${fixture.path}/outside.bin').writeAsBytesSync(List.filled(8192, 2));

    await tester.pumpWidget(
      TreeScanApp(
        initialDirectory: fixture.absolute.path,
        settingsFile: File('${fixture.path}/settings.json'),
      ),
    );
    await untilVisible(tester, find.text('完成'));
    expect(notices, Platform.isWindows ? ['扫描完成，已扫描 2 个文件。'] : isEmpty);
    expect(find.text('GPT 龙娘'), findsNothing);
    final startLabel = find.textContaining('首批可浏览');
    await untilVisible(tester, startLabel);
    expect(startLabel, findsOneWidget);
    final first = tester.widget<Text>(startLabel).data!;
    if (Platform.isWindows) {
      expect(readMs(first, '首批可浏览'), lessThanOrEqualTo(2000));
    }
    debugPrint('TreeScan ${Platform.operatingSystem} UI $first');

    final table = find.byKey(const ValueKey('directory-table'));
    final selected = find.descendant(
      of: table,
      matching: find.text('selected-directory'),
    );
    expect(selected, findsOneWidget);
    await tester.tap(selected);
    await untilVisible(
      tester,
      find.descendant(of: table, matching: find.text('large.bin')),
    );
    final metrics = find.byType(SegmentedButton<Metric>);
    await tester.tap(find.descendant(of: metrics, matching: find.text('逻辑大小')));
    await untilVisible(tester, find.text('逻辑大小 ↓'));
    await untilVisible(tester, find.byType(SpaceMap));
    final diagram = tester.widget<SpaceMap>(find.byType(SpaceMap)).diagram;
    expect(diagram.items.single.bytes, BigInt.from(20001));

    File('${sub.path}/large.bin').deleteSync();
    await tester.tap(find.text('重扫此目录'));
    await untilVisible(tester, find.text('暂无可绘制的容量'));
    await tester.tap(find.text('前 100 项'));
    final ranking = find.byKey(const ValueKey('file-ranking'));
    await untilVisible(tester, ranking);
    expect(
      find.descendant(of: ranking, matching: find.text('outside.bin')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: ranking, matching: find.text('large.bin')),
      findsNothing,
    );
    if (Platform.isWindows) {
      expect(notices.length, 2);
      expect(notices.last, startsWith('重扫完成'));

      await tester.tap(find.byKey(const ValueKey('open-settings')));
      final notifications = find.byKey(const ValueKey('scan-notifications'));
      await untilVisible(tester, notifications);
      expect(tester.widget<SwitchListTile>(notifications).value, isTrue);
      final testButton = find.byKey(const ValueKey('test-scan-notification'));
      await tester.ensureVisible(testButton);
      await tester.tap(testButton);
      await untilVisible(tester, find.text('Windows 已接收通知请求。'));
      expect(testNotices, ['这是一条 TreeScan 测试通知。']);
      await tester.ensureVisible(notifications);
      await tester.tap(notifications);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('restart-or-stop')));
      await untilVisible(tester, find.text('完成'));
      expect(notices.length, 2);
    } else {
      await tester.tap(find.byKey(const ValueKey('choose-folder')));
      await untilVisible(tester, find.text('文件系统'));
      await tester.tap(find.text('文件系统'));
      await untilVisible(tester, find.text('/'));
      expect(notices, isEmpty);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'keeps the area map in place during scan and co-operatively stops',
    (tester) async {
      final dataset = Platform.environment['TREESCAN_BENCH_PATH'];
      if (dataset == null) return;
      final fixture = testFolder();
      await tester.pumpWidget(
        TreeScanApp(
          initialDirectory: dataset,
          settingsFile: File('${fixture.path}/settings.json'),
        ),
      );
      await untilVisible(tester, find.byType(SpaceMap));
      final initial = tester.widget<SpaceMap>(find.byType(SpaceMap)).diagram;
      final firstLabel = find.textContaining('首批可浏览');
      await untilVisible(tester, firstLabel);
      expect(
        readMs(tester.widget<Text>(firstLabel).data!, '首批可浏览'),
        lessThanOrEqualTo(2000),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester.widget<SpaceMap>(find.byType(SpaceMap)).diagram,
        same(initial),
      );
      await tester.tap(find.byTooltip('刷新面积图'));
      for (var attempt = 0; attempt < 100; attempt++) {
        await tester.pump(const Duration(milliseconds: 30));
        if (tester.widget<SpaceMap>(find.byType(SpaceMap)).diagram != initial) {
          break;
        }
      }
      expect(
        tester.widget<SpaceMap>(find.byType(SpaceMap)).diagram,
        isNot(same(initial)),
      );
      await tester.tap(find.byKey(const ValueKey('restart-or-stop')));
      await untilVisible(tester, find.text('已停止'));
      final timing = tester.widget<Text>(find.textContaining('停止反馈')).data!;
      expect(readMs(timing, '停止反馈'), lessThanOrEqualTo(500));
      expect(timing, contains('后台收尾'));
      expect(find.text('部分统计'), findsWidgets);
      debugPrint('TreeScan Windows UI $timing');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('saves display and graphics settings across launches', (
    tester,
  ) async {
    final fixture = testFolder();
    final file = File('${fixture.path}/settings.json');

    await tester.pumpWidget(TreeScanApp(settingsFile: file));
    final settings = find.byKey(const ValueKey('open-settings'));
    await untilVisible(tester, settings);
    expect(find.byType(AppBar), findsNothing);
    await tester.tap(settings);
    await selectSetting(tester, 'language', 'English');
    final gb = find.descendant(
      of: find.byKey(const ValueKey('size-unit')),
      matching: find.text('GB'),
    );
    await tester.ensureVisible(gb);
    await tester.tap(gb);
    final dark = find.byKey(const ValueKey('theme-dark'));
    await tester.ensureVisible(dark);
    await tester.tap(dark);
    await selectSetting(tester, 'graphics', 'Power saving');
    await selectSetting(tester, 'workers', '2');
    final notifications = find.byKey(const ValueKey('scan-notifications'));
    await tester.ensureVisible(notifications);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: notifications, matching: find.byType(Switch)),
    );
    await tester.pumpAndSettle();
    final mascotToggle = find.byKey(const ValueKey('show-mascot'));
    await tester.ensureVisible(mascotToggle);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: mascotToggle, matching: find.byType(Switch)),
    );

    final store = SettingsStore(file);
    var saved = await store.load();
    for (
      var attempt = 0;
      attempt < 60 &&
          (saved.workers != 2 || saved.showMascot || saved.scanNotifications);
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 30));
      saved = await store.load();
    }
    expect(saved.language, AppLanguage.english);
    expect(saved.unit, SizeUnit.decimal);
    expect(saved.theme, ThemeMode.dark);
    expect(saved.graphics, GraphicsPreference.powerSaving);
    expect(saved.workers, 2);
    expect(saved.showMascot, isFalse);
    expect(saved.scanNotifications, isFalse);
    expect(formatBytes(BigInt.from(1000000000), saved.unit), '1.0 GB');
    expect(formatBytes(BigInt.from(1073741824)), '1.0 GiB');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(TreeScanApp(settingsFile: file));
    await untilVisible(tester, find.text('Explore disk usage'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sidebar-mascot')), findsNothing);
    expect(
      Theme.of(tester.element(find.text('Explore disk usage'))).brightness,
      Brightness.dark,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'opens about from the mascot and can check the release configuration',
    (tester) async {
      final fixture = testFolder();
      await tester.pumpWidget(
        TreeScanApp(settingsFile: File('${fixture.path}/settings.json')),
      );
      final mascot = find.byKey(const ValueKey('sidebar-mascot'));
      await untilVisible(tester, mascot);
      await tester.tap(mascot);
      await untilVisible(tester, find.text('Build by Codex'));
      await untilVisible(tester, find.textContaining('· 构建'));
      expect(find.text('MIT'), findsOneWidget);
      expect(
        find.text('CrossPet · ZipZipPipe · CC BY-NC-SA 4.0'),
        findsOneWidget,
      );
      await tester.tap(find.text('检查更新'));
      await untilVisible(tester, find.text('尚未配置 GitHub 发布仓库。'));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'browses folders inside TreeScan and refreshes after file commands',
    (tester) async {
      final fixture = testFolder();
      final parent = Directory('${fixture.path}/picker-parent')..createSync();
      final root = Directory('${parent.path}/in-app-target')..createSync();
      final destination = Directory('${root.path}/destination')..createSync();
      final source = File('${root.path}/source.bin')
        ..writeAsStringSync('clipboard source');
      final pasted = File('${destination.path}/pasted.bin');

      const shell = MethodChannel('org.treescan/windows');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final commands = <String>[];
      messenger.setMockMethodCallHandler(shell, (call) async {
        final path = call.arguments;
        switch (call.method) {
          case 'titleTheme':
            return null;
          case 'volumeInfo':
            return null;
          case 'volumes':
            return [parent.absolute.path];
          case 'wslDisks':
            return [
              {
                'name': 'TreeScan fixture WSL',
                'path': r'\\wsl.localhost\TreeScan-fixture-WSL\',
                'image': r'D:\WSL fixture\ext4.vhdx',
              },
            ];
          case 'hasClipboardFiles':
            return true;
          case 'copy':
          case 'cut':
            commands.add(call.method);
            expect(
              File(path as String).resolveSymbolicLinksSync(),
              source.resolveSymbolicLinksSync(),
            );
            return {'changed': <String>[]};
          case 'paste':
            commands.add(call.method);
            expect(
              Directory(path as String).resolveSymbolicLinksSync(),
              destination.resolveSymbolicLinksSync(),
            );
            source.copySync(pasted.path);
            return {
              'changed': [path],
            };
          case 'delete':
            commands.add(call.method);
            expect(
              File(path as String).resolveSymbolicLinksSync(),
              pasted.resolveSymbolicLinksSync(),
            );
            pasted.deleteSync();
            return {
              'changed': [File(path).parent.path],
            };
          default:
            throw StateError('Unexpected Windows command ${call.method}');
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(shell, null));

      await tester.pumpWidget(
        TreeScanApp(settingsFile: File('${fixture.path}/settings.json')),
      );
      final picker = find.byKey(const ValueKey('choose-folder'));
      await untilVisible(tester, picker);
      await tester.tap(picker);
      await untilVisible(tester, find.text('WSL 2 虚拟磁盘'));
      await tester.tap(find.text('TreeScan fixture WSL'));
      await tester.pump();
      final confirm = find.byKey(const ValueKey('confirm-scan-folder'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      await tester.tap(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text(parent.absolute.path),
        ),
      );
      await untilVisible(tester, find.text('in-app-target'));
      await tester.tap(find.text('in-app-target'));
      await untilVisible(tester, find.text('destination'));
      await tester.tap(confirm);
      await untilVisible(tester, find.text('完成'));

      final table = find.byKey(const ValueKey('directory-table'));
      Finder row(String name) => find.descendant(
        of: table,
        matching: find.byWidgetPredicate(
          (widget) => widget is Text && widget.data == name,
        ),
      );
      Future<void> menu(String name, String command) async {
        await tester.tap(
          row(name),
          buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await untilVisible(tester, find.text(command));
        await tester.pumpAndSettle();
        await tester.tap(find.text(command));
        await tester.pumpAndSettle();
      }

      await menu('source.bin', '复制');
      await menu('source.bin', '剪切');
      await tester.tap(row('destination'));
      await untilVisible(tester, find.text('暂无可绘制的容量'));
      await menu('destination', '粘贴');
      await untilVisible(tester, row('pasted.bin'));
      await menu('pasted.bin', '删除');
      expect(commands, ['copy', 'cut', 'paste', 'delete']);
      await untilVisible(tester, find.text('暂无可绘制的容量'));
      expect(row('pasted.bin'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Directory testFolder() {
  final base = Directory(
    Platform.environment['TREESCAN_TEST_TMP'] ?? '../target',
  );
  if (!base.existsSync()) base.createSync(recursive: true);
  final parent = base.resolveSymbolicLinksSync();
  final folder = base.createTempSync('desktop-test-');
  addTearDown(() {
    final prefix = '$parent${Platform.pathSeparator}desktop-test-';
    if (folder.resolveSymbolicLinksSync().startsWith(prefix)) {
      folder.deleteSync(recursive: true);
    }
  });
  return folder;
}

Future<void> selectSetting(
  WidgetTester tester,
  String key,
  String label,
) async {
  final setting = find.byKey(ValueKey(key));
  await untilVisible(tester, setting);
  await tester.ensureVisible(setting);
  await tester.tap(setting);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

int readMs(String label, String prefix) =>
    int.parse(RegExp('$prefix (\\d+) ms').firstMatch(label)!.group(1)!);

Future<void> untilVisible(WidgetTester tester, Finder finder) async {
  final timer = Stopwatch()..start();
  while (finder.evaluate().isEmpty &&
      timer.elapsed < const Duration(seconds: 15)) {
    await tester.pump(const Duration(milliseconds: 30));
  }
  expect(finder, findsWidgets);
}
