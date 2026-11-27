import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'about.dart';
import 'crash_log.dart';
import 'desktop_shell.dart';
import 'directory_picker.dart';
import 'mascot.dart';
import 'scanner.dart';
import 'settings.dart';
import 'smart.dart';
import 'treemap.dart';

part 'workspace_view.dart';

const _shell = MethodChannel('org.treescan/windows');
const _blue = Color(0xff275acb);

enum _FileCommand { open, copy, cut, paste, delete, copyPath, reveal }

enum _WorkspacePage { scan, smart, settings, about }

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  final frameworkHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    crashLog.record(
      'flutter-framework',
      details.exception.runtimeType.toString(),
      details.stack,
    );
    frameworkHandler?.call(details);
  };
  final dispatcher = PlatformDispatcher.instance;
  final previousHandler = dispatcher.onError;
  dispatcher.onError = (error, stack) {
    crashLog.record('dart-unhandled', error.runtimeType.toString(), stack);
    return previousHandler?.call(error, stack) ?? false;
  };
  unawaited(_loadCrashVersion());
  String? initial;
  if (args.length == 2 && args.first == '--scan') {
    initial = args[1];
  } else if (args.length == 1 && !args.first.startsWith('-')) {
    initial = args.first;
  }
  runApp(TreeScanApp(initialDirectory: initial));
}

Future<void> _loadCrashVersion() async {
  if (!Platform.isWindows) return;
  try {
    final version = await _shell.invokeMapMethod<String, Object?>('appVersion');
    if (version?['version'] case final String name) {
      crashLog.version = '${name.split('+').first}+${version!['build']}';
    }
  } on Exception {
    return;
  }
}

class TreeScanApp extends StatefulWidget {
  const TreeScanApp({super.key, this.initialDirectory, this.settingsFile});

  final String? initialDirectory;
  final File? settingsFile;

  @override
  State<TreeScanApp> createState() => _TreeScanAppState();
}

