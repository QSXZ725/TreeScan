part of 'main.dart';

extension _WorkspaceView on _WorkspaceState {
  ColorScheme get _colors => Theme.of(context).colorScheme;

  static const _tabular = [FontFeature.tabularFigures()];

  Widget _buildWorkspace() {
    final isMac = Platform.isMacOS;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        SingleActivator(
          LogicalKeyboardKey.keyO,
          control: !isMac,
          meta: isMac,
        ): () {
          if (!_busy && !_editingFiles) unawaited(_chooseFolder());
        },
        const SingleActivator(LogicalKeyboardKey.f5): _shortcutRescan,
        SingleActivator(LogicalKeyboardKey.keyR, control: !isMac, meta: isMac):
            _shortcutRescan,
        SingleActivator(LogicalKeyboardKey.keyF, control: !isMac, meta: isMac):
            _toggleFilterBar,
        const SingleActivator(LogicalKeyboardKey.escape): _shortcutEscape,
        const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true):
            _shortcutParent,
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _shortcutMove(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _shortcutMove(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _shortcutExpand(true),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _shortcutExpand(false),
        if (!_readOnlyScan)
          SingleActivator(
            LogicalKeyboardKey.keyC,
            control: !isMac,
            meta: isMac,
            shift: true,
          ): _shortcutCopyPath,
        if (Platform.isWindows && !_readOnlyScan) ...{
          const SingleActivator(LogicalKeyboardKey.delete): () =>
              _shortcutFileCommand(_FileCommand.delete),
          const SingleActivator(LogicalKeyboardKey.keyC, control: true): () =>
              _shortcutFileCommand(_FileCommand.copy),
          const SingleActivator(LogicalKeyboardKey.keyX, control: true): () =>
              _shortcutFileCommand(_FileCommand.cut),
          const SingleActivator(LogicalKeyboardKey.keyV, control: true): () =>
              _shortcutFileCommand(_FileCommand.paste),
        },
      },
      child: Focus(
        focusNode: _workspaceFocus,
        autofocus: true,
        child: Scaffold(
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, limits) => Row(
                children: [
                  _sidebar(
                    compact: limits.maxWidth < 1070,
                    short: limits.maxHeight < 630,
                  ),
                  VerticalDivider(width: 1, color: _colors.outlineVariant),
                  Expanded(child: _page()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _page() {
    final children = <Widget>[
      _scanView(),
      if (_visitedPages.contains(_WorkspacePage.smart))
        SmartPage(settings: _settings, load: () => readSmartDisks(_scanner))
      else
        const SizedBox.shrink(),
      if (_visitedPages.contains(_WorkspacePage.settings))
        SettingsPage(
          settings: _settings,
          onChanged: widget.onSettingsChanged,
          error: widget.settingsError,
          graphicsAdapter: _graphicsAdapter,
          shell: _shell,
        )
      else
        const SizedBox.shrink(),
      if (_visitedPages.contains(_WorkspacePage.about))
        AboutPage(settings: _settings, shell: _shell)
      else
        const SizedBox.shrink(),
    ];
    final stack = IndexedStack(index: _workspacePage.index, children: children);
    if (MediaQuery.disableAnimationsOf(context)) return stack;
    return AnimatedBuilder(
      animation: _pageAnimation,
      child: stack,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_pageAnimation.value);
        return Opacity(
          opacity: 0.35 + 0.65 * t,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - t)),
            child: child,
          ),
        );
      },
    );
  }

