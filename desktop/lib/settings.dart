import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'mascot.dart';

enum AppLanguage { system, chinese, english }

enum SizeUnit { binary, decimal }

enum GraphicsPreference { system, powerSaving, highPerformance }

typedef SettingsChange = AppSettings Function(AppSettings current);

class AppSettings {
  const AppSettings({
    this.language = AppLanguage.chinese,
    this.unit = SizeUnit.binary,
    this.theme = ThemeMode.system,
    this.workers = 0,
    this.showMascot = true,
    this.mascot = MascotCharacter.gpt,
    this.scanNotifications = true,
    this.graphics = GraphicsPreference.system,
  });

  static const workerOptions = [0, 1, 2, 4, 8, 16, 32];

  final AppLanguage language;
  final SizeUnit unit;
  final ThemeMode theme;
  final int workers;
  final bool showMascot;
  final MascotCharacter mascot;
  final bool scanNotifications;
  final GraphicsPreference graphics;

  bool get chinese => switch (language) {
    AppLanguage.chinese => true,
    AppLanguage.english => false,
    AppLanguage.system =>
      PlatformDispatcher.instance.locale.languageCode == 'zh',
  };

  String text(String zh, String en) => chinese ? zh : en;

  AppSettings copyWith({
    AppLanguage? language,
    SizeUnit? unit,
    ThemeMode? theme,
    int? workers,
    bool? showMascot,
    MascotCharacter? mascot,
    bool? scanNotifications,
    GraphicsPreference? graphics,
  }) => AppSettings(
    language: language ?? this.language,
    unit: unit ?? this.unit,
    theme: theme ?? this.theme,
    workers: workers ?? this.workers,
    showMascot: showMascot ?? this.showMascot,
    mascot: mascot ?? this.mascot,
    scanNotifications: scanNotifications ?? this.scanNotifications,
    graphics: graphics ?? this.graphics,
  );
}

class SettingsStore {
  SettingsStore(File? file) : _file = file ?? _defaultFile();

  final File _file;
  Directory get directory => _file.parent;

  static File _defaultFile() {
    final executable = File(Platform.resolvedExecutable).parent;
    if (File('${executable.path}/TreeScan.portable').existsSync()) {
      return File('${executable.path}/settings.json');
    }
    final env = Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'] ?? Directory.systemTemp.path;
    final base = Platform.isMacOS
        ? '$home/Library/Application Support'
        : env['LOCALAPPDATA'] ?? env['XDG_CONFIG_HOME'] ?? '$home/.config';
    return File('$base/TreeScan/settings.json');
  }

  Future<AppSettings> load() async {
    if (!await _file.exists()) return const AppSettings();
    final data = jsonDecode(await _file.readAsString());
    if (data is! Map<String, dynamic>) return const AppSettings();
    return AppSettings(
      language: _value(
        AppLanguage.values,
        data['language'],
        AppLanguage.chinese,
      ),
      unit: _value(SizeUnit.values, data['unit'], SizeUnit.binary),
      theme: _value(ThemeMode.values, data['theme'], ThemeMode.system),
      workers: AppSettings.workerOptions.contains(data['workers'])
          ? data['workers'] as int
          : 0,
      showMascot: data['showMascot'] != false,
      mascot: _value(
        MascotCharacter.values,
        data['mascot'],
        MascotCharacter.gpt,
      ),
      scanNotifications: data['scanNotifications'] != false,
      graphics: _value(
        GraphicsPreference.values,
        data['graphics'],
        GraphicsPreference.system,
      ),
    );
  }

  T _value<T extends Enum>(List<T> values, Object? name, T fallback) =>
      values.where((value) => value.name == name).firstOrNull ?? fallback;