class _TreeScanAppState extends State<TreeScanApp> with WidgetsBindingObserver {
  late final _store = SettingsStore(widget.settingsFile);
  AppSettings _settings = const AppSettings();
  String? _settingsError;
  bool _ready = false;
  Future<void> _writes = Future.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadSettings());
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    if (_settings.language == AppLanguage.system) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await _store.load();
      if (mounted) {
        setState(() => _settings = settings);
        unawaited(_updateTitleTheme(settings.theme));
      }
    } catch (error) {
      if (mounted) setState(() => _settingsError = error.toString());
    } finally {
      if (mounted) setState(() => _ready = true);
    }
  }

  void _changeSettings(SettingsChange change) {
    final settings = change(_settings);
    final themeChanged = settings.theme != _settings.theme;
    setState(() => _settings = settings);
    if (themeChanged) unawaited(_updateTitleTheme(settings.theme));
    _writes = _writes.then((_) async {
      try {
        await _store.save(settings);
        if (mounted) setState(() => _settingsError = null);
      } catch (error) {
        if (mounted) setState(() => _settingsError = error.toString());
      }
    });
  }

  Future<void> _updateTitleTheme(ThemeMode theme) async {
    if (!Platform.isWindows) return;
    try {
      await _shell.invokeMethod<void>(
        'titleTheme',
        theme == ThemeMode.system ? null : theme == ThemeMode.dark,
      );
    } on MissingPluginException {
      return;
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'TreeScan',
    debugShowCheckedModeBanner: false,
    locale: Locale(_settings.chinese ? 'zh' : 'en'),
    supportedLocales: const [Locale('zh'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    themeMode: _settings.theme,
    home: _ready
        ? _Workspace(
            initialDirectory: widget.initialDirectory,
            settings: _settings,
            onSettingsChanged: _changeSettings,
            settingsError: _settingsError,
          )
        : const SizedBox.shrink(),
  );

  ThemeData _theme(Brightness brightness) {
    final colors = ColorScheme.fromSeed(
      seedColor: _blue,
      brightness: brightness,
      primary: brightness == Brightness.light ? _blue : null,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surfaceContainerLow,
      fontFamily: Platform.isWindows ? 'Segoe UI' : null,
      fontFamilyFallback: Platform.isWindows
          ? const ['Microsoft YaHei UI']
          : null,
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: colors.surfaceContainerLow,
        border: OutlineInputBorder(
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
      ),
    );
  }
}

class _Workspace extends StatefulWidget {
  const _Workspace({
    this.initialDirectory,
    required this.settings,
    required this.onSettingsChanged,
    this.settingsError,
  });

  final String? initialDirectory;
  final AppSettings settings;
  final ValueChanged<SettingsChange> onSettingsChanged;
  final String? settingsError;

  @override
  State<_Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<_Workspace>
    with SingleTickerProviderStateMixin {
  final _scanner = Scanner();
  final _expanded = <int>{0};
  final _pageLimits = <int, int>{};
  final _clock = Stopwatch();
  final _stopClock = Stopwatch();
  final _treeScroll = ScrollController();
  final _rankingScroll = ScrollController();
  final _filterController = TextEditingController();
  final _filterFocus = FocusNode();
  final _workspaceFocus = FocusNode();
  late final _pageAnimation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: 1,
  );
  late final _graphicsAdapter = _readGraphicsAdapter();
  late final Future<List<VolumeEntry>> _quickVolumes = _loadQuickVolumes();
  Timer? _timer;

  String? _rootPath;
  String? _sourcePath;
  String? _error;
  ScanProgress? _progress;
  ScanItem? _selected;
  ScanItem? _directory;
  List<ScanItem> _breadcrumbs = const [];
  final _pageCache = <Metric, Map<int, VisiblePages>>{};
  Map<int, VisiblePages> get _pages => _pageCache[_metric] ?? const {};
  List<({ScanItem? item, int? more, int depth, BigInt? parentBytes})>
  _flattened = const [];
  List<ScanItem> _top = [];
  Diagram? _diagram;
  Future<int?>? _wslHostAllocation;
  Metric _metric = Metric.allocated;
  var _revision = 0;
  var _starting = false;
  var _checking = false;
  var _wantUpdate = false;
  var _refreshDiagram = false;
  var _diagramStale = false;
  var _showFiles = false;
  var _stopPending = false;
  var _workspacePage = _WorkspacePage.scan;
  final _visitedPages = <_WorkspacePage>{_WorkspacePage.scan};
  var _wslRoot = false;
  var _editingFiles = false;
  var _filter = '';
  var _filterOpen = false;
  var _splitRatio = 0.48;
  int? _hoveredId;
  int? _pendingScrollToId;
  int? _firstFrameMs;
  int? _stopFrameMs;

  bool get _busy => _starting || (_progress?.busy ?? false);
  AppSettings get _settings => widget.settings;
  String Function(String, String) get _t => _settings.text;

  Future<List<VolumeEntry>> _loadQuickVolumes() async {
    try {
      return await loadLocalVolumeEntries(
        _shell,
        _settings,
        includeHome: false,
        includeWsl: false,
      );
    } on Exception {
      return const [];
    }
  }

  void _ensurePolling() {
    _timer ??= Timer.periodic(const Duration(milliseconds: 140), (_) {
      if (_progress?.busy == true) unawaited(_update());
    });
  }

  void _stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  Future<String?> _readGraphicsAdapter() async {
    if (!Platform.isWindows) return null;
    try {
      return await _shell.invokeMethod<String>('graphicsAdapter');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<void> _notifyScanComplete(int files, {required bool rescanned}) async {
    if (!Platform.isWindows || !_settings.scanNotifications) return;
    final message = rescanned
        ? _t('重扫完成，已扫描 $files 个文件。', 'Rescan complete. Scanned $files files.')
        : _t('扫描完成，已扫描 $files 个文件。', 'Scan complete. Scanned $files files.');
    try {
      await _shell.invokeMethod<bool>('scanCompleteNotification', message);
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  Future<int?>? _readWslHostAllocation(String path) {
    if (!_isWslPath(path)) return null;
    final parts = path.split(r'\');
    final index = path.startsWith(r'\\?\') ? 5 : 3;
    if (parts.length <= index || parts[index].isEmpty) return null;
    return _shell
        .invokeMethod<int>('wslHostAllocation', parts[index])
        .then((bytes) => bytes, onError: (Object _) => null);
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialDirectory case final path?) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_start(path));
      });
    }
  }

  @override
  void dispose() {
    _stopPolling();
    _pageAnimation.dispose();
    _treeScroll.dispose();
    _rankingScroll.dispose();
    _filterController.dispose();
    _filterFocus.dispose();
    _workspaceFocus.dispose();
    _scanner.close();
    super.dispose();
  }

  void _report(Object error) {
    if (mounted) setState(() => _error = error.toString());
  }

  void _changed({bool diagram = false}) {
    _revision++;
    _wantUpdate = true;
    _refreshDiagram |= diagram;
    unawaited(_update());
  }

  Future<void> _start(String path, {bool wslRoot = false}) async {
    if (path.isEmpty || _busy || _editingFiles) return;
    _revision++;
    _clock
      ..reset()
      ..start();
    setState(() {
      _starting = true;
      _workspacePage = _WorkspacePage.scan;
      _error = null;
      _firstFrameMs = null;
      _stopFrameMs = null;
      _diagramStale = false;
    });
    try {
      final root = await _scanner.start(
        path,
        workers: _settings.workers,
        wslRoot: wslRoot,
      );
      if (!mounted) return;
      _ensurePolling();
      setState(() {
        _rootPath = root;
        _sourcePath = path;
        _wslHostAllocation = _readWslHostAllocation(root);
        _wslRoot = wslRoot;
        _progress = null;
        _selected = null;
        _directory = null;
        _breadcrumbs = const [];
        _expanded
          ..clear()
          ..add(0);
        _pageLimits.clear();
        _pageCache.clear();
        _flattened = const [];
        _diagram = null;
        _diagramStale = false;
        _top = [];
        _stopPending = false;
        _hoveredId = null;
        _pendingScrollToId = null;
      });
    } catch (error) {
      _clock.stop();
      _report(error);
    } finally {
      if (mounted) {
        setState(() => _starting = false);
        _changed(diagram: true);
      }
    }
  }

  Future<void> _stop() async {
    if (_stopPending || _progress?.busy != true) return;
    _stopClock
      ..reset()
      ..start();
    setState(() => _stopPending = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _stopClock.stop();
      if (mounted) {
        setState(() => _stopFrameMs = _stopClock.elapsedMilliseconds);
      }
    });
    try {
      await _scanner.request('stop');
      _changed();
    } catch (error) {
      if (mounted) setState(() => _stopPending = false);
      _report(error);
    }
  }

  Future<void> _refreshDirectory() => _refreshAt(_directory?.id ?? 0);

  Future<void> _refreshAt(int id) async {
    final current = _progress;
    if (_busy || current == null) return;
    setState(() {
      _starting = true;
      _error = null;
      _stopFrameMs = null;
    });
    try {
      await _scanner.request('refresh', {
        'id': id,
        'generation': current.generation,
      });
      _ensurePolling();
    } catch (error) {
      _report(error);
    } finally {
      if (mounted) {
        setState(() => _starting = false);
        _changed();
      }
    }
  }

  Future<void> _update() async {
    if (!mounted || _checking || _starting || _rootPath == null) return;
    _checking = true;
    final viewRevision = _revision;
    final force = _wantUpdate;
    final refreshDiagram = _refreshDiagram;
    final metric = _metric;
    final previous = _progress;
    final expanded = Set<int>.of(_expanded);
    _wantUpdate = false;
    _refreshDiagram = false;
    try {
      final progress = await _scanner.poll(expanded);
      final newGeneration =
          previous != null && previous.generation != progress.generation;
      final finished = previous?.busy == true && !progress.busy;
      final changed =
          force ||
          previous?.revision != progress.revision ||
          newGeneration ||
          finished;
      var directory = _directory;
      var selected = _selected;
      if (newGeneration) {
        directory = await _scanner.find(
          directory?.path ?? _rootPath!,
          progress.generation,
        );
        final selectedPath = selected?.path;
        selected = selectedPath == null
            ? null
            : await _scanner.find(selectedPath, progress.generation);
        expanded
          ..clear()
          ..add(0);
        var parent = directory;
        while (parent != null) {
          expanded.add(parent.id);
          final id = parent.parent;
          parent = id == null
              ? null
              : await _scanner.node(id, progress.generation);
        }
      } else if (changed && selected != null) {
        selected = await _scanner.node(selected.id, progress.generation);
      }
      final currentDirectory = directory?.id ?? 0;
      final pages = <int, VisiblePages>{
        if (!newGeneration) ...?_pageCache[metric],
      }..removeWhere((id, _) => !expanded.contains(id));
      for (final id in expanded) {
        final limit = newGeneration ? 80 : _pageLimits[id] ?? 80;
        final kept = pages[id];
        if (kept != null &&
            kept.limit == limit &&
            kept.revision == progress.directoryRevisions[id]) {
          continue;
        }
        final page = await _scanner.visiblePages(
          id,
          progress.generation,
          metric,
          limit,
          kept,
        );
        if (page != null) pages[id] = page;
      }
      var diagram = _diagram;
      var diagramUpdated = false;
      if (refreshDiagram ||
          newGeneration ||
          finished ||
          diagram == null ||
          (diagram.items.isEmpty && changed)) {
        final page = await _scanner.page(
          currentDirectory,
          progress.generation,
          metric,
          limit: 48,
        );
        final info = currentDirectory == 0
            ? progress.root
            : await _scanner.node(currentDirectory, progress.generation);
        if (page != null && info != null) {
          diagram = Diagram.fromPage(info, page, metric);
          diagramUpdated = true;
        }
      }
      final top = _showFiles && changed
          ? await _scanner.top(progress.generation, metric)
          : _top;
      if (!mounted || viewRevision != _revision) {
        _refreshDiagram |= refreshDiagram;
        return;
      }
      if (!progress.busy) _stopPolling();
      setState(() {
        _progress = progress;
        if (finished && _wslHostAllocation != null) {
          _wslHostAllocation = _readWslHostAllocation(_rootPath!);
        }
        _directory = directory;
        if (directory == null) {
          _breadcrumbs = [progress.root];
        } else if (newGeneration) {
          _breadcrumbs = [progress.root, if (directory.id != 0) directory];
        }
        _selected = selected;
        _expanded
          ..clear()
          ..addAll(expanded);
        if (newGeneration) {
          _pageLimits.clear();
          _pageCache.clear();
        }
        _pageCache[metric] = pages;
        _diagram = diagram;
        if (diagramUpdated) {
          _diagramStale = false;
        } else if (changed && progress.busy && diagram != null) {
          _diagramStale = true;
        }
        _top = top;
        if (!progress.busy) _stopPending = false;
        if (progress.error != null) _error = progress.error;
        _rebuildFlattened();
      });
      if (newGeneration && directory != null) {
        unawaited(_resolveBreadcrumbs(directory, progress.generation));
      }
      if (_pendingScrollToId case final targetId?) {
        if (_flattened.any((row) => row.item?.id == targetId)) {
          _pendingScrollToId = null;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _scrollToNode(targetId);
          });
        }
      }
      if (progress.phase == 'Complete' &&
          (previous == null || finished || newGeneration)) {
        unawaited(
          _notifyScanComplete(
            progress.operationFiles,
            rescanned: newGeneration,
          ),
        );
      }
      if (_firstFrameMs == null &&
          _clock.isRunning &&
          (pages[0]?.rows.any((row) => row.canExpand) ?? false)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && viewRevision == _revision && _clock.isRunning) {
            _clock.stop();
            setState(() => _firstFrameMs = _clock.elapsedMilliseconds);
          }
        });
      }
    } catch (error) {
      _report(error);
    } finally {
      _checking = false;
      if (mounted && _wantUpdate) unawaited(_update());
    }
  }

  Future<void> _activate(
    ScanItem item, {
    bool expand = true,
    bool revealInTree = false,
  }) async {
    final gen = _progress?.generation;
    if (gen == null) return;
    final revision = _revision;
    try {
      final details = item.path != null
          ? item
          : await _scanner.node(item.id, gen);
      if (details == null ||
          !mounted ||
          revision != _revision ||
          gen != _progress?.generation) {
        return;
      }
      final dir = details.isDirectory
          ? details
          : await _scanner.node(details.parent ?? 0, gen);
      final ancestors = <int>{};
      if (revealInTree) {
        var parentId = details.parent;
        while (parentId != null) {
          ancestors.add(parentId);
          final parentNode = await _scanner.node(parentId, gen);
          parentId = parentNode?.parent;
        }
      }
      if (!mounted || revision != _revision || gen != _progress?.generation) {
        return;
      }
      final dirChanged = (_directory?.id ?? 0) != (dir?.id ?? 0);
      var expandedChanged = false;
      setState(() {
        _selected = details;
        _directory = dir;
        if (expand && details.canExpand) {
          expandedChanged |= _expanded.add(details.id);
        }
        for (final id in ancestors) {
          expandedChanged |= _expanded.add(id);
        }
        if (dirChanged) {
          _diagram = null;
          _diagramStale = false;
        }
        _rebuildFlattened();
      });
      if (dirChanged) {
        unawaited(_resolveBreadcrumbs(dir, gen));
      }
      if (revealInTree) {
        if (!expandedChanged &&
            _flattened.any((row) => row.item?.id == details.id)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _scrollToNode(details.id);
          });
        } else {
          _pendingScrollToId = details.id;
        }
      }
      if (dirChanged || expandedChanged) {
        _changed(diagram: dirChanged);
      }
    } catch (error) {
      _report(error);
    }
  }

  Future<void> _chooseFolder() async {
    if (_busy || _editingFiles) return;
    try {
      final folder = await pickScanDirectory(
        context,
        _shell,
        _settings,
        _sourcePath,
      );
      if (folder == null || !mounted) return;
      await _start(folder);
    } catch (error) {
      _report(error);
    }
  }

  Future<void> _action(String action, String path) async {
    try {
      if (action == 'copyPath') {
        await Clipboard.setData(ClipboardData(text: path));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_t('路径已复制', 'Path copied')),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else if (!Platform.isWindows) {
        await openUnixDesktop(path, reveal: action == 'reveal');
      } else {
        await _shell.invokeMethod<void>(action, path);
      }
    } catch (error) {
      _report(error);
    }
  }

  Future<void> _contextMenu(ScanItem row, Offset position) async {
    final generation = _progress?.generation;
    if (generation == null || _editingFiles) return;
    try {
      final item = row.path == null
          ? await _scanner.node(row.id, generation)
          : row;
      if (!mounted || item == null || generation != _progress?.generation) {
        return;
      }
      final path = item.path;
      if (path == null) return;
      final managed =
          item.shellAccessible &&
          item.kind != 'Unknown' &&
          item.kind != 'Mount';
      final parent = item.parent;
      final target = item.isDirectory
          ? item
          : parent == null
          ? null
          : await _scanner.node(parent, generation);
      final available =
          Platform.isWindows &&
          (await _shell.invokeMethod<bool>('hasClipboardFiles') ?? false);
      if (!mounted || generation != _progress?.generation) return;
      setState(() => _selected = item);
      final overlay =
          Overlay.of(context).context.findRenderObject()! as RenderBox;
      final pointing = overlay.globalToLocal(position);

      final command = await showMenu<_FileCommand>(
        context: context,
        position: RelativeRect.fromSize(pointing & Size.zero, overlay.size),
        items: [
          _menuItem(
            _FileCommand.open,
            Icons.open_in_new,
            _t('打开', 'Open'),
            managed,
          ),
          if (Platform.isWindows) ...[
            const PopupMenuDivider(),
            _menuItem(
              _FileCommand.copy,
              Icons.copy_outlined,
              _t('复制', 'Copy'),
              managed && parent != null,
            ),
            _menuItem(
              _FileCommand.cut,
              Icons.content_cut,
              _t('剪切', 'Cut'),
              managed && parent != null,
            ),
            _menuItem(
              _FileCommand.paste,
              Icons.content_paste,
              _t('粘贴', 'Paste'),
              !_busy &&
                  available &&
                  target?.path != null &&
                  target?.shellAccessible == true &&
                  target?.coverage != 'Unreadable',
            ),
            _menuItem(
              _FileCommand.delete,
              Icons.delete_outline,
              _t('删除', 'Delete'),
              !_busy && managed && parent != null,
            ),
          ],
          const PopupMenuDivider(),
          _menuItem(
            _FileCommand.copyPath,
            Icons.link,
            _t('复制路径', 'Copy path'),
            true,
          ),
          _menuItem(
            _FileCommand.reveal,
            Icons.folder_open,
            _t('在文件管理器中显示', 'Show in file manager'),
            managed,
          ),
        ],
      );
      if (command == null ||
          !mounted ||
          generation != _progress?.generation ||
          _editingFiles) {
        return;
      }
      await _executeFileCommand(
        item,
        command,
        generation,
        pasteTarget: target,
        clipboardReady: available,
      );
    } catch (error) {
      _report(error);
    }
  }

  Future<void> _executeFileCommand(
    ScanItem item,
    _FileCommand command,
    int generation, {
    ScanItem? pasteTarget,
    bool? clipboardReady,
  }) async {
    if (_editingFiles || generation != _progress?.generation) return;
    final path = item.path;
    if (path == null) return;
    final managed =
        item.shellAccessible && item.kind != 'Unknown' && item.kind != 'Mount';
    if (command == _FileCommand.copyPath ||
        command == _FileCommand.reveal ||
        (!Platform.isWindows && command == _FileCommand.open)) {
      if (command == _FileCommand.reveal && !managed) return;
      await _action(
        command.name,
        command == _FileCommand.copyPath ? item.displayPath ?? path : path,
      );
      return;
    }
    if (!Platform.isWindows) return;
    if (command == _FileCommand.open && !managed) return;
    if ((command == _FileCommand.copy || command == _FileCommand.cut) &&
        !(managed && item.parent != null)) {
      return;
    }
    if (command == _FileCommand.delete &&
        (_busy || !managed || item.parent == null)) {
      return;
    }
    var targetPath = path;
    if (command == _FileCommand.paste) {
      if (_busy) return;
      final available =
          clipboardReady ??
          (await _shell.invokeMethod<bool>('hasClipboardFiles') ?? false);
      if (!available || !mounted || generation != _progress?.generation) return;
      final target =
          pasteTarget ??
          (item.isDirectory
              ? item
              : item.parent == null
              ? null
              : await _scanner.node(item.parent!, generation));
      if (target?.path == null ||
          target?.shellAccessible != true ||
          target?.coverage == 'Unreadable') {
        return;
      }
      targetPath = target!.path!;
    }
    setState(() => _editingFiles = true);
    try {
      final response = await _shell.invokeMapMethod<String, Object?>(
        command.name,
        targetPath,
      );
      if (mounted && !_busy && generation == _progress?.generation) {
        final paths = (response?['changed'] as List?)?.cast<String>() ?? [];
        await _refreshChangedLocations(paths, generation);
      }
      if (response?['error'] case final int code) {
        final hex = code.toUnsigned(32).toRadixString(16).toUpperCase();
        _report(_t('文件操作失败（0x$hex）', 'File operation failed (0x$hex)'));
      }
    } finally {
      if (mounted) setState(() => _editingFiles = false);
    }
  }

  PopupMenuItem<_FileCommand> _menuItem(
    _FileCommand command,
    IconData icon,
    String title,
    bool enabled,
  ) => PopupMenuItem(
    value: command,
    enabled: enabled,
    child: Row(
      children: [Icon(icon, size: 18), const SizedBox(width: 11), Text(title)],
    ),
  );

  Future<void> _refreshChangedLocations(
    List<String> paths,
    int generation,
  ) async {
    final folders = <int>{};
    for (final path in paths.toSet()) {
      final item = await _scanner.find(path, generation);
      if (item != null) {
        folders.add(item.isDirectory ? item.id : item.parent ?? 0);
      }
    }
    if (mounted && generation == _progress?.generation && folders.isNotEmpty) {
      await _refreshAt(folders.length == 1 ? folders.single : 0);
    }
  }

  void _changeMetric(Metric metric) {
    setState(() {
      _metric = metric;
      _diagram = null;
      _diagramStale = false;
      _top = [];
      _rebuildFlattened();
    });
    _changed(diagram: true);
  }

  void _toggle(int id) {
    setState(() {
      if (_expanded.contains(id)) {
        _collapse(id);
      } else {
        _expanded.add(id);
      }
      _rebuildFlattened();
    });
    _changed();
  }

  void _collapse(int id) {
    _expanded.remove(id);
    final rows = _pages[id]?.rows ?? const <ScanItem>[];
    for (final row in rows) {
      if (_expanded.contains(row.id)) _collapse(row.id);
    }
  }

  Future<void> _goTo(int id) async {
    final current = _progress;
    if (current == null) return;
    final item = await _scanner.node(id, current.generation);
    if (item != null &&
        mounted &&
        _progress?.generation == current.generation) {
      await _activate(item, revealInTree: true);
    }
  }

  void _togglePanel(bool showFiles) {
    if (_showFiles == showFiles) return;
    setState(() => _showFiles = showFiles);
    _changed();
  }

  void _loadMore(int id) {
    _pageLimits[id] = (_pageLimits[id] ?? 80) + 80;
    _changed();
  }

  void _onRemainderTap() {
    final dirId = _directory?.id ?? 0;
    final page = _pages[dirId];
    if (page != null && page.rows.length < page.total) {
      _expanded.add(dirId);
      _loadMore(dirId);
    }
    _scrollToNode(dirId);
  }

  void _rebuildFlattened() {
    final root = _progress?.root;
    if (root == null) {
      _flattened = const [];
      return;
    }
    final query = _filter.trim().toLowerCase();
    final rows =
        <({ScanItem? item, int? more, int depth, BigInt? parentBytes})>[];
    if (query.isEmpty) {
      void visit(ScanItem item, int depth, BigInt? parentBytes) {
        rows.add((
          item: item,
          more: null,
          depth: depth,
          parentBytes: parentBytes,
        ));
        if (!_expanded.contains(item.id)) return;
        final page = _pages[item.id];
        if (page == null) return;
        final selfBytes = item.size(_metric)?.bytes;
        for (final child in page.rows) {
          visit(child, depth + 1, selfBytes);
        }
        if (page.rows.length < page.total) {
          rows.add((
            item: null,
            more: item.id,
            depth: depth + 1,
            parentBytes: null,
          ));
        }
      }

      visit(root, 0, null);
    } else {
      bool collect(ScanItem item, int depth, BigInt? parentBytes) {
        final start = rows.length;
        rows.add((
          item: item,
          more: null,
          depth: depth,
          parentBytes: parentBytes,
        ));
        var keep = item.name.toLowerCase().contains(query);
        if (_expanded.contains(item.id)) {
          final page = _pages[item.id];
          if (page != null) {
            final selfBytes = item.size(_metric)?.bytes;
            for (final child in page.rows) {
              if (collect(child, depth + 1, selfBytes)) keep = true;
            }
          }
        }
        if (!keep && item.id != 0) rows.length = start;
        return keep;
      }

      collect(root, 0, null);
    }
    _flattened = rows;
  }

  Future<void> _resolveBreadcrumbs(ScanItem? dir, int generation) async {
    if (dir == null) {
      final root = _progress?.root;
      if (mounted && _progress?.generation == generation) {
        setState(() => _breadcrumbs = root == null ? const [] : [root]);
      }
      return;
    }
    final chain = <ScanItem>[dir];
    var parentId = dir.parent;
    while (parentId != null) {
      final parent = await _scanner.node(parentId, generation);
      if (parent == null || !mounted || _progress?.generation != generation) {
        return;
      }
      chain.add(parent);
      parentId = parent.parent;
    }
    if (mounted && _progress?.generation == generation) {
      setState(() => _breadcrumbs = chain.reversed.toList(growable: false));
    }
  }

  void _scrollToNode(int id) {
    if (!_treeScroll.hasClients) return;
    final index = _flattened.indexWhere((row) => row.item?.id == id);
    if (index < 0) return;
    const extent = 38.0;
    final top = index * extent;
    final bottom = top + extent;
    final viewport = _treeScroll.position.viewportDimension;
    final offset = _treeScroll.offset;
    if (top < offset || bottom > offset + viewport) {
      final target = (top - viewport * 0.35).clamp(
        0.0,
        _treeScroll.position.maxScrollExtent,
      );
      _treeScroll.jumpTo(target);
    }
  }

  Future<void> _exportSnapshot() async {
    final generation = _progress?.generation;
    if (generation == null || _busy || _editingFiles) return;
    final directory = await pickScanDirectory(
      context,
      _shell,
      _settings,
      _sourcePath,
      saving: true,
    );
    if (directory == null || !mounted || generation != _progress?.generation) {
      return;
    }
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final sep = Platform.pathSeparator;
    final base = directory.endsWith(sep) ? directory : '$directory$sep';
    final filePath = '${base}TreeScan-snapshot-$stamp.json';
    try {
      await _scanner.exportSnapshot(filePath, generation);
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                _t('已导出快照到 $filePath', 'Snapshot exported to $filePath'),
              ),
            ),
          );
      }
    } catch (error) {
      _report(error);
    }
  }

  bool get _editingText {
    final primary = FocusManager.instance.primaryFocus?.context;
    if (primary == null) return false;
    return primary.widget is EditableText ||
        primary.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _toggleFilterBar() {
    if (_workspacePage != _WorkspacePage.scan || _rootPath == null) return;
    setState(() => _filterOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _filterFocus.requestFocus();
    });
  }

  void _closeFilterBar() {
    setState(() {
      _filterOpen = false;
      _filter = '';
      _filterController.clear();
      _rebuildFlattened();
    });
    _workspaceFocus.requestFocus();
  }

  void _shortcutRescan() {
    if (_workspacePage != _WorkspacePage.scan ||
        _rootPath == null ||
        _busy ||
        _editingFiles) {
      return;
    }
    unawaited(_refreshDirectory());
  }

  void _shortcutEscape() {
    if (_filterOpen) {
      _closeFilterBar();
    } else if (_busy && !_stopPending && _progress?.busy == true) {
      unawaited(_stop());
    } else if (_selected != null) {
      _dismissSelection();
    }
  }

  void _shortcutParent() {
    if (_editingText || _workspacePage != _WorkspacePage.scan) return;
    final parentId = _directory?.parent;
    if (parentId != null) unawaited(_goTo(parentId));
  }

  void _shortcutMove(int delta) {
    if (_editingText ||
        _workspacePage != _WorkspacePage.scan ||
        _flattened.isEmpty) {
      return;
    }
    final items = _flattened
        .where((row) => row.item != null)
        .map((row) => row.item!)
        .toList(growable: false);
    if (items.isEmpty) return;
    final current = items.indexWhere((item) => item.id == _selected?.id);
    final nextIndex = current < 0
        ? 0
        : (current + delta).clamp(0, items.length - 1);
    final target = items[nextIndex];
    unawaited(_activate(target, expand: false));
    _scrollToNode(target.id);
  }

  void _shortcutExpand(bool expand) {
    if (_editingText || _workspacePage != _WorkspacePage.scan) return;
    final item = _selected;
    if (item == null) return;
    if (expand) {
      if (item.canExpand && !_expanded.contains(item.id)) _toggle(item.id);
    } else if (item.canExpand && _expanded.contains(item.id)) {
      _toggle(item.id);
    } else if (item.parent case final parentId?) {
      unawaited(_goTo(parentId));
    }
  }

  void _shortcutCopyPath() {
    if (_editingText || _workspacePage != _WorkspacePage.scan) return;
    final item = _selected;
    final path = item?.displayPath ?? item?.path;
    if (path != null) unawaited(_action('copyPath', path));
  }

  void _shortcutFileCommand(_FileCommand command) {
    if (_editingText ||
        _workspacePage != _WorkspacePage.scan ||
        _editingFiles) {
      return;
    }
    final item = _selected;
    final generation = _progress?.generation;
    if (item == null || generation == null) return;
    unawaited(_executeFileCommand(item, command, generation));
  }

  void _dismissError() => setState(() => _error = null);

  void _showPage(_WorkspacePage page) {
    if (_workspacePage == page) return;
    setState(() {
      _workspacePage = page;
      _visitedPages.add(page);
    });
    if (!MediaQuery.disableAnimationsOf(context)) {
      _pageAnimation.forward(from: 0);
    } else {
      _pageAnimation.value = 1;
    }
  }

  void _dismissSelection() => setState(() => _selected = null);

  void _setSplitRatio(double ratio) => setState(() => _splitRatio = ratio);

  void _setHoveredId(int? id) {
    if (_hoveredId != id) setState(() => _hoveredId = id);
  }

  void _setFilter(String value) => setState(() {
    _filter = value;
    _rebuildFlattened();
  });

  @override
  Widget build(BuildContext context) => _buildWorkspace();
}
