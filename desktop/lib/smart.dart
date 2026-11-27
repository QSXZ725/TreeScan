import 'package:flutter/material.dart';

import 'scanner.dart';
import 'settings.dart';

class SmartDisk {
  SmartDisk(Json disk)
    : number = disk['number'] as int,
      model = disk['model'] as String,
      bus = disk['bus'] as String?,
      firmware = disk['firmware'] as String?,
      size = BigInt.tryParse(disk['size'] as String? ?? ''),
      error = disk['error'] as String?,
      metrics = (disk['metrics'] as Json?) ?? const {};

  final int number;
  final String model;
  final String? bus;
  final String? firmware;
  final BigInt? size;
  final String? error;
  final Json metrics;

  bool? get warning => metrics['warning'] as bool?;
  int? get temperature => metrics['temperature'] as int?;
  int? get wear => metrics['wear'] as int?;
  String? get hours => metrics['powerOnHours'] as String?;
}

Future<List<SmartDisk>> readSmartDisks([Scanner? scanner]) async {
  final worker = scanner ?? Scanner();
  try {
    final reply = await worker
        .request('smart')
        .timeout(const Duration(seconds: 20));
    return (reply as List).cast<Json>().map(SmartDisk.new).toList();
  } finally {
    if (scanner == null) worker.close();
  }
}

class SmartPage extends StatefulWidget {
  const SmartPage({
    super.key,
    required this.settings,
    this.load = readSmartDisks,
  });

  final AppSettings settings;
  final Future<List<SmartDisk>> Function() load;

  @override
  State<SmartPage> createState() => _SmartPageState();
}

class _SmartPageState extends State<SmartPage> {
  late Future<List<SmartDisk>> _query = widget.load();
  int? _selected;