  Future<void> save(AppSettings settings) async {
    await _file.parent.create(recursive: true);
    final pending = File('${_file.path}.$pid.tmp');
    try {
      await pending.writeAsString(
        jsonEncode({
          'language': settings.language.name,
          'unit': settings.unit.name,
          'theme': settings.theme.name,
          'workers': settings.workers,
          'showMascot': settings.showMascot,
          'mascot': settings.mascot.name,
          'scanNotifications': settings.scanNotifications,
          'graphics': settings.graphics.name,
        }),
        flush: true,
      );
      await pending.rename(_file.path);
    } finally {
      if (await pending.exists()) await pending.delete();
    }
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    required this.onChanged,
    this.error,
    this.graphicsAdapter,
    this.shell,
  });

  final AppSettings settings;
  final ValueChanged<SettingsChange> onChanged;
  final String? error;
  final Future<String?>? graphicsAdapter;
  final MethodChannel? shell;

  Future<void> _testNotification(BuildContext context) async {
    final t = settings.text;
    String message;
    try {
      await shell!.invokeMethod<void>(
        'testScanNotification',
        t('这是一条 TreeScan 测试通知。', 'This is a TreeScan test notification.'),
      );
      message = t('Windows 已接收通知请求。', 'Windows accepted the notification.');
    } on PlatformException catch (error) {
      final details = error.details ?? error.code;
      message = error.code == 'notifications-disabled'
          ? t(
              '请在 Windows 通知设置中开启通知。',
              'Enable notifications in Windows Settings.',
            )
          : t(
              '发送通知失败（$details）',
              'Could not send the notification ($details).',
            );
    } on MissingPluginException {
      message = t(
        '当前程序不支持测试通知。',
        'This build does not support test notifications.',
      );
    }
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final t = settings.text;
    final theme = Theme.of(context);
    final appearance = _group(
      context,
      icon: Icons.palette_outlined,
      title: t('语言与外观', 'Language and appearance'),
      children: [
        _field(
          context,
          t('语言', 'Language'),
          _dropdown(
            'language',
            settings.language,
            {
              AppLanguage.system: t('跟随系统', 'System default'),
              AppLanguage.chinese: '简体中文',
              AppLanguage.english: 'English',
            },
            (value) =>
                onChanged((current) => current.copyWith(language: value)),
          ),
        ),
        const SizedBox(height: 20),
        _field(
          context,
          t('主题', 'Theme'),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final (mode, icon, label) in [
                (
                  ThemeMode.system,
                  Icons.brightness_auto_outlined,
                  t('跟随系统', 'System'),
                ),
                (ThemeMode.light, Icons.light_mode_outlined, t('浅色', 'Light')),
                (ThemeMode.dark, Icons.dark_mode_outlined, t('深色', 'Dark')),
              ])
                ChoiceChip(
                  key: ValueKey('theme-${mode.name}'),
                  avatar: Icon(icon, size: 17),
                  label: Text(label),
                  selected: settings.theme == mode,
                  showCheckmark: false,
                  onSelected: (_) =>
                      onChanged((current) => current.copyWith(theme: mode)),
                ),
            ],
          ),
        ),
        if (Platform.isWindows) ...[
          const SizedBox(height: 20),
          _field(
            context,
            t('渲染显卡', 'Graphics adapter'),
            _dropdown(
              'graphics',
              settings.graphics,
              {
                GraphicsPreference.system: t('系统默认', 'System default'),
                GraphicsPreference.powerSaving: t('省电', 'Power saving'),
                GraphicsPreference.highPerformance: t(
                  '高性能',
                  'High performance',
                ),
              },
              (value) =>
                  onChanged((current) => current.copyWith(graphics: value)),
            ),
            hint: t(
              '下次启动 TreeScan 时生效。',
              'Applies the next time TreeScan opens.',
            ),
          ),
          FutureBuilder<String?>(
            future: graphicsAdapter,
            builder: (context, snapshot) {
              final adapter = snapshot.data;
              if (adapter == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  t('当前渲染显卡 $adapter', 'Rendering on $adapter'),
                  style: theme.textTheme.bodySmall,
                ),
              );
            },
          ),
        ],
      ],
    );
    final scanning = _group(
      context,
      icon: Icons.tune_rounded,
      title: t('扫描与统计', 'Scanning and sizes'),
      children: [
        _field(
          context,
          t('容量单位', 'Size units'),
          SegmentedButton<SizeUnit>(
            key: const ValueKey('size-unit'),
            segments: [
              ButtonSegment(
                value: SizeUnit.binary,
                label: const Text('GiB', maxLines: 1),
                tooltip: t('二进制单位', 'Binary units'),
              ),
              ButtonSegment(
                value: SizeUnit.decimal,
                label: const Text('GB', maxLines: 1),
                tooltip: t('十进制单位', 'Decimal units'),
              ),
            ],
            selected: {settings.unit},
            showSelectedIcon: false,
            onSelectionChanged: (values) =>
                onChanged((current) => current.copyWith(unit: values.single)),
          ),
          hint: settings.unit == SizeUnit.binary
              ? '1 GiB = 1,024 MiB'
              : '1 GB = 1,000 MB',
        ),
        const SizedBox(height: 20),
        _field(
          context,
          t('扫描线程', 'Scan threads'),
          _dropdown(
            'workers',
            settings.workers,
            {
              for (final count in AppSettings.workerOptions)
                count: count == 0 ? t('自动', 'Automatic') : '$count',
            },
            (value) => onChanged((current) => current.copyWith(workers: value)),
          ),
          hint: t('下次扫描本地目录时生效。', 'Applies when starting a local scan.'),
        ),
        if (Platform.isWindows) ...[
          const SizedBox(height: 8),
          SwitchListTile(
            key: const ValueKey('scan-notifications'),
            contentPadding: EdgeInsets.zero,
            title: Text(t('后台扫描完成通知', 'Background scan notifications')),
            subtitle: Text(
              t(
                '切到其他应用或最小化时提醒。',
                'Notify me when TreeScan is in the background.',
              ),
            ),
            value: settings.scanNotifications,
            onChanged: (value) => onChanged(
              (current) => current.copyWith(scanNotifications: value),
            ),
          ),
          if (shell != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('test-scan-notification'),
                onPressed: settings.scanNotifications
                    ? () => _testNotification(context)
                    : null,
                icon: const Icon(Icons.notifications_outlined),
                label: Text(t('发送测试通知', 'Send test notification')),
              ),
            ),
        ],
      ],
    );
    final mascot = _surface(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            key: const ValueKey('show-mascot'),
            contentPadding: const EdgeInsets.fromLTRB(14, 10, 18, 10),
            secondary: MascotPortrait(size: 55, character: settings.mascot),
            title: Text(t('显示看板娘', 'Show mascot')),
            value: settings.showMascot,
            onChanged: (value) =>
                onChanged((current) => current.copyWith(showMascot: value)),
          ),
          if (settings.showMascot) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t('看板娘角色', 'Mascot character'),
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final character in MascotCharacter.values)
                        ChoiceChip(
                          key: ValueKey('mascot-${character.name}'),
                          avatar: MascotPortrait(
                            size: 22,
                            character: character,
                          ),
                          label: Text(character.shortLabel),
                          selected: settings.mascot == character,
                          showCheckmark: false,
                          onSelected: (_) => onChanged(
                            (current) => current.copyWith(mascot: character),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
    final cards = [appearance, scanning, mascot];
    return LayoutBuilder(
      builder: (context, limits) {
        const gap = 16.0;
        final padding = limits.maxWidth < 600 ? 16.0 : 28.0;
        final availableWidth = (limits.maxWidth - 2 * padding).clamp(
          0.0,
          double.infinity,
        );
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final minCardWidth = 320 * textScale.clamp(1.0, double.infinity);
        final columns = ((availableWidth + gap) ~/ (minCardWidth + gap)).clamp(
          1,
          cards.length,
        );
        final cardWidth = ((availableWidth - gap * (columns - 1)) / columns)
            .floorToDouble();

        return ListView(
          padding: EdgeInsets.fromLTRB(padding, 26, padding, 36),
          children: [
            Text(t('设置', 'Settings'), style: theme.textTheme.headlineSmall),
            const SizedBox(height: 20),
            Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final card in cards)
                  SizedBox(width: cardWidth, child: card),
              ],
            ),
            if (error case final message?) ...[
              const SizedBox(height: gap),
              Text(message, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        );
      },
    );
  }

  Widget _surface(BuildContext context, Widget child) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  Widget _group(
    BuildContext context, {
    required IconData icon,
    required String title,
    required List<Widget> children,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return _surface(
      context,
      Padding(
        padding: const EdgeInsets.all(19),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      icon,
                      size: 19,
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: 13),
            const Divider(height: 1),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _field(
    BuildContext context,
    String label,
    Widget control, {
    String? hint,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.titleSmall),
        const SizedBox(height: 7),
        control,
        if (hint != null) ...[
          const SizedBox(height: 5),
          Text(
            hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Widget _dropdown<T>(
    String key,
    T selected,
    Map<T, String> choices,
    ValueChanged<T> onSelected,
  ) => BorderedDropdown<T>(
    dropdownKey: ValueKey(key),
    selected: selected,
    choices: choices,
    onSelected: onSelected,
    maxWidth: double.infinity,
  );
}

class BorderedDropdown<T> extends StatelessWidget {
  const BorderedDropdown({
    super.key,
    this.dropdownKey,
    required this.selected,
    required this.choices,
    required this.onSelected,
    this.maxWidth = 230,
  });

  final Key? dropdownKey;
  final T selected;
  final Map<T, String> choices;
  final ValueChanged<T> onSelected;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(maxWidth: maxWidth),
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          key: dropdownKey,
          value: selected,
          isExpanded: true,
          borderRadius: BorderRadius.circular(10),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          items: [
            for (final choice in choices.entries)
              DropdownMenuItem(
                value: choice.key,
                child: Text(
                  choice.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (value) {
            if (value != null) onSelected(value);
          },
        ),
      ),
    ),
  );
}
