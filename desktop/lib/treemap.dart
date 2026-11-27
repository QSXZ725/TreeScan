import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'scanner.dart';
import 'settings.dart';

class Diagram {
  const Diagram(this.items);
  final List<SpaceSlice> items;

  factory Diagram.fromPage(
    ScanItem directory,
    DirectoryPage page,
    Metric metric,
  ) {
    final items = [
      for (final item in page.rows)
        if (item.size(metric) case Amount(
          bytes: final bytes,
        ) when bytes > BigInt.zero)
          SpaceSlice(item.name, bytes, item),
    ];
    final displayed = items.fold(BigInt.zero, (sum, item) => sum + item.bytes);
    final remainder = (directory.size(metric)?.bytes ?? displayed) - displayed;
    if (remainder > BigInt.zero && page.total > page.rows.length) {
      items.add(
        SpaceSlice(
          '',
          remainder,
          null,
          hiddenCount: page.total - page.rows.length,
        ),
      );
    }
    items.sort((a, b) => b.bytes.compareTo(a.bytes));
    return Diagram(items);
  }
}

class SpaceSlice {
  const SpaceSlice(this.name, this.bytes, this.item, {this.hiddenCount = 0});
  final String name;
  final BigInt bytes;
  final ScanItem? item;
  final int hiddenCount;
}

class SpaceMap extends StatefulWidget {
  const SpaceMap({
    super.key,
    required this.diagram,
    required this.settings,
    required this.selection,
    required this.onSelected,
    required this.onContextMenu,
    this.hoveredId,
    this.onHovered,
    this.onRemainderTap,
  });

  final Diagram diagram;
  final AppSettings settings;
  final int? selection;
  final int? hoveredId;
  final ValueChanged<ScanItem> onSelected;
  final void Function(ScanItem, Offset) onContextMenu;
  final ValueChanged<int?>? onHovered;
  final VoidCallback? onRemainderTap;

  @override
  State<SpaceMap> createState() => _SpaceMapState();
}

class _SpaceMapState extends State<SpaceMap> {
  Diagram? _cachedDiagram;
  Size? _cachedSize;
  List<Rect> _cachedRects = const [];
  BigInt _cachedTotal = BigInt.zero;

  List<Rect> _rectsFor(Size size) {
    if (!identical(_cachedDiagram, widget.diagram) || _cachedSize != size) {
      _cachedDiagram = widget.diagram;
      _cachedSize = size;
      _cachedRects = layoutTiles(widget.diagram.items, size);
      _cachedTotal = widget.diagram.items.fold(
        BigInt.zero,
        (sum, item) => sum + item.bytes,
      );
    }
    return _cachedRects;
  }

