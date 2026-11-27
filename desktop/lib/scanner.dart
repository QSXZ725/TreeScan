import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'crash_log.dart';
import 'settings.dart';

typedef Json = Map<String, dynamic>;

enum Metric {
  allocated,
  logical;

  String label(AppSettings settings) => switch (this) {
    allocated => settings.text('占用空间', 'Allocated size'),
    logical => settings.text('逻辑大小', 'Logical size'),
  };
}

class Amount {
  Amount(Json json)
    : bytes = BigInt.parse(json['bytes'] as String),
      unknown = json['unknown'] as int;

  final BigInt bytes;
  final int unknown;
}

String formatBytes(BigInt bytes, [SizeUnit system = SizeUnit.binary]) {
  final binary = system == SizeUnit.binary;
  final base = binary ? 1024 : 1000;
  if (bytes < BigInt.from(base)) return '$bytes B';
  final units = binary
      ? const ['KiB', 'MiB', 'GiB', 'TiB', 'PiB', 'EiB', 'ZiB', 'YiB']
      : const ['KB', 'MB', 'GB', 'TB', 'PB', 'EB', 'ZB', 'YB'];
  var value = bytes.toDouble() / base;
  var unit = 0;
  while (value >= base && unit < units.length - 1) {
    value /= base;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

String formatAmount(
  Amount? amount, [
  AppSettings settings = const AppSettings(),
]) {
  if (amount == null || (amount.unknown > 0 && amount.bytes == BigInt.zero)) {
    return settings.text('未知', 'Unknown');
  }
  return formatBytes(amount.bytes, settings.unit);
}

String formatCount(int value) {
  final negative = value < 0;
  final digits = (negative ? -value : value).toString();
  final buffer = StringBuffer(negative ? '-' : '');
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) buffer.write(',');
    buffer.write(digits[index]);
  }
  return buffer.toString();
}

double shareRatio(BigInt? part, BigInt? total) {
  if (part == null ||
      total == null ||
      total <= BigInt.zero ||
      part <= BigInt.zero) {
    return 0;
  }
  if (part >= total) return 1;
  return (part * BigInt.from(10000) ~/ total).toDouble() / 10000;
}

String formatPercent(BigInt part, BigInt total) {
  if (total <= BigInt.zero || part <= BigInt.zero) return '0%';
  if (part >= total) return '100%';
  final tenths = (part * BigInt.from(1000)) ~/ total;
  if (tenths == BigInt.zero) return '<0.1%';
  return '${(tenths.toDouble() / 10).toStringAsFixed(1)}%';
}

class ScanItem {
  ScanItem(Json json)
    : id = json['id'] as int,
      parent = json['parent'] as int?,
      name = json['name'] as String,
      kind = json['kind'] as String,
      coverage = json['coverage'] as String,
      target = json['target'] as String?,
      path = json['path'] as String?,
      displayPath = (json['displayPath'] ?? json['path']) as String?,
      shellAccessible = json['shellAccessible'] != false,
      placeholder = json['placeholder'] as bool,
      sharedWith = json['sharedWith'] as int?,
      allocated = _size(json, 'allocated'),
      logical = _size(json, 'logical');

  static Amount? _size(Json json, String key) {
    final value = (json['sizes'] as Json?)?[key] as Json?;
    return value == null ? null : Amount(value);
  }

  final int id;
  final int? parent;
  final String name;
  final String kind;
  final String coverage;
  final String? target;
  final String? path;
  final String? displayPath;
  final bool shellAccessible;
  final bool placeholder;
  final int? sharedWith;
  final Amount? allocated;
  final Amount? logical;

  bool get isDirectory => kind == 'Directory';
  bool get canExpand => isDirectory && coverage != 'Unreadable';

  Amount? size(Metric metric) => metric == Metric.logical ? logical : allocated;

  String? annotation(AppSettings settings) {
    final t = settings.text;
    if (sharedWith != null) return t('共享占用', 'Shared storage');
    if (coverage == 'Pending') return t('未访问', 'Pending');
    if (coverage == 'Partial') return t('部分统计', 'Partial');
    if (coverage == 'Unreadable') {
      return placeholder
          ? t('云目录 · 未枚举', 'Cloud folder · skipped')
          : t('无法访问', 'Inaccessible');
    }
    if (kind == 'Mount') return t('挂载卷', 'Mount');
    if (kind == 'Link') return t('链接', 'Link');
    if (kind == 'Unknown') return t('无法识别', 'Unavailable');
    if (placeholder) return t('云占位', 'Cloud placeholder');
    if (!shellAccessible) return t('Linux 专用路径', 'Linux-only path');
    return null;
  }
}

