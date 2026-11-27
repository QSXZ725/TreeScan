import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'scanner.dart';
import 'settings.dart';

class VolumeEntry {
  const VolumeEntry({
    required this.name,
    required this.path,
    this.image,
    this.totalBytes,
    this.freeBytes,
    this.icon = Icons.storage_outlined,
  });

  final String name;
  final String path;
  final String? image;
  final int? totalBytes;
  final int? freeBytes;
  final IconData icon;

  double? get usedRatio {
    final total = totalBytes;
    final free = freeBytes;
    if (total == null || free == null || total <= 0) return null;
    return ((total - free) / total).clamp(0.0, 1.0);
  }
}

Future<List<VolumeEntry>> loadLocalVolumeEntries(
  MethodChannel shell,
  AppSettings settings, {
  bool includeHome = true,
  bool includeWsl = true,
}) async {
  final t = settings.text;
  final home =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  final entries = <VolumeEntry>[
    if (includeHome && home != null)
      VolumeEntry(
        name: t('用户目录', 'Home'),
        path: home,
        icon: Icons.home_outlined,
      ),
  ];

  if (!Platform.isWindows) {
    final candidates = <(String, String)>[
      (t('文件系统', 'File system'), '/'),
      (t('挂载卷', 'Mounted volumes'), Platform.isMacOS ? '/Volumes' : '/mnt'),
      if (Platform.isLinux) (t('可移动设备', 'Removable devices'), '/media'),
      if (Platform.isLinux && home != null)
        (
          t('用户挂载卷', 'User mounts'),
          '/run/media/${Platform.environment['USER'] ?? ''}',
        ),
    ];
    final checks = await Future.wait(
      candidates.map((item) => Directory(item.$2).exists()),
    );
    for (var i = 0; i < candidates.length; i++) {
      if (checks[i]) {
        entries.add(
          VolumeEntry(name: candidates[i].$1, path: candidates[i].$2),
        );
      }
    }
    return entries;
  }

  List<Map<Object?, Object?>>? volumeDetails;
  try {
    volumeDetails = await shell.invokeListMethod<Map<Object?, Object?>>(
      'volumeInfo',
    );
  } on MissingPluginException {
    volumeDetails = null;
  } on PlatformException {
    volumeDetails = null;
  }

  final futures = await Future.wait([
    volumeDetails != null
        ? Future<List<String>?>.value(null)
        : shell.invokeListMethod<String>('volumes'),
    includeWsl
        ? shell.invokeListMethod<Map<Object?, Object?>>('wslDisks')
        : Future<List<Map<Object?, Object?>>?>.value(null),
  ]);

  if (volumeDetails != null) {
    for (final volume in volumeDetails) {
      final path = volume['path'] as String?;
      if (path == null || path.isEmpty) continue;
      final label = (volume['label'] as String? ?? '').trim();
      var drive = path;
      while (drive.endsWith(r'\') || drive.endsWith('/')) {
        drive = drive.substring(0, drive.length - 1);
      }
      entries.add(
        VolumeEntry(
          name: label.isEmpty ? path : '$label ($drive)',
          path: path,
          totalBytes: volume['total'] as int?,
          freeBytes: volume['free'] as int?,
        ),
      );
    }
  } else {
    for (final path in (futures[0] ?? []).cast<String>()) {
      entries.add(VolumeEntry(name: path, path: path));
    }
  }

  for (final disk in (futures[1] ?? []).cast<Map<Object?, Object?>>()) {
    entries.add(
      VolumeEntry(
        name: disk['name'] as String,
        path: disk['path'] as String,
        image: disk['image'] as String,
        icon: Icons.dns_outlined,
      ),
    );
  }
  return entries;
}

Future<String?> pickScanDirectory(
  BuildContext context,
  MethodChannel shell,
  AppSettings settings,
  String? initialPath, {
  bool saving = false,
}) => showDialog<String>(
  context: context,
  builder: (_) => _DirectoryPicker(
    initialPath: initialPath,
    shell: shell,
    settings: settings,
    saving: saving,
  ),
);

class _DirectoryPicker extends StatefulWidget {
  const _DirectoryPicker({
    required this.initialPath,
    required this.shell,
    required this.settings,
    required this.saving,
  });

  final String? initialPath;
  final MethodChannel shell;
  final AppSettings settings;
  final bool saving;

  @override
  State<_DirectoryPicker> createState() => _DirectoryPickerState();
}

class _DirectoryPickerState extends State<_DirectoryPicker> {
  final _address = TextEditingController();
  String? _directory;
  List<Directory> _folders = [];
  List<VolumeEntry> _sources = [];
  String? _browseError;
  String? _sourcesError;
  int _request = 0;
  bool _loading = true;
  bool _canScan = false;

  String Function(String, String) get _t => widget.settings.text;

  @override
  void initState() {
    super.initState();
    _loadSources();
    if (widget.initialPath case final path?) _browse(path);
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _loadSources() async {
    try {
      final sources = await loadLocalVolumeEntries(
        widget.shell,
        widget.settings,
      );
      if (!mounted) return;
      final home =
          Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
      setState(() => _sources = sources);
      if (_request == 0) {
        _browse(home ?? (sources.firstOrNull?.path ?? Directory.current.path));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _sourcesError = error.toString());
      if (_request == 0) _browse(Directory.current.path);
    }
  }

  String _withoutTrailingSlashes(String path) =>
      path.replaceAll(RegExp(Platform.isWindows ? r'[/\\]+$' : r'/+$'), '');

  String? _parentOf(String path) {
    if (Platform.isWindows) {
      final normalized = _withoutTrailingSlashes(path.replaceAll('/', r'\'));
      if (normalized.startsWith(r'\\') &&
          normalized.substring(2).split(r'\').length <= 2) {
        return null;
      }
    }
    final parent = Directory(path).parent.path;
    return _withoutTrailingSlashes(parent) == _withoutTrailingSlashes(path)
        ? null
        : parent;
  }

  Future<void> _browse(String path, {bool registeredWslRoot = false}) async {
    final request = ++_request;
    final dir = Directory(path).absolute;
    setState(() {
      _directory = dir.path;
      _address.text = dir.path;
      _loading = true;
      _canScan = registeredWslRoot;
      _folders = [];
      _browseError = null;
    });
    var exists = false;
    try {
      exists = await dir.exists();
      if (!mounted || request != _request) return;
      if (!exists) {
        throw FileSystemException(
          _t('无法访问目录', 'Cannot access folder'),
          dir.path,
        );
      }
      final folders = <Directory>[];
      await for (final entry in dir.list(followLinks: false)) {
        if (!mounted || request != _request) return;
        if (entry is Directory) folders.add(entry);
      }
      folders.sort(
        (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()),
      );
      if (!mounted || request != _request) return;
      setState(() {
        _folders = folders;
        _canScan = true;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _browseError = error.toString();
        _canScan = exists || registeredWslRoot;
        _loading = false;
      });
    }
  }

  void _submitAddress(String input) {
    var path = input.trim();
    if (path.startsWith('"') && path.endsWith('"') && path.length > 1) {
      path = path.substring(1, path.length - 1);
    }
    if (path.isEmpty) return;
    final registered = _sources.any(
      (source) =>
          source.image != null &&
          _withoutTrailingSlashes(source.path) == _withoutTrailingSlashes(path),
    );
    _browse(path, registeredWslRoot: registered);
  }

  String _folderName(String path) => _withoutTrailingSlashes(
    path,
  ).split(RegExp(Platform.isWindows ? r'[/\\]' : '/')).last;

  Widget _sourceTile(VolumeEntry source) {
    final ratio = source.usedRatio;
    final free = source.freeBytes;
    final total = source.totalBytes;
    Widget? subtitle;
    if (source.image case final image?) {
      subtitle = Text(image, maxLines: 1, overflow: TextOverflow.ellipsis);
    } else if (ratio != null && free != null && total != null) {
      final freeText = formatBytes(
        BigInt.from(math.max(0, free)),
        widget.settings.unit,
      );
      subtitle = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(value: ratio, minHeight: 3),
          ),
          const SizedBox(height: 2),
          Text(
            _t('$freeText 可用', '$freeText free'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
        ],
      );
    }
    return Tooltip(
      message: source.image ?? source.path,
      child: ListTile(
        dense: true,
        leading: Icon(source.icon, size: 19),
        title: Text(source.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: subtitle,
        selected:
            _directory != null &&
            _withoutTrailingSlashes(_directory!) ==
                _withoutTrailingSlashes(source.path),
        onTap: () =>
            _browse(source.path, registeredWslRoot: source.image != null),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final parent = _directory == null ? null : _parentOf(_directory!);
    final theme = Theme.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: SizedBox(
        width: 880,
        height: 540,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
              child: Text(
                widget.saving
                    ? _t('选择保存目录', 'Choose a save location')
                    : _t('选择扫描目录', 'Choose a folder to scan'),
                style: theme.textTheme.titleLarge,
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: 208,
                    child: ListView(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      children: [
                        for (final source in _sources.where(
                          (item) => item.image == null,
                        ))
                          _sourceTile(source),
                        if (_sources.any((item) => item.image != null)) ...[
                          const Divider(),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 6, 12, 4),
                            child: Text(
                              _t('WSL 2 虚拟磁盘', 'WSL 2 virtual disks'),
                            ),
                          ),
                          for (final source in _sources.where(
                            (item) => item.image != null,
                          ))
                            _sourceTile(source),
                        ],
                        if (_sourcesError case final error?)
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(error),
                          ),
                      ],
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              IconButton(
                                tooltip: _t('上一级目录', 'Parent folder'),
                                onPressed: parent == null
                                    ? null
                                    : () => _browse(parent),
                                icon: const Icon(Icons.arrow_upward),
                              ),
                              Expanded(
                                child: TextField(
                                  key: const ValueKey('scan-path'),
                                  controller: _address,
                                  onSubmitted: _submitAddress,
                                  decoration: InputDecoration(
                                    hintText: _t(
                                      '输入目录路径',
                                      'Enter a folder path',
                                    ),
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: _t('转到目录', 'Go to folder'),
                                onPressed: () => _submitAddress(_address.text),
                                icon: const Icon(Icons.arrow_forward),
                              ),
                            ],
                          ),
                        ),
                        if (_loading)
                          const LinearProgressIndicator(minHeight: 2),
                        Expanded(
                          child: _browseError != null
                              ? Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(
                                    _browseError!,
                                    style: TextStyle(
                                      color: theme.colorScheme.error,
                                    ),
                                  ),
                                )
                              : !_loading && _folders.isEmpty
                              ? Center(
                                  child: Text(_t('没有子目录', 'No subfolders')),
                                )
                              : ListView.builder(
                                  itemCount: _folders.length,
                                  itemExtent: 36,
                                  itemBuilder: (context, index) {
                                    final path = _folders[index].path;
                                    return ListTile(
                                      dense: true,
                                      leading: const Icon(
                                        Icons.folder_outlined,
                                        size: 20,
                                      ),
                                      title: Text(
                                        _folderName(path),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      onTap: () => _browse(path),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(_t('取消', 'Cancel')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('confirm-scan-folder'),
                    onPressed: _canScan
                        ? () => Navigator.pop(context, _directory)
                        : null,
                    child: Text(
                      widget.saving
                          ? _t('保存到此目录', 'Save to this folder')
                          : _t('扫描此目录', 'Scan this folder'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
