import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:jigsawpuzzle/theme/app_palette.dart';
import 'package:jigsawpuzzle/theme/app_text_styles.dart';
import 'package:logging/logging.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// 日志查看页：全屏查看运行日志
///
/// - 数据源：进程内最近 3000 条（内存环形缓冲）+ 当天磁盘日志历史 + 实时订阅
/// - 布局：时间线式（最新日志置顶，向下滚动查看更早）
/// - 能力：实时更新、按等级过滤（全部 / INFO+ / WARN+ / ERROR+）、复制日志、回顶部、清除日志（磁盘文件 + 内存缓存）
class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const LogViewerPage()));
  }

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

/// 视图过滤档位：只展示 >= 该数值等级 的日志（取 package:logging Level.value）
enum LogViewFilter {
  all('', 0),
  info('INFO+', 800),
  warn('WARN+', 900),
  error('ERROR+', 1000);

  const LogViewFilter(this.label, this.minValue);
  final String label;
  final int minValue;
}

/// 单条解析后的日志（含文件续行合并后的完整消息）
class _LogEntry {
  _LogEntry({
    required this.time,
    required this.levelShort,
    required this.levelValue,
    required this.logger,
    required this.message,
  });

  final DateTime time;
  final String levelShort;
  final int levelValue;
  final String logger;
  String message;
}

class _LogViewerPageState extends State<LogViewerPage> {
  /// 完整日志（时间升序）：当天文件历史(前部) + 内存缓冲(尾部) + 实时追加
  final List<_LogEntry> _all = <_LogEntry>[];

  /// 当前过滤后的展示列表（与 [_all] 同序，懒重建）
  final List<_LogEntry> _shown = <_LogEntry>[];

  StreamSubscription<LogRecord>? _sub;
  LogViewFilter _filter = LogViewFilter.all;
  bool _historyLoaded = false;
  final ScrollController _scrollController = ScrollController();

  /// 清除代数：每次清除日志 +1，用于丢弃清除前已发起的异步历史加载结果
  int _clearEpoch = 0;

  static const int _maxAllEntries = 20000;
  static const int _maxHistoryFileLines = 15000;