class DirectoryPage {
  DirectoryPage(Json json)
    : total = json['total'] as int,
      rows = (json['rows'] as List).cast<Json>().map(ScanItem.new).toList();

  final int total;
  final List<ScanItem> rows;
}

class VisiblePages {
  factory VisiblePages(Json json, int limit, VisiblePages? previous) {
    final pages = (json['pages'] as List).cast<Json>();
    final windows = [
      for (var index = 0; index < pages.length; index++)
        pages[index]['rows'] == null
            ? previous!._windows[index]
            : (pages[index]['rows'] as List)
                  .cast<Json>()
                  .map(ScanItem.new)
                  .toList(growable: false),
    ];
    return VisiblePages._(
      json['total'] as int,
      json['revision'] as int,
      limit,
      pages.map((page) => page['stamp'] as String).toList(growable: false),
      windows,
    );
  }

  VisiblePages._(
    this.total,
    this.revision,
    this.limit,
    this.stamps,
    this._windows,
  ) : rows = _windows.expand((window) => window).toList(growable: false);

  final int total;
  final int revision;
  final int limit;
  final List<String> stamps;
  final List<List<ScanItem>> _windows;
  final List<ScanItem> rows;
}

class ScanProgress {
  ScanProgress(Json json, List<int> directories)
    : phase = json['phase'] as String,
      refreshing = json['refreshing'] as bool,
      generation = json['generation'] as int,
      revision = json['revision'] as int,
      directoryRevisions = Map.fromIterables(
        directories,
        (json['directoryRevisions'] as List).cast<int?>(),
      ),
      files = json['files'] as int,
      skipped = json['skipped'] as int,
      unavailable = json['unavailable'] as int,
      operationFiles = json['operationFiles'] as int,
      elapsedMs = (json['elapsedMs'] as num).toDouble(),
      stopDrainMs = (json['stopDrainMs'] as num?)?.toDouble(),
      error = json['error'] as String?,
      root = ScanItem(json['root'] as Json);

  final String phase;
  final bool refreshing;
  final int generation;
  final int revision;
  final Map<int, int?> directoryRevisions;
  final int files;
  final int skipped;
  final int unavailable;
  final int operationFiles;
  final double elapsedMs;
  final double? stopDrainMs;
  final String? error;
  final ScanItem root;

  bool get busy => phase == 'Running' || phase == 'Stopping';
}

class Scanner {
  Scanner() {
    _replies.listen(_receive);
    unawaited(_spawn());
  }

  final _replies = ReceivePort();
  final _ready = Completer<SendPort>();
  final _pending = <int, Completer<Object?>>{};
  var _nextId = 0;
  bool _closed = false;

  Future<void> _spawn() async {
    try {
      await Isolate.spawn(
        _worker,
        _replies.sendPort,
        onError: _replies.sendPort,
        onExit: _replies.sendPort,
        debugName: 'TreeScan native queries',
      );
    } catch (error, stack) {
      crashLog.record('scanner-isolate', error.runtimeType.toString(), stack);
      _fail(error.toString());
    }
  }

  void _receive(dynamic message) {
    if (message is SendPort) {
      _ready.complete(message);
      if (_closed) message.send(null);
    } else if (message == null) {
      _fail('扫描服务已关闭');
      _replies.close();
    } else if (message is List && message[0] is int) {
      final reply = _pending.remove(message[0]);
      if (message[1] == true) {
        reply?.complete(message[2]);
      } else {
        reply?.completeError(ScanFailure(message[2] as String));
      }
    } else if (message is List) {
      if (!_closed && message.length == 2 && message[1] is String) {
        crashLog.record(
          'scanner-isolate',
          'UnhandledWorkerError',
          StackTrace.fromString(message[1] as String),
        );
      }
      _fail(message.first.toString());
    }
  }

  void _fail(String error) {
    if (!_ready.isCompleted) _ready.completeError(ScanFailure(error));
    for (final reply in _pending.values) {
      reply.completeError(ScanFailure(error));
    }
    _pending.clear();
  }

  Future<Object?> request(
    String operation, [
    Json parameters = const {},
  ]) async {
    final port = await _ready.future;
    if (_closed) throw const ScanFailure('扫描服务已关闭');
    final id = _nextId++;
    final reply = _pending[id] = Completer<Object?>();
    port.send([
      id,
      {'op': operation, ...parameters},
    ]);
    return reply.future;
  }