  Rect _insetRect(Rect raw) {
    final dx = raw.width > 2.0 ? 1.0 : 0.0;
    final dy = raw.height > 2.0 ? 1.0 : 0.0;
    return Rect.fromLTRB(
      raw.left + dx,
      raw.top + dy,
      raw.right - dx,
      raw.bottom - dy,
    );
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, limits) {
          final size = Size(limits.maxWidth, limits.maxHeight);
          final rectangles = _rectsFor(size);
          return Stack(
            fit: StackFit.expand,
            children: [
              for (var index = 0; index < rectangles.length; index++) ...[
                Positioned.fromRect(
                  rect: _insetRect(rectangles[index]),
                  child: _tile(
                    widget.diagram.items[index],
                    _insetRect(rectangles[index]).size,
                    index,
                    brightness,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _tile(SpaceSlice tile, Size size, int index, Brightness brightness) {
    final item = tile.item;
    final selected = item != null && item.id == widget.selection;
    final hovered = item != null && item.id == widget.hoveredId;
    final showTitle = size.width >= 72 && size.height >= 30;
    final showSize = size.width >= 82 && size.height >= 54;
    final showPercent = size.width >= 106 && size.height >= 54;
    final capacity = formatBytes(tile.bytes, widget.settings.unit);
    final percent = formatPercent(tile.bytes, _cachedTotal);
    final name = item == null
        ? widget.settings.text(
            '其它 ${tile.hiddenCount} 项',
            '${tile.hiddenCount} more items',
          )
        : tile.name;
    final baseColor = _tileColor(tile, brightness, index);
    final fillColor = hovered
        ? Color.lerp(baseColor, Colors.white, 0.14)!
        : baseColor;
    final side = selected
        ? const BorderSide(color: Color(0xffa8dbff), width: 2.5)
        : hovered
        ? BorderSide(color: Colors.white.withValues(alpha: 0.7), width: 1.5)
        : BorderSide.none;
    return MouseRegion(
      onEnter: item == null ? null : (_) => widget.onHovered?.call(item.id),
      onExit: item == null
          ? null
          : (_) {
              if (widget.hoveredId == item.id) widget.onHovered?.call(null);
            },
      child: Material(
        color: fillColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: side,
        ),
        clipBehavior: Clip.antiAlias,
        child: Tooltip(
          message: '$name\n$capacity ($percent)',
          child: Semantics(
            label: '$name, $capacity, $percent',
            button: item != null || widget.onRemainderTap != null,
            child: InkWell(
              onTap: item != null
                  ? () => widget.onSelected(item)
                  : widget.onRemainderTap,
              onSecondaryTapUp: item == null
                  ? null
                  : (event) => widget.onContextMenu(item, event.globalPosition),
              child: showTitle
                  ? Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 4,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                          if (showSize)
                            Text(
                              showPercent ? '$capacity · $percent' : capacity,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xffe5efff),
                                fontSize: 11,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                        ],
                      ),
                    )
                  : const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

Color _tileColor(SpaceSlice slice, Brightness brightness, int index) {
  final dark = brightness == Brightness.dark;
  final item = slice.item;
  if (item == null) {
    return dark ? const Color(0xff425064) : const Color(0xff526176);
  }
  if (item.isDirectory) {
    const lightDirs = [
      Color(0xff2754ad),
      Color(0xff2f5fbd),
      Color(0xff234b9a),
      Color(0xff3867c4),
    ];
    const darkDirs = [
      Color(0xff234a99),
      Color(0xff2a54ab),
      Color(0xff1e4188),
      Color(0xff325db4),
    ];
    return (dark ? darkDirs : lightDirs)[index % 4];
  }
  final dot = slice.name.lastIndexOf('.');
  final ext = dot > 0 ? slice.name.substring(dot + 1).toLowerCase() : '';
  if (const {
    'mp4',
    'mkv',
    'mov',
    'avi',
    'webm',
    'mp3',
    'flac',
    'wav',
    'png',
    'jpg',
    'jpeg',
    'webp',
    'gif',
    'psd',
  }.contains(ext)) {
    return dark ? const Color(0xff175f6d) : const Color(0xff1b6d7c);
  }
  if (const {
    'zip',
    '7z',
    'rar',
    'tar',
    'gz',
    'xz',
    'iso',
    'img',
    'vhdx',
    'vhd',
    'dmg',
  }.contains(ext)) {
    return dark ? const Color(0xff894722) : const Color(0xff9c5228);
  }
  if (const {
    'exe',
    'dll',
    'so',
    'dylib',
    'msi',
    'apk',
    'deb',
    'rpm',
    'appimage',
    'wasm',
  }.contains(ext)) {
    return dark ? const Color(0xff5e3b7d) : const Color(0xff6b448d);
  }
  if (const {
    'dart',
    'rs',
    'py',
    'js',
    'ts',
    'json',
    'xml',
    'yaml',
    'yml',
    'md',
    'pdf',
    'docx',
    'xlsx',
    'csv',
    'db',
    'sqlite',
  }.contains(ext)) {
    return dark ? const Color(0xff235f4a) : const Color(0xff296d55);
  }
  return dark ? const Color(0xff395073) : const Color(0xff425c82);
}

List<Rect> layoutTiles(List<SpaceSlice> tiles, Size size) {
  if (tiles.isEmpty || size.isEmpty || !size.isFinite) return [];
  final total = tiles.fold(0.0, (sum, tile) => sum + tile.bytes.toDouble());
  final scale = size.width * size.height / total;
  final areas = tiles.map((tile) => tile.bytes.toDouble() * scale).toList();
  var remaining = Offset.zero & size;
  final result = <Rect>[];
  var first = 0;
  while (first < areas.length) {
    final side = math.min(remaining.width, remaining.height);
    if (side <= 0) {
      result.addAll(List.filled(areas.length - first, Rect.zero));
      break;
    }
    var end = first + 1;
    var area = areas[first];
    final largest = areas[first];
    while (end < areas.length) {
      final next = area + areas[end];
      if (_aspect(side, next, largest, areas[end]) >
          _aspect(side, area, largest, areas[end - 1])) {
        break;
      }
      area = next;
      end++;
    }

    final vertical = remaining.width >= remaining.height;
    final thickness = end == areas.length
        ? (vertical ? remaining.width : remaining.height)
        : area / side;
    var position = vertical ? remaining.top : remaining.left;
    for (var index = first; index < end; index++) {
      final length = thickness > 0 ? areas[index] / thickness : 0.0;
      result.add(
        vertical
            ? Rect.fromLTWH(remaining.left, position, thickness, length)
            : Rect.fromLTWH(position, remaining.top, length, thickness),
      );
      position += length;
    }
    remaining = vertical
        ? Rect.fromLTRB(
            remaining.left + thickness,
            remaining.top,
            remaining.right,
            remaining.bottom,
          )
        : Rect.fromLTRB(
            remaining.left,
            remaining.top + thickness,
            remaining.right,
            remaining.bottom,
          );
    first = end;
  }
  return result;
}

double _aspect(double side, double area, double largest, double smallest) {
  final ratio = side * side / (area * area);
  return math.max(largest * ratio, 1 / (smallest * ratio));
}
