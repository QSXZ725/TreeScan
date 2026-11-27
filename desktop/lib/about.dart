import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'crash_log.dart';
import 'desktop_shell.dart';
import 'directory_picker.dart';
import 'mascot.dart';
import 'settings.dart';

const githubRepository = String.fromEnvironment('TREESCAN_GITHUB_REPOSITORY');
const officialRelease = bool.fromEnvironment('TREESCAN_OFFICIAL_RELEASE');

class GitHubRelease {
  const GitHubRelease(this.version, this.page);

  final String version;
  final Uri page;

  static final _repository = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$',
  );
  static final _version = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$');

  static List<int> _parts(String version) {
    final match = _version.firstMatch(version);
    if (match == null) throw const FormatException('Invalid release version');
    return List.generate(3, (index) => int.parse(match.group(index + 1)!));
  }

  bool isNewerThan(String current, {required bool preview}) {
    final latest = _parts(version);
    final installed = _parts(current.split('+').first);
    for (var index = 0; index < latest.length; index++) {
      if (latest[index] != installed[index]) {
        return latest[index] > installed[index];
      }
    }
    return preview;
  }

  static Future<GitHubRelease?> latest(String repository) async {
    if (!_repository.hasMatch(repository)) {
      throw const FormatException('Invalid GitHub repository');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final endpoint = Uri.https(
        'api.github.com',
        '/repos/$repository/releases/latest',
      );
      final request = await client
          .getUrl(endpoint)
          .timeout(const Duration(seconds: 10));
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      request.headers.set(HttpHeaders.userAgentHeader, 'TreeScan');
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode == HttpStatus.notFound) return null;
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}', uri: endpoint);
      }
      final json =
          jsonDecode(
                await response
                    .transform(utf8.decoder)
                    .join()
                    .timeout(const Duration(seconds: 10)),
              )
              as Map<String, dynamic>;
      final tag = json['tag_name'] as String;
      _parts(tag);
      return GitHubRelease(
        tag.startsWith('v') ? tag.substring(1) : tag,
        Uri.https('github.com', '/$repository/releases/tag/$tag'),
      );
    } finally {
      client.close(force: true);
    }
  }
}

class AboutPage extends StatefulWidget {
  const AboutPage({super.key, required this.settings, required this.shell});

  final AppSettings settings;
  final MethodChannel shell;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  static bool _licenseRegistered = false;
  String? _version = const bool.hasEnvironment('TREESCAN_VERSION')
      ? const String.fromEnvironment('TREESCAN_VERSION')
      : null;
  int? _build = const bool.hasEnvironment('TREESCAN_BUILD_NUMBER')
      ? const int.fromEnvironment('TREESCAN_BUILD_NUMBER')
      : null;
  String? _message;
  GitHubRelease? _update;
  bool _checking = false;