  Widget _sidebar({required bool compact, required bool short}) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return Material(
      color: _colors.surface,
      child: AnimatedContainer(
        duration: reducedMotion
            ? Duration.zero
            : const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        width: compact ? 64 : 182,
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(top: 14, bottom: 8),
                child: Column(
                  children: [
                    _sideButton(
                      compact,
                      _readOnlyScan
                          ? _t('管理员只读', 'Admin read-only')
                          : _t('扫描', 'Scan'),
                      _readOnlyScan
                          ? Icons.lock_outline
                          : Icons.space_dashboard_outlined,
                      () => _showPage(_WorkspacePage.scan),
                      selected: _workspacePage == _WorkspacePage.scan,
                    ),
                    const SizedBox(height: 6),
                    _sideButton(
                      compact,
                      _t('选择目录', 'Choose folder'),
                      Icons.create_new_folder_outlined,
                      _busy || _editingFiles ? null : _chooseFolder,
                      key: const ValueKey('choose-folder'),
                    ),
                    if (_sourcePath case final path?) ...[
                      if (!compact)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(15, 10, 15, 5),
                          child: Tooltip(
                            message: _progress?.root.displayPath ?? path,
                            child: Text(
                              _progress?.root.displayPath ?? path,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: _colors.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      _sideButton(
                        compact,
                        _busy
                            ? (_stopPending
                                  ? _t('正在停止', 'Stopping')
                                  : _t('停止扫描', 'Stop scan'))
                            : _t('重新扫描', 'Scan again'),
                        _busy ? Icons.stop_circle_outlined : Icons.refresh,
                        _busy
                            ? (_stopPending || _progress?.busy != true
                                  ? null
                                  : _stop)
                            : (_editingFiles
                                  ? null
                                  : () => _start(path, wslRoot: _wslRoot)),
                        key: const ValueKey('restart-or-stop'),
                      ),
                      if (Platform.isWindows && !_readOnlyScan)
                        _sideButton(
                          compact,
                          _isWslPath(path)
                              ? (_wslRoot
                                    ? _t('普通权限重扫', 'Scan as default user')
                                    : _t('以 WSL root 重扫', 'Scan as WSL root'))
                              : _t('管理员重扫', 'Scan as admin'),
                          Icons.admin_panel_settings_outlined,
                          _busy || _editingFiles
                              ? null
                              : _isWslPath(path)
                              ? () => _start(path, wslRoot: !_wslRoot)
                              : () => _action('elevate', path),
                        ),
                      if (!_readOnlyScan)
                        _sideButton(
                          compact,
                          _t('导出快照', 'Export snapshot'),
                          Icons.download_outlined,
                          _progress == null || _busy || _editingFiles
                              ? null
                              : _exportSnapshot,
                        ),
                      if (_wslRoot && !compact)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'WSL root',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            if (!_readOnlyScan) ...[
              if (_settings.showMascot) _mascot(compact, short),
              const Divider(indent: 12, endIndent: 12),
              if (Platform.isWindows)
                _sideButton(
                  compact,
                  _t('磁盘健康', 'Drive health'),
                  Icons.monitor_heart_outlined,
                  () => _showPage(_WorkspacePage.smart),
                  selected: _workspacePage == _WorkspacePage.smart,
                  key: const ValueKey('open-smart'),
                ),
              _sideButton(
                compact,
                _t('设置', 'Settings'),
                Icons.settings_outlined,
                () => _showPage(_WorkspacePage.settings),
                selected: _workspacePage == _WorkspacePage.settings,
                key: const ValueKey('open-settings'),
              ),
              _sideButton(
                compact,
                _t('关于', 'About'),
                Icons.info_outline,
                () => _showPage(_WorkspacePage.about),
                selected: _workspacePage == _WorkspacePage.about,
                key: const ValueKey('open-about'),
              ),
            ],
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _mascot(bool compact, bool short) {
    final size = compact ? 44.0 : (short ? 86.0 : 114.0);
    return Tooltip(
      message: _t('关于 TreeScan', 'About TreeScan'),
      child: InkWell(
        key: const ValueKey('sidebar-mascot'),
        borderRadius: BorderRadius.circular(14),
        onTap: () => _showPage(_WorkspacePage.about),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 7),
          child: MascotPortrait(
            size: size,
            searching: _busy,
            character: _settings.mascot,
          ),
        ),
      ),
    );
  }

  bool _isWslPath(String path) {
    final value = path.toLowerCase();
    return value.startsWith(r'\\wsl.localhost\') ||
        value.startsWith(r'\\wsl$\') ||
        value.startsWith(r'\\?\unc\wsl.localhost\') ||
        value.startsWith(r'\\?\unc\wsl$\');
  }

  Widget _sideButton(
    bool compact,
    String label,
    IconData icon,
    VoidCallback? onPressed, {
    bool selected = false,
    Key? key,
  }) {
    final style = ButtonStyle(
      backgroundColor: selected
          ? WidgetStatePropertyAll(_colors.primaryContainer)
          : null,
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
      child: compact
          ? IconButton(
              key: key,
              tooltip: label,
              style: style,
              onPressed: onPressed,
              icon: Icon(icon),
            )
          : SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                key: key,
                onPressed: onPressed,
                style: style.copyWith(alignment: Alignment.centerLeft),
                icon: Icon(icon, size: 19),
                label: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
    );
  }

  Widget _scanView() => Column(
    children: [
      if (_error case final error?)
        MaterialBanner(
          leading: const Icon(Icons.error_outline_rounded),
          content: Text(error),
          actions: [
            TextButton(
              onPressed: _dismissError,
              child: Text(_t('关闭', 'Dismiss')),
            ),
          ],
        ),
      if (_rootPath == null)
        Expanded(child: _empty())
      else ...[
        _summary(),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: LayoutBuilder(
              builder: (context, limits) {
                const handleWidth = 10.0;
                final available = math.max(0.0, limits.maxWidth - handleWidth);
                final minLeft = math.min(260.0, available * 0.45);
                final maxLeft = math.max(
                  minLeft,
                  available - math.min(280.0, available * 0.45),
                );
                final leftWidth = (available * _splitRatio).clamp(
                  minLeft,
                  maxLeft,
                );
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: leftWidth, child: _directoryPanel()),
                    MouseRegion(
                      cursor: SystemMouseCursors.resizeColumn,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onDoubleTap: () => _setSplitRatio(0.48),
                        onHorizontalDragUpdate: (details) {
                          if (available <= 0) return;
                          _setSplitRatio(
                            ((leftWidth + details.delta.dx) / available).clamp(
                              0.26,
                              0.74,
                            ),
                          );
                        },
                        child: SizedBox(
                          width: handleWidth,
                          child: Center(
                            child: Container(
                              width: 3,
                              height: 36,
                              decoration: BoxDecoration(
                                color: _colors.outlineVariant,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(child: _resultsPanel()),
                  ],
                );
              },
            ),
          ),
        ),
        if (_selected case final item?) _details(item),
        _status(),
      ],
    ],
  );

  Widget _empty() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: _colors.primaryContainer,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(
              Icons.storage_outlined,
              color: _colors.onPrimaryContainer,
              size: 36,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            _t('查看磁盘占用', 'Explore disk usage'),
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 23),
          ),
          const SizedBox(height: 6),
          Text(
            _t(
              '选择一个磁盘或文件夹，立即分析空间占用',
              'Pick a drive or folder to analyze disk usage',
            ),
            style: TextStyle(color: _colors.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _chooseFolder,
            icon: const Icon(Icons.folder_open_rounded, size: 17),
            label: Text(_t('选择目录', 'Choose folder')),
          ),
          FutureBuilder<List<VolumeEntry>>(
            future: _quickVolumes,
            builder: (context, snapshot) {
              final volumes = snapshot.data;
              if (volumes == null || volumes.isEmpty) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(top: 26),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 660),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    alignment: WrapAlignment.center,
                    children: [
                      for (final volume in volumes) _quickVolumeCard(volume),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    ),
  );

  Widget _quickVolumeCard(VolumeEntry volume) {
    final ratio = volume.usedRatio;
    final free = volume.freeBytes;
    final total = volume.totalBytes;
    return SizedBox(
      width: 204,
      child: _panel(
        InkWell(
          onTap: _busy || _editingFiles ? null : () => _start(volume.path),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(volume.icon, size: 18, color: _colors.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        volume.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
                if (ratio != null && free != null && total != null) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(value: ratio, minHeight: 5),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '${formatBytes(BigInt.from(math.max(0, free)), _settings.unit)} ${_t('可用', 'free')} · ${formatBytes(BigInt.from(math.max(0, total)), _settings.unit)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _colors.onSurfaceVariant,
                      fontSize: 11,
                      fontFeatures: _tabular,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _summary() {
    final progress = _progress;
    final root = progress?.root;
    final cards = [
      _stat(_t('占用空间', 'Allocated'), formatAmount(root?.allocated, _settings)),
      const SizedBox(width: 8),
      _stat(_t('逻辑大小', 'Logical'), formatAmount(root?.logical, _settings)),
      const SizedBox(width: 8),
      _stat(_t('已发现文件', 'Files'), formatCount(progress?.files ?? 0)),
      const SizedBox(width: 8),
      _stat(_t('跳过目录', 'Skipped folders'), formatCount(progress?.skipped ?? 0)),
    ];
    final toggle = SegmentedButton<Metric>(
      segments: [
        for (final metric in Metric.values)
          ButtonSegment(value: metric, label: Text(metric.label(_settings))),
      ],
      selected: {_metric},
      showSelectedIcon: false,
      onSelectionChanged: (choice) => _changeMetric(choice.single),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (_, limits) => limits.maxWidth >= 760
                ? Row(children: [...cards, const SizedBox(width: 12), toggle])
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Row(children: cards),
                      const SizedBox(height: 4),
                      toggle,
                    ],
                  ),
          ),
          if (_wslHostAllocation case final allocation?)
            FutureBuilder<int?>(
              future: allocation,
              builder: (context, snapshot) {
                final bytes = snapshot.data;
                final value = bytes == null
                    ? _t('未报告', 'Not reported')
                    : formatBytes(BigInt.from(bytes), _settings.unit);
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _t(
                      'VHDX 在 Windows 上占用 · $value',
                      'VHDX space on Windows · $value',
                    ),
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontFeatures: _tabular),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _stat(String title, String value) => Expanded(
    child: _panel(
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: _colors.onSurfaceVariant, fontSize: 12),
            ),
            Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 19,
                fontFeatures: _tabular,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _panel(Widget child) => Material(
    color: _colors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(color: _colors.outlineVariant),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );

  Widget _directoryPanel() {
    return _panel(
      Column(
        children: [
          _heading(
            _t('目录树', 'Directory tree'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: _t('过滤已展开项 (Ctrl+F)', 'Filter expanded items'),
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    _filterOpen
                        ? Icons.filter_alt_rounded
                        : Icons.search_rounded,
                    size: 18,
                    color: _filter.isNotEmpty ? _colors.primary : null,
                  ),
                  onPressed: _filterOpen ? _closeFilterBar : _toggleFilterBar,
                ),
                const SizedBox(width: 4),
                Text(
                  '${_metric.label(_settings)} ↓',
                  style: TextStyle(color: _colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (_filterOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: TextField(
                controller: _filterController,
                focusNode: _filterFocus,
                onChanged: _setFilter,
                decoration: InputDecoration(
                  hintText: _t('过滤已加载的名称…', 'Filter loaded names…'),
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  suffixIcon: IconButton(
                    tooltip: _t('关闭过滤', 'Clear filter'),
                    icon: const Icon(Icons.close_rounded, size: 17),
                    onPressed: _closeFilterBar,
                  ),
                ),
              ),
            ),
          Divider(height: 1, color: _colors.outlineVariant),
          Expanded(
            child: Scrollbar(
              controller: _treeScroll,
              child: ListView.builder(
                key: const ValueKey('directory-table'),
                controller: _treeScroll,
                itemCount: _flattened.length,
                itemExtent: 38,
                itemBuilder: (context, index) {
                  final row = _flattened[index];
                  if (row.item case final item?) {
                    return _treeRow(item, row.depth, row.parentBytes);
                  }
                  return Padding(
                    padding: EdgeInsets.only(
                      left: 16.0 + row.depth.clamp(0, 12) * 14,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => _loadMore(row.more!),
                        child: Text(_t('加载更多', 'Load more')),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _treeRow(ScanItem item, int depth, BigInt? parentBytes) {
    final selected = _selected?.id == item.id;
    final hovered = _hoveredId == item.id;
    final opened = _expanded.contains(item.id);
    final itemBytes = item.size(_metric)?.bytes;
    final ratio = shareRatio(itemBytes, parentBytes);
    final showShare =
        parentBytes != null &&
        parentBytes > BigInt.zero &&
        itemBytes != null &&
        itemBytes > BigInt.zero;
    return MouseRegion(
      onEnter: (_) => _setHoveredId(item.id),
      onExit: (_) {
        if (_hoveredId == item.id) _setHoveredId(null);
      },
      child: Ink(
        color: selected
            ? _colors.primaryContainer
            : hovered
            ? _colors.surfaceContainerHighest.withValues(alpha: 0.55)
            : null,
        child: InkWell(
          onTap: () => unawaited(_activate(item)),
          onSecondaryTapUp: (event) =>
              unawaited(_contextMenu(item, event.globalPosition)),
          child: Padding(
            padding: EdgeInsets.only(
              left: 8.0 + depth.clamp(0, 10) * 14,
              right: 12,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: item.canExpand
                      ? IconButton(
                          padding: EdgeInsets.zero,
                          tooltip: opened
                              ? _t('折叠 ${item.name}', 'Collapse ${item.name}')
                              : _t('展开 ${item.name}', 'Expand ${item.name}'),
                          onPressed: () => _toggle(item.id),
                          icon: Icon(
                            opened
                                ? Icons.expand_more_rounded
                                : Icons.chevron_right_rounded,
                            size: 18,
                          ),
                        )
                      : null,
                ),
                Icon(
                  _icon(item, opened),
                  size: 17,
                  color: item.isDirectory
                      ? _colors.primary
                      : _colors.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Tooltip(
                    message: item.name,
                    child: Text(item.name, overflow: TextOverflow.ellipsis),
                  ),
                ),
                if (item.annotation(_settings) case final note?)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 88),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      child: Text(
                        note,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _colors.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                if (showShare) ...[
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 34,
                    height: 4,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: ratio,
                        backgroundColor: _colors.surfaceContainerHighest,
                        color: item.isDirectory
                            ? _colors.primary.withValues(alpha: 0.72)
                            : _colors.secondary.withValues(alpha: 0.72),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      formatPercent(itemBytes, parentBytes),
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: _colors.onSurfaceVariant,
                        fontSize: 11,
                        fontFeatures: _tabular,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                SizedBox(
                  width: 66,
                  child: Text(
                    formatAmount(item.size(_metric), _settings),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFeatures: _tabular,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _resultsPanel() {
    final crumbs = _breadcrumbs.isNotEmpty
        ? _breadcrumbs
        : [
            if (_directory case final dir?)
              dir
            else if (_progress?.root case final root?)
              root,
          ];
    return _panel(
      Column(
        children: [
          _heading(
            _showFiles
                ? _t('大文件排行', 'Largest files')
                : _t('占用分布', 'Space usage'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final tab in [
                  (false, _t('面积图', 'Treemap')),
                  (true, _t('前 100 项', 'Top 100')),
                ])
                  Padding(
                    padding: const EdgeInsets.only(left: 5),
                    child: ChoiceChip(
                      label: Text(tab.$2),
                      selected: _showFiles == tab.$1,
                      showCheckmark: false,
                      onSelected: (_) => _togglePanel(tab.$1),
                    ),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: _colors.outlineVariant),
          if (_showFiles)
            Expanded(child: _ranking())
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
              child: Row(
                children: [
                  IconButton(
                    tooltip: _t('上一级目录', 'Parent folder'),
                    icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                    onPressed: _directory?.parent == null
                        ? null
                        : () => _goTo(_directory!.parent!),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          if (crumbs.isEmpty)
                            Text(
                              _rootPath!,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            )
                          else
                            for (var i = 0; i < crumbs.length; i++) ...[
                              if (i > 0)
                                Icon(
                                  Icons.chevron_right_rounded,
                                  size: 16,
                                  color: _colors.onSurfaceVariant,
                                ),
                              InkWell(
                                borderRadius: BorderRadius.circular(6),
                                onTap: i == crumbs.length - 1
                                    ? null
                                    : () => unawaited(
                                        _activate(crumbs[i], expand: false),
                                      ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 4,
                                  ),
                                  child: Text(
                                    crumbs[i].name,
                                    style: TextStyle(
                                      fontWeight: i == crumbs.length - 1
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                      color: i == crumbs.length - 1
                                          ? _colors.onSurface
                                          : _colors.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                        ],
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _busy || _editingFiles
                        ? null
                        : _refreshDirectory,
                    child: Text(_t('重扫此目录', 'Rescan folder')),
                  ),
                  IconButton(
                    tooltip: _t('刷新面积图', 'Refresh treemap'),
                    onPressed: () => _changed(diagram: true),
                    icon: Badge(
                      isLabelVisible: _busy && _diagramStale,
                      smallSize: 7,
                      child: const Icon(Icons.refresh_rounded, size: 19),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: _diagram == null || _diagram!.items.isEmpty
                    ? Center(
                        child: Text(
                          _t('暂无可绘制的容量', 'No sizes to display'),
                          style: TextStyle(color: _colors.onSurfaceVariant),
                        ),
                      )
                    : SpaceMap(
                        diagram: _diagram!,
                        settings: _settings,
                        selection: _selected?.id,
                        hoveredId: _hoveredId,
                        onHovered: _setHoveredId,
                        onSelected: _activate,
                        onContextMenu: _contextMenu,
                        onRemainderTap: _onRemainderTap,
                      ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _ranking() {
    if (_top.isEmpty) {
      return Center(
        child: Text(
          _t('暂无可排行的文件', 'No files to rank'),
          style: TextStyle(color: _colors.onSurfaceVariant),
        ),
      );
    }
    final rootBytes = _progress?.root.size(_metric)?.bytes;
    return Scrollbar(
      controller: _rankingScroll,
      child: ListView.builder(
        key: const ValueKey('file-ranking'),
        controller: _rankingScroll,
        itemCount: _top.length,
        itemExtent: 50,
        itemBuilder: (context, index) {
          final item = _top[index];
          final selected = _selected?.id == item.id;
          final itemBytes = item.size(_metric)?.bytes;
          final ratio = shareRatio(itemBytes, rootBytes);
          return Ink(
            color: selected ? _colors.primaryContainer : null,
            child: InkWell(
              onTap: () => unawaited(_activate(item, revealInTree: true)),
              onSecondaryTapUp: (event) =>
                  unawaited(_contextMenu(item, event.globalPosition)),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 5,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 28,
                      child: Text(
                        '${index + 1}',
                        style: TextStyle(
                          color: _colors.onSurfaceVariant,
                          fontFeatures: _tabular,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(item.name, overflow: TextOverflow.ellipsis),
                          Text(
                            item.displayPath ?? '',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _colors.onSurfaceVariant,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (rootBytes != null &&
                        rootBytes > BigInt.zero &&
                        itemBytes != null &&
                        itemBytes > BigInt.zero) ...[
                      SizedBox(
                        width: 34,
                        height: 4,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: ratio,
                            backgroundColor: _colors.surfaceContainerHighest,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Text(
                      formatAmount(
                        itemBytes == null ? null : item.size(_metric),
                        _settings,
                      ),
                      style: const TextStyle(fontFeatures: _tabular),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _heading(String title, {required Widget trailing}) => SizedBox(
    height: 51,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
          trailing,
        ],
      ),
    ),
  );

  Widget _details(ScanItem item) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 9),
    child: _panel(
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 5),
        child: Row(
          children: [
            Icon(_icon(item, false), size: 18, color: _colors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Tooltip(
                    message: item.displayPath ?? item.name,
                    child: Text(
                      item.displayPath ?? item.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    [
                      '${_t('占用', 'Allocated')} ${formatAmount(item.allocated, _settings)}',
                      '${_t('逻辑', 'Logical')} ${formatAmount(item.logical, _settings)}',
                      if (item.size(_metric) case Amount(
                        unknown: final unknown,
                      ) when unknown > 0)
                        _t('$unknown 项未知', '$unknown unknown'),
                      if (item.annotation(_settings) case final note?) note,
                      if (item.target case final target?)
                        _t('目标 $target', 'Target $target'),
                    ].join(' · '),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _colors.onSurfaceVariant,
                      fontSize: 12,
                      fontFeatures: _tabular,
                    ),
                  ),
                ],
              ),
            ),
            if (item.path case final path? when !_readOnlyScan) ...[
              IconButton(
                tooltip: _t('复制路径', 'Copy path'),
                icon: const Icon(Icons.copy_rounded, size: 18),
                onPressed: () =>
                    unawaited(_action('copyPath', item.displayPath ?? path)),
              ),
              IconButton(
                tooltip: _t('在文件管理器中显示', 'Show in file manager'),
                icon: const Icon(Icons.folder_open_rounded, size: 19),
                onPressed: item.shellAccessible
                    ? () => unawaited(_action('reveal', path))
                    : null,
              ),
            ],
            if (item.sharedWith case final owner?)
              IconButton(
                tooltip: _t('显示占用归属', 'Show the owning file'),
                icon: const Icon(Icons.link_rounded, size: 19),
                onPressed: () => _goTo(owner),
              ),
            IconButton(
              tooltip: _t('关闭详情', 'Close details'),
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: _dismissSelection,
            ),
          ],
        ),
      ),
    ),
  );

  Widget _status() {
    final progress = _progress;
    final label = _stopPending
        ? _t('已接受停止请求', 'Stop requested')
        : switch (progress?.phase) {
            'Complete' => switch (progress?.root.coverage) {
              'Unreadable' => _t('无法读取目录', 'Cannot read folder'),
              'Partial' => _t('部分完成', 'Partially complete'),
              _ => _t('完成', 'Complete'),
            },
            'Cancelled' => _t('已停止', 'Stopped'),
            'Failed' => _t('扫描失败', 'Scan failed'),
            _ =>
              progress?.refreshing == true
                  ? _t('局部重扫中', 'Rescanning')
                  : (_sourcePath != null &&
                            _isWslPath(_sourcePath!) &&
                            progress?.root.coverage == 'Pending'
                        ? _t('等待 WSL 文件系统', 'Waiting for WSL')
                        : _t('扫描中', 'Scanning')),
          };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Row(
        children: [
          if (_busy)
            const SizedBox.square(
              dimension: 13,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(Icons.circle, color: _colors.primary, size: 8),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              [
                if (progress?.refreshing == true)
                  _t(
                    '已发现 ${formatCount(progress!.operationFiles)} 个文件',
                    '${formatCount(progress.operationFiles)} files found',
                  ),
                if ((progress?.unavailable ?? 0) > 0)
                  _t(
                    '${formatCount(progress!.unavailable)} 个条目无法识别',
                    '${formatCount(progress.unavailable)} entries unavailable',
                  ),
                if (_firstFrameMs case final ms?)
                  _t('首批可浏览 $ms ms', 'First results $ms ms'),
                if (_stopFrameMs case final ms?)
                  _t('停止反馈 $ms ms', 'Stop response $ms ms'),
                if (progress?.stopDrainMs case final ms?)
                  _t(
                    '后台收尾 ${ms.toStringAsFixed(1)} ms',
                    'Background finish ${ms.toStringAsFixed(1)} ms',
                  ),
                if (progress != null)
                  _t(
                    '扫描 ${(progress.elapsedMs / 1000).toStringAsFixed(2)} s',
                    'Scan ${(progress.elapsedMs / 1000).toStringAsFixed(2)} s',
                  ),
              ].join('   ·   '),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: _colors.onSurfaceVariant,
                fontSize: 12,
                fontFeatures: _tabular,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

IconData _icon(ScanItem item, bool open) => switch (item.kind) {
  'Directory' => open ? Icons.folder_open_rounded : Icons.folder_rounded,
  'Link' => Icons.link_rounded,
  'Mount' => Icons.storage_rounded,
  'File' => Icons.insert_drive_file_outlined,
  _ => Icons.help_outline_rounded,
};