  String Function(String, String) get _t => widget.settings.text;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<SmartDisk>>(
    future: _query,
    builder: (context, snapshot) {
      final loading = snapshot.connectionState != ConnectionState.done;
      final disks = snapshot.data ?? [];
      return ListView(
        padding: const EdgeInsets.fromLTRB(28, 26, 28, 36),
        children: [
          Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _t('磁盘健康', 'Drive health'),
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: loading
                            ? null
                            : () {
                                final query = widget.load();
                                setState(() {
                                  _query = query;
                                });
                              },
                        icon: const Icon(Icons.refresh_rounded),
                        label: Text(_t('刷新', 'Refresh')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (loading) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 10),
                    Text(_t('正在读取物理磁盘…', 'Reading physical drives…')),
                  ] else if (snapshot.hasError)
                    _message(
                      context,
                      _t('无法读取磁盘信息', 'Could not read disk information'),
                      snapshot.error.toString(),
                    )
                  else if (disks.isEmpty)
                    _message(context, _t('未找到物理磁盘', 'No physical drives found'))
                  else
                    _diskInfo(context, disks),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );

  Widget _diskInfo(BuildContext context, List<SmartDisk> disks) {
    final disk =
        disks.where((disk) => disk.number == _selected).firstOrNull ??
        disks.first;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final status = switch (disk.warning) {
      true => (
        _t('有 SMART 告警', 'SMART warning'),
        Icons.warning_amber_outlined,
        colors.errorContainer,
        colors.onErrorContainer,
      ),
      false => (
        _t('无 SMART 告警', 'No SMART warning'),
        Icons.check_circle_outline,
        colors.primaryContainer,
        colors.onPrimaryContainer,
      ),
      null => (
        _t('告警状态未报告', 'Warning status unavailable'),
        Icons.info_outline,
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
      ),
    };
    final details = <(String, String)>[
      if (disk.metrics['spare'] case final int spare)
        (_t('可用备用空间', 'Available spare'), '$spare%'),
      if (disk.metrics['spareThreshold'] case final int threshold)
        (_t('备用空间阈值', 'Spare threshold'), '$threshold%'),
      if (disk.metrics['powerCycles'] case final String count)
        (_t('通电次数', 'Power cycles'), count),
      if (disk.metrics['unsafeShutdowns'] case final String count)
        (_t('非正常关机', 'Unsafe shutdowns'), count),
      if (disk.metrics['mediaErrors'] case final String count)
        (_t('介质与数据完整性错误', 'Media and data integrity errors'), count),
      if (disk.metrics['errorLogEntries'] case final String count)
        (_t('错误日志条目', 'Error log entries'), count),
      if (disk.metrics['readBytes'] case final String bytes)
        (_t('累计读取', 'Lifetime reads'), _size(bytes)),
      if (disk.metrics['writtenBytes'] case final String bytes)
        (_t('累计写入', 'Lifetime writes'), _size(bytes)),
      if (disk.metrics['warningBits'] case final int bits when bits > 0)
        (
          _t('NVMe 告警位', 'NVMe critical warning bits'),
          '0x${bits.toRadixString(16).toUpperCase().padLeft(2, '0')}',
        ),
    ];
    final summary = [
      'PhysicalDrive${disk.number}',
      if (disk.bus case final bus? when bus.isNotEmpty) bus,
      if (disk.size case final size?) formatBytes(size, widget.settings.unit),
      if (disk.firmware case final firmware?)
        _t('固件 $firmware', 'Firmware $firmware'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card(
          context,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _t('物理磁盘', 'Physical drive'),
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              BorderedDropdown<int>(
                dropdownKey: const ValueKey('smart-device'),
                selected: disk.number,
                maxWidth: double.infinity,
                choices: {
                  for (final item in disks)
                    item.number: _t(
                      '磁盘 ${item.number} · ${item.model}',
                      'Drive ${item.number} · ${item.model}',
                    ),
                },
                onSelected: (value) => setState(() => _selected = value),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    summary.join(' · '),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: status.$3,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(status.$2, size: 16, color: status.$4),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              status.$1,
                              style: TextStyle(color: status.$4),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, limits) {
            const gap = 10.0;
            final width = limits.maxWidth;
            final columns = width >= 520
                ? 3
                : width >= 300
                ? 2
                : 1;
            final cardWidth = (width - (columns - 1) * gap) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final (icon, label, value) in [
                  (
                    Icons.thermostat_outlined,
                    _t('温度', 'Temperature'),
                    disk.temperature == null ? null : '${disk.temperature} °C',
                  ),
                  (
                    Icons.schedule_rounded,
                    _t('通电时间', 'Power-on time'),
                    disk.hours == null
                        ? null
                        : _t('${disk.hours} 小时', '${disk.hours} h'),
                  ),
                  (
                    Icons.speed_outlined,
                    _t('已用耐久度', 'Endurance used'),
                    disk.wear == null ? null : '${disk.wear}%',
                  ),
                ])
                  SizedBox(
                    width: cardWidth,
                    child: _metric(context, icon, label, value),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        if (disk.error case final error?)
          _message(context, _t('无法打开此磁盘', 'Could not open this drive'), error)
        else if (details.isEmpty)
          _message(
            context,
            _t(
              '驱动未提供更多 SMART 项目',
              'The driver reported no additional SMART fields',
            ),
          )
        else
          _card(
            context,
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _t('SMART 计数', 'SMART counters'),
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 10),
                for (final (label, value) in details)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        Expanded(child: Text(label)),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            value,
                            textAlign: TextAlign.end,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  String _size(String bytes) {
    final amount = BigInt.tryParse(bytes);
    return amount == null
        ? _t('未报告', 'Not reported')
        : formatBytes(amount, widget.settings.unit);
  }

  Widget _metric(
    BuildContext context,
    IconData icon,
    String label,
    String? value,
  ) {
    final theme = Theme.of(context);
    return _card(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 19, color: theme.colorScheme.primary),
          const SizedBox(height: 6),
          Text(label, style: theme.textTheme.labelMedium),
          const SizedBox(height: 3),
          Text(
            value ?? _t('未报告', 'Not reported'),
            style: theme.textTheme.titleLarge?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _message(BuildContext context, String title, [String? detail]) =>
      _card(
        context,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            if (detail != null) ...[
              const SizedBox(height: 5),
              SelectableText(detail),
            ],
          ],
        ),
      );

  Widget _card(BuildContext context, Widget child) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}
