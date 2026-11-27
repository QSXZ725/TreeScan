import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:treescan_desktop/mascot.dart';
import 'package:treescan_desktop/scanner.dart';
import 'package:treescan_desktop/settings.dart';
import 'package:treescan_desktop/smart.dart';
import 'package:treescan_desktop/treemap.dart';

void main() {
  testWidgets('settings cards reflow when the window is resized', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.25;
    tester.view.physicalSize = const Size(1600, 1600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(settings: const AppSettings(), onChanged: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final appearance = find.text('语言与外观');
    final scanning = find.text('扫描与统计');
    final mascot = find.byKey(const ValueKey('show-mascot'));
    expect(tester.getTopLeft(scanning).dy, tester.getTopLeft(appearance).dy);
    expect(
      tester.getTopLeft(mascot).dx,
      greaterThan(tester.getTopLeft(scanning).dx),
    );

    tester.view.physicalSize = const Size(1000, 1600);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(scanning).dy, tester.getTopLeft(appearance).dy);
    expect(
      tester.getTopLeft(mascot).dy,
      greaterThan(tester.getBottomLeft(scanning).dy),
    );

    tester.view.physicalSize = const Size(540, 1600);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(scanning).dx, tester.getTopLeft(appearance).dx);
    expect(
      tester.getTopLeft(scanning).dy,
      greaterThan(tester.getBottomLeft(appearance).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('capacity labels stay on one line at high DPI and large text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.25;
    tester.view.physicalSize = const Size(620, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    var settings = const AppSettings();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.35)),
          child: child!,
        ),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SettingsPage(
              settings: settings,
              onChanged: (change) =>
                  setState(() => settings = change(settings)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final control = find.byKey(const ValueKey('size-unit'));
    final gib = find.descendant(of: control, matching: find.text('GiB'));
    final gb = find.descendant(of: control, matching: find.text('GB'));
    expect(tester.widget<Text>(gib).maxLines, 1);
    expect(tester.widget<Text>(gb).maxLines, 1);
    await tester.ensureVisible(gb);
    await tester.tap(gb);
    await tester.pumpAndSettle();
    expect(settings.unit, SizeUnit.decimal);
    expect(find.text('1 GB = 1,000 MB'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'SMART lists drives, keeps zero counters and handles missing data',
    (tester) async {
      var loads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SmartPage(
              settings: const AppSettings(),
              load: () async {
                loads++;
                return [
                  SmartDisk({
                    'number': 0,
                    'model': 'Fixture NVMe',
                    'bus': 'NVMe',
                    'metrics': {
                      'warning': true,
                      'warningBits': 2,
                      'temperature': 47,
                      'powerOnHours': '0',
                      'wear': 6,
                    },
                  }),
                  SmartDisk({
                    'number': 2,
                    'model': 'Fixture USB',
                    'bus': 'USB',
                  }),
                ];
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('47 °C'), findsOneWidget);
      expect(find.text('0 小时'), findsOneWidget);
      expect(find.text('有 SMART 告警'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('smart-device')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('磁盘 2 · Fixture USB').last);
      await tester.pumpAndSettle();
      expect(find.text('告警状态未报告'), findsOneWidget);
      expect(find.text('未报告'), findsNWidgets(3));
      await tester.tap(find.text('刷新'));
      await tester.pumpAndSettle();
      expect(loads, 2);
      expect(find.text('告警状态未报告'), findsOneWidget);
    },
  );

  testWidgets('switches mascot character and persists selection', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync('treescan-settings-');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final file = File('${tempDir.path}/settings.json');
    final store = SettingsStore(file);
    var settings = const AppSettings();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SettingsPage(
              settings: settings,
              onChanged: (change) =>
                  setState(() => settings = change(settings)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final geminiChip = find.byKey(const ValueKey('mascot-gemini'));
    expect(geminiChip, findsOneWidget);
    await tester.ensureVisible(geminiChip);
    await tester.pumpAndSettle();
    await tester.tap(geminiChip);
    await tester.pumpAndSettle();
    expect(settings.mascot, MascotCharacter.gemini);

    final loaded = await tester.runAsync(() async {
      await store.save(settings);
      return store.load();
    });
    expect(loaded?.mascot, MascotCharacter.gemini);
  });

  testWidgets('SpaceMap handles selection, hover, and remainder tap', (
    tester,
  ) async {
    ScanItem makeItem(int id, String name, String kind, int bytes) => ScanItem({
      'id': id,
      'parent': 0,
      'name': name,
      'kind': kind,
      'coverage': 'Complete',
      'placeholder': false,
      'sizes': {
        'allocated': {'bytes': '$bytes', 'unknown': 0},
        'logical': {'bytes': '$bytes', 'unknown': 0},
      },
    });

    final dir = makeItem(1, 'folder', 'Directory', 600);
    final file = makeItem(2, 'movie.mp4', 'File', 300);
    final diagram = Diagram([
      SpaceSlice(dir.name, BigInt.from(600), dir),
      SpaceSlice(file.name, BigInt.from(300), file),
      SpaceSlice('', BigInt.from(100), null, hiddenCount: 5),
    ]);
    ScanItem? tapped;
    var remainderTapped = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 300,
            child: SpaceMap(
              diagram: diagram,
              settings: const AppSettings(),
              selection: 1,
              onSelected: (item) => tapped = item,
              onContextMenu: (_, _) {},
              onRemainderTap: () => remainderTapped++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('folder'), findsOneWidget);
    expect(find.text('movie.mp4'), findsOneWidget);
    await tester.tap(find.text('movie.mp4'));
    expect(tapped?.id, 2);
    await tester.tap(find.text('其它 5 项'));
    expect(remainderTapped, 1);

    final extremeDiagram = Diagram([
      SpaceSlice(
        'huge.iso',
        BigInt.from(10000000000),
        makeItem(10, 'huge.iso', 'File', 10000000000),
      ),
      SpaceSlice('tiny.txt', BigInt.one, makeItem(11, 'tiny.txt', 'File', 1)),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 300,
            child: SpaceMap(
              diagram: extremeDiagram,
              settings: const AppSettings(),
              selection: null,
              onSelected: (_) {},
              onContextMenu: (_, _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('huge.iso'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('formatCount and formatPercent format edge cases cleanly', () {
    expect(formatCount(0), '0');
    expect(formatCount(999), '999');
    expect(formatCount(1000), '1,000');
    expect(formatCount(1234567), '1,234,567');
    expect(formatPercent(BigInt.zero, BigInt.from(100)), '0%');
    expect(formatPercent(BigInt.from(1), BigInt.from(5000)), '<0.1%');
    expect(formatPercent(BigInt.from(342), BigInt.from(1000)), '34.2%');
    expect(formatPercent(BigInt.from(1000), BigInt.from(1000)), '100%');
  });
}