  String Function(String, String) get _t => widget.settings.text;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await widget.shell.invokeMapMethod<String, Object?>(
        'appVersion',
      );
      if (mounted && info != null) {
        setState(() {
          _version = (info['version'] as String).split('+').first;
          _build = info['build'] as int;
        });
      }
    } on PlatformException catch (error) {
      if (mounted) setState(() => _message = error.message);
    }
  }

  Future<void> _check() async {
    if (githubRepository.isEmpty) {
      setState(
        () => _message = _t(
          '尚未配置 GitHub 发布仓库。',
          'A GitHub release repository has not been configured.',
        ),
      );
      return;
    }
    setState(() {
      _checking = true;
      _message = null;
      _update = null;
    });
    try {
      final latest = await GitHubRelease.latest(githubRepository);
      if (!mounted) return;
      final installed = _version;
      setState(() {
        if (latest == null) {
          _message = _t('尚无公开发行版。', 'No public release is available.');
        } else if (installed == null ||
            latest.isNewerThan(installed, preview: !officialRelease)) {
          _update = latest;
          _message = _t(
            '最新正式版为 ${latest.version}。',
            'Latest release is ${latest.version}.',
          );
        } else {
          _message = _t('已是最新版本。', 'TreeScan is up to date.');
        }
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = _t('检查更新失败（$error）', 'Update check failed ($error)'),
        );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _openPage(Uri uri) async {
    try {
      if (!Platform.isWindows) {
        await openUnixDesktop(uri.toString());
        return;
      }
      final result = await widget.shell.invokeMapMethod<String, Object?>(
        'open',
        uri.toString(),
      );
      if (result?['error'] != null) {
        throw const FileSystemException('Could not open the browser');
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = _t(
            '无法打开页面（$error）',
            'Could not open the page ($error)',
          ),
        );
      }
    }
  }

  void _showLicenses() {
    if (!_licenseRegistered) {
      LicenseRegistry.addLicense(() async* {
        final directory = File(Platform.resolvedExecutable).parent.path;
        final resources = Platform.isMacOS
            ? '$directory/../Resources'
            : directory;
        for (final name in ['LICENSE', 'THIRD_PARTY_NOTICES.md']) {
          final file = File('$resources/$name');
          if (await file.exists()) {
            yield LicenseEntryWithLineBreaks([
              'TreeScan',
            ], await file.readAsString());
          }
        }
      });
      _licenseRegistered = true;
    }
    showLicensePage(
      context: context,
      applicationName: 'TreeScan',
      applicationVersion: _version,
      applicationLegalese: 'MIT License',
    );
  }

  Future<void> _showCrashLog() async {
    final report = await crashLog.reportAsync();
    if (!mounted) return;
    final events = report['events'] as List<Map<String, Object>>;
    final groups = report['groups'] as List<Map<String, Object>>;
    final export = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('崩溃与异常', 'Crashes and errors')),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _t(
                    '最近 30 天保留 ${events.length} 条记录',
                    '${events.length} reports retained from the last 30 days',
                  ),
                ),
                if (groups.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _t('暂无崩溃或异常记录', 'No crashes or errors recorded'),
                    ),
                  ),
                for (final group in groups)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${group['type']} × ${group['count']}'),
                    subtitle: Text(
                      [
                        '${group['source']} · ${group['version']}',
                        if (group['frame'] case final String frame) frame,
                        DateTime.fromMillisecondsSinceEpoch(
                          group['lastSeenMs'] as int,
                        ).toString().split('.').first,
                      ].join('\n'),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_t('关闭', 'Close')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_t('导出 JSON', 'Export JSON')),
          ),
        ],
      ),
    );
    if (export != true || !mounted) return;
    final directory = await pickScanDirectory(
      context,
      widget.shell,
      widget.settings,
      null,
      saving: true,
    );
    if (directory == null || !mounted) return;
    final file = File(
      '$directory/TreeScan-crash-report-${report['generatedAtMs']}-$pid.json',
    );
    try {
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
        flush: true,
      );
      if (mounted) {
        setState(
          () => _message = _t(
            '诊断已导出到 ${file.path}',
            'Diagnostics exported to ${file.path}',
          ),
        );
      }
    } on FileSystemException catch (error) {
      if (mounted) {
        setState(
          () => _message = _t(
            '无法导出诊断（$error）',
            'Could not export diagnostics ($error)',
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
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
                    Image.asset(
                      'assets/treescan-logo.png',
                      width: 56,
                      height: 56,
                      excludeFromSemantics: true,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _t('关于 TreeScan', 'About TreeScan'),
                            style: theme.textTheme.headlineSmall,
                          ),
                          Text(
                            'Build by Codex',
                            style: theme.textTheme.titleMedium,
                          ),
                          if (_version case final version?)
                            Text(
                              officialRelease
                                  ? version
                                  : _t(
                                      '$version · 构建 ${_build ?? 0}',
                                      '$version · Build ${_build ?? 0}',
                                    ),
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Material(
                  color: colors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: colors.outlineVariant),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.article_outlined),
                        title: Text(_t('开源协议', 'Open-source license')),
                        subtitle: const Text('MIT'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: _showLicenses,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.palette_outlined),
                        title: Text(_t('看板娘素材', 'Mascot artwork')),
                        subtitle: const Text(
                          'CrossPet · ZipZipPipe · CC BY-NC-SA 4.0',
                        ),
                        trailing: const Icon(
                          Icons.open_in_new_rounded,
                          size: 18,
                        ),
                        onTap: () => _openPage(Uri.parse(mascotSource)),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.auto_awesome_outlined),
                        title: Text(
                          _t('Gemini 看板娘素材', 'Gemini mascot artwork'),
                        ),
                        subtitle: const Text('CrossPet · CC BY-NC-SA 4.0'),
                        trailing: const Icon(
                          Icons.open_in_new_rounded,
                          size: 18,
                        ),
                        onTap: () => _openPage(Uri.parse(geminiMascotSource)),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.monitor_heart_outlined),
                        title: Text(_t('崩溃与异常', 'Crashes and errors')),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: _showCrashLog,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    onPressed: _checking ? null : _check,
                    icon: _checking
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.system_update_alt_rounded),
                    label: Text(_t('检查更新', 'Check for updates')),
                  ),
                ),
                if (_message case final message?)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(message),
                  ),
                if (_update case final release?)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => _openPage(release.page),
                      child: Text(_t('查看 GitHub 发行版', 'Open GitHub release')),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