  /// 日志正文等宽样式（常规字重，避免 mono 主题粗体大字号观感）
  static const TextStyle _monoBody = TextStyle(
    fontFamily: 'monospace',
    fontWeight: FontWeight.w400,
    height: 1.3,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// 等级缩写 → 单字母（徽章展示用）
  static String _levelLetterOf(String short) {
    switch (short) {
      case 'TRACE':
        return 'T';
      case 'DEBUG':
        return 'D';
      case 'CONFIG':
        return 'C';
      case 'INFO':
        return 'I';
      case 'WARN':
        return 'W';
      case 'ERROR':
        return 'E';
      case 'FATAL':
        return 'F';
      default:
        return short.isNotEmpty ? short.substring(0, 1) : '?';
    }
  }

  /// 文件行头：`2026-09-06T10:28:45.123 [INFO] [App.Game] msg...`
  static final RegExp _headerRe = RegExp(
    r'^(\d{4}-\d{2}-\d{2}T[\d:.]+(?:Z|[\+\-]\d{2}:\d{2})?) \[(\w+)\] \[([^\]]+)\] (.*)$',
  );

  static int _levelValueOf(String short) {
    switch (short) {
      case 'TRACE':
        return 300;
      case 'DEBUG':
        return 500;
      case 'CONFIG':
        return 700;
      case 'INFO':
        return 800;
      case 'WARN':
        return 900;
      case 'ERROR':
        return 1000;
      case 'FATAL':
        return 1200;
      default:
        return 800;
    }
  }

  @override
  void initState() {
    super.initState();
    // 先以内存缓冲快速渲染
    final snapshot = AppLogger.memoryRecords;
    for (final rec in snapshot) {
      _appendPhysicalLines(AppLogger.formatRecord(rec).split('\n'));
    }
    _rebuildShown();
    // 再订阅实时流
    _sub = AppLogger.liveRecords.listen((rec) {
      if (!mounted) return;
      final entry = _entryFromPhysicalLines(
        AppLogger.formatRecord(rec).split('\n'),
      );
      if (entry == null) return;
      setState(() {
        _addEntry(entry);
      });
    });
    // 最后异步加载当天文件历史（补齐更早日志）
    unawaited(_loadHistory());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  /// 一键回到顶部（最新日志，列表时间线式布局的顶部锚点）
  void _jumpToTop() {
    if (!mounted || !_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  // ---- 行解析 / 合并 ----

  /// 将物理行序列喂入合并器，逐条追加到 [_all]（含实时订阅与内存快照共用逻辑）
  void _appendPhysicalLines(List<String> lines) {
    final entry = _entryFromPhysicalLines(lines);
    if (entry == null) return;
    _addEntry(entry);
  }

  /// 解析一组物理行（首行须为日志头，其余视为该条消息的换行续行），返回合并后条目
  _LogEntry? _entryFromPhysicalLines(List<String> lines) {
    if (lines.isEmpty) return null;
    final m = _headerRe.firstMatch(lines.first);
    if (m == null) return null;
    final time = DateTime.tryParse(m.group(1)!);
    if (time == null) return null;
    final levelShort = m.group(2)!;
    final sb = StringBuffer(m.group(4)!);
    for (var i = 1; i < lines.length; i++) {
      sb.write('\n');
      sb.write(lines[i]);
    }
    return _LogEntry(
      time: time,
      levelShort: levelShort,
      levelValue: _levelValueOf(levelShort),
      logger: m.group(3)!,
      message: sb.toString(),
    );
  }

  void _addEntry(_LogEntry entry) {
    _all.add(entry);
    if (_all.length > _maxAllEntries) {
      // 偶发全量裁剪 + 重建展示列表
      _all.removeRange(0, _all.length - _maxAllEntries);
      _rebuildShown();
      return;
    }
    if (entry.levelValue >= _filter.minValue) {
      // 展示列表最新在前（时间线式：顶部=最新，向下越旧）
      _shown.insert(0, entry);
    }
  }

  /// 依据 [_filter] 重建展示列表（最新在前）
  void _rebuildShown() {
    _shown
      ..clear()
      ..addAll(
        _all.where((e) => e.levelValue >= _filter.minValue).toList().reversed,
      );
  }

  // ---- 历史文件加载 ----

  Future<void> _loadHistory() async {
    final epoch = _clearEpoch;
    var lines = const <String>[];
    try {
      lines = await AppLogger.readTodayLogLines();
      // best-effort：清理/降级失败可静默
      // ignore: avoid_catches_without_on_clauses
    } catch (_) {
      lines = const [];
    }
    if (!mounted) return;
    // 期间发生过清除：丢弃此次读取到的旧日志，避免清除后又被回填
    if (epoch != _clearEpoch) {
      setState(() => _historyLoaded = true);
      return;
    }
    // 文件行可能极大，仅保留最新 [_maxHistoryFileLines] 行用于展示
    if (lines.length > _maxHistoryFileLines) {
      lines = lines.sublist(lines.length - _maxHistoryFileLines);
    }

    // 内存记录时间下界：早于该时间(严格小于)的文件行才作为历史补齐，避免与内存重叠
    final firstMemTime = _all.isNotEmpty ? _all.first.time : null;

    // 解析文件行为条目
    final fileEntries = <_LogEntry>[];
    _LogEntry? cur;
    for (final line in lines) {
      final m = _headerRe.firstMatch(line);
      if (m != null) {
        final time = DateTime.tryParse(m.group(1)!);
        if (time == null) continue;
        cur = _LogEntry(
          time: time,
          levelShort: m.group(2)!,
          levelValue: _levelValueOf(m.group(2)!),
          logger: m.group(3)!,
          message: m.group(4)!,
        );
        fileEntries.add(cur);
      } else if (cur != null) {
        cur.message = '${cur.message}\n$line';
      }
    }

    // 截断与内存重叠的尾部（文件与内存时间都有序）
    var cutIndex = fileEntries.length;
    if (firstMemTime != null) {
      for (var i = 0; i < fileEntries.length; i++) {
        if (!fileEntries[i].time.isBefore(firstMemTime)) {
          cutIndex = i;
          break;
        }
      }
    }
    if (cutIndex > 0) {
      setState(() {
        _all.insertAll(0, fileEntries.sublist(0, cutIndex));
        _rebuildShown();
        _historyLoaded = true;
      });
    } else {
      setState(() => _historyLoaded = true);
    }
  }

  // ---- 复制 ----

  String _formatForCopy(_LogEntry e) {
    final t = e.time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final hhmmss = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    return '$hhmmss [${e.levelShort}] [${e.logger}] ${e.message}';
  }

  Future<void> _copyLogs({required bool filteredOnly}) async {
    // 复制按时间升序（旧 → 新），不受展示顺序影响
    final source = filteredOnly
        ? _all.where((e) => e.levelValue >= _filter.minValue)
        : _all;
    if (source.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(t.logs.nothingToCopy),
            duration: const Duration(seconds: 1),
          ),
        );
      }
      return;
    }
    final buf = StringBuffer();
    for (final e in source) {
      buf.writeln(_formatForCopy(e));
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            filteredOnly
                ? t.logs.copiedFiltered(count: _shown.length)
                : t.logs.copiedAll(count: _all.length),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  // ---- 清除 ----

  /// 清除全部日志（磁盘文件 + 内存缓存），需二次确认
  Future<void> _confirmClearLogs() async {
    final palette = AppPalette.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(t.logs.clearConfirmTitle),
        content: Text(t.logs.clearConfirmDesc),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.common.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: palette.error),
            child: Text(t.logs.clearConfirmBtn),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // 置代数使在途历史加载失效
    _clearEpoch++;
    try {
      await AppLogger.clearAll();
      // best-effort：清理/降级失败可静默
      // ignore: avoid_catches_without_on_clauses
    } catch (_) {
      // clearAll 内部已兜底，失败不阻断视图清空
    }
    if (!mounted) return;
    setState(() {
      _all.clear();
      _shown.clear();
      _historyLoaded = true;
    });
    _jumpToTop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(t.logs.clearedToast),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ---- UI ----

  /// 过滤档位 chip 文案（'INFO+' 等为开发者通用术语不翻译，'全部' 本地化）
  String _filterChipLabel(LogViewFilter f) {
    return switch (f) {
      LogViewFilter.all => t.logs.filterAll,
      _ => f.label,
    };
  }

  Color _levelColor(String short, AppPalette palette) {
    switch (short) {
      case 'ERROR':
      case 'FATAL':
        return palette.error;
      case 'WARN':
        return palette.gold;
      case 'INFO':
        return palette.info;
      default:
        return palette.secondaryText;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);

    return Scaffold(
      backgroundColor: palette.surface,
      appBar: AppBar(
        backgroundColor: palette.surface,
        foregroundColor: palette.primaryText,
        elevation: 0.5,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        title: Text(t.logs.title, style: styles.h3.copyWith(fontSize: 19)),
        actions: [
          IconButton(
            tooltip: t.logs.scrollTopTooltip,
            icon: Icon(
              PhosphorIconsBold.arrowFatLinesUp,
              color: palette.brand,
              size: 22,
            ),
            onPressed: _jumpToTop,
          ),
          PopupMenuButton<String>(
            icon: Icon(
              PhosphorIconsBold.copySimple,
              color: palette.brand,
              size: 22,
            ),
            tooltip: t.logs.copyTooltip,
            onSelected: (v) {
              if (v == 'filtered') {
                _copyLogs(filteredOnly: true);
              } else {
                _copyLogs(filteredOnly: false);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'filtered',
                child: Row(
                  children: [
                    Icon(
                      PhosphorIconsRegular.copy,
                      size: 16,
                      color: palette.primaryText,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      t.logs.copyFiltered(count: _shown.length),
                      style: styles.body,
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'all',
                child: Row(
                  children: [
                    Icon(
                      PhosphorIconsRegular.copySimple,
                      size: 16,
                      color: palette.primaryText,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      t.logs.copyAll(count: _all.length),
                      style: styles.body,
                    ),
                  ],
                ),
              ),
            ],
          ),
          IconButton(
            tooltip: t.logs.clearTooltip,
            icon: Icon(
              PhosphorIconsBold.trashSimple,
              color: palette.error,
              size: 22,
            ),
            onPressed: _confirmClearLogs,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // 等级过滤条
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            color: palette.surfaceContainerLow,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  Text(
                    t.logs.filterPrefix,
                    style: styles.caption.copyWith(
                      color: palette.secondaryText,
                    ),
                  ),
                  const SizedBox(width: 8),
                  for (final f in LogViewFilter.values) ...[
                    ChoiceChip(
                      label: Text(_filterChipLabel(f)),
                      selected: _filter == f,
                      onSelected: (_) => setState(() {
                        _filter = f;
                        _rebuildShown();
                      }),
                      showCheckmark: false,
                      selectedColor: palette.brand,
                      labelStyle: styles.captionBold.copyWith(
                        color: _filter == f
                            ? palette.surface
                            : palette.primaryText,
                      ),
                      backgroundColor: palette.surface,
                      side: BorderSide(color: palette.divider),
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
          ),
          // 日志列表（时间线式：最新置顶，向下滚动查看更早日志）
          Expanded(
            child: _shown.isEmpty
                ? _buildEmpty(palette, styles)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: _shown.length,
                    itemBuilder: (context, index) {
                      final e = _shown[index];
                      return _buildLogLine(e, palette);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(AppPalette palette, AppTextStyles styles) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('📄', style: TextStyle(fontSize: 40)),
          const SizedBox(height: 8),
          Text(
            _historyLoaded ? t.logs.emptyFiltered : t.logs.loading,
            style: styles.body.copyWith(color: palette.secondaryText),
          ),
        ],
      ),
    );
  }

  Widget _buildLogLine(_LogEntry e, AppPalette palette) {
    final levelColor = _levelColor(e.levelShort, palette);
    final t = e.time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final hhmmss = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    final ms = (t.millisecond ~/ 10).toString().padLeft(2, '0');

    return InkWell(
      onTap: () => _showDetail(e, palette),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 级别徽章（单字母）
            Container(
              width: 24,
              padding: const EdgeInsets.symmetric(vertical: 2),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: levelColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: levelColor.withValues(alpha: 0.35),
                ),
              ),
              child: Tooltip(
                message: e.levelShort,
                waitDuration: const Duration(milliseconds: 600),
                child: Text(
                  _levelLetterOf(e.levelShort),
                  style: _monoBody.copyWith(
                    color: levelColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // 时间 + logger + 消息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$hhmmss.$ms  [${e.logger}]',
                    style: _monoBody.copyWith(
                      color: palette.secondaryText,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    e.message,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: _monoBody.copyWith(
                      color: palette.primaryText,
                      fontSize: 13,
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

  /// 点击行查看完整消息（多行 stack 展开）
  void _showDetail(_LogEntry e, AppPalette palette) {
    final styles = AppTextStyles.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(
              PhosphorIconsFill.fileText,
              size: 18,
              color: _levelColor(e.levelShort, palette),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${_levelLetterOf(e.levelShort)} · ${e.logger}',
                style: styles.body.copyWith(
                  color: _levelColor(e.levelShort, palette),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              _formatForCopy(e),
              style: _monoBody.copyWith(fontSize: 13),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.logs.close),
          ),
        ],
      ),
    );
  }
}