  Future<String> start(
    String root, {
    int workers = 0,
    bool wslRoot = false,
  }) async =>
      ((await request('start', {
                'path': root,
                if (workers != 0) 'workers': workers,
                if (wslRoot) 'wslRoot': true,
              }))
              as Json)['root']
          as String;

  Future<ScanProgress> poll(Set<int> directories) async {
    final ids = directories.toList(growable: false);
    return ScanProgress(
      (await request('poll', {'directories': ids})) as Json,
      ids,
    );
  }

  Future<VisiblePages?> visiblePages(
    int id,
    int generation,
    Metric metric,
    int limit,
    VisiblePages? previous,
  ) async {
    final result =
        await request('visiblePages', {
              'id': id,
              'generation': generation,
              'logical': metric == Metric.logical,
              'limit': limit,
              if (previous != null) 'stamps': previous.stamps,
            })
            as Json?;
    return result == null ? null : VisiblePages(result, limit, previous);
  }

  Future<DirectoryPage?> page(
    int id,
    int generation,
    Metric metric, {
    int offset = 0,
    int limit = 100,
  }) async {
    final result =
        await request('page', {
              'id': id,
              'generation': generation,
              'logical': metric == Metric.logical,
              'offset': offset,
              'limit': limit,
            })
            as Json?;
    return result == null ? null : DirectoryPage(result);
  }

  Future<List<ScanItem>> top(int generation, Metric metric) async {
    final result =
        await request('top', {
              'generation': generation,
              'logical': metric == Metric.logical,
            })
            as List?;
    return result?.cast<Json>().map(ScanItem.new).toList() ?? [];
  }

  Future<ScanItem?> node(int id, int generation) async {
    final result =
        await request('node', {'id': id, 'generation': generation}) as Json?;
    return result == null ? null : ScanItem(result);
  }

  Future<ScanItem?> find(String path, int generation) async {
    final result =
        await request('find', {
              'path': path,
              'generation': generation,
              'nearest': true,
            })
            as Json?;
    return result == null ? null : ScanItem(result);
  }

  Future<void> exportSnapshot(String path, int generation) async {
    await request('export', {'path': path, 'generation': generation});
  }

  void close() {
    _closed = true;
    unawaited(
      _ready.future.then((port) => port.send(null)).catchError((Object _) {}),
    );
  }
}

class ScanFailure implements Exception {
  const ScanFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

void _worker(SendPort send) {
  final location = File(Platform.resolvedExecutable).parent.path;
  final dll = ffi.DynamicLibrary.open(
    Platform.isWindows
        ? '$location${Platform.pathSeparator}treescan.dll'
        : Platform.isMacOS
        ? '$location/../Frameworks/libtreescan.dylib'
        : '$location/lib/libtreescan.so',
  );
  final open = dll
      .lookupFunction<
        ffi.Pointer<ffi.Void> Function(),
        ffi.Pointer<ffi.Void> Function()
      >('treescan_open');
  final request = dll
      .lookupFunction<
        ffi.Pointer<Utf8> Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Size,
        ),
        ffi.Pointer<Utf8> Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          int,
        )
      >('treescan_request');
  final freeReply = dll
      .lookupFunction<
        ffi.Void Function(ffi.Pointer<Utf8>),
        void Function(ffi.Pointer<Utf8>)
      >('treescan_free_reply');
  final close = dll
      .lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Void>),
        void Function(ffi.Pointer<ffi.Void>)
      >('treescan_close');
  final session = open();
  final incoming = ReceivePort();
  send.send(incoming.sendPort);
  incoming.listen((dynamic message) {
    if (message == null) {
      close(session);
      incoming.close();
      return;
    }
    final id = message[0] as int;
    final input = utf8.encode(jsonEncode(message[1]));
    final buffer = calloc<ffi.Uint8>(input.length);
    try {
      buffer.asTypedList(input.length).setAll(0, input);
      final reply = request(session, buffer, input.length);
      if (reply == ffi.nullptr) throw const ScanFailure('无法读取扫描结果');
      try {
        final result = jsonDecode(reply.toDartString()) as Json;
        final error = result['error'] as String?;
        send.send([id, error == null, error ?? result['value']]);
      } finally {
        freeReply(reply);
      }
    } catch (error) {
      send.send([id, false, error.toString()]);
    } finally {
      calloc.free(buffer);
    }
  });
}
