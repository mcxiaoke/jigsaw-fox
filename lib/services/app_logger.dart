import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 统一日志门面（基于 package:logging）
///
/// 特性：
/// - 分级 Level: ALL/FINEST/FINER/FINE/CONFIG/INFO/WARNING/SEVERE/SHOUT
/// - 控制台：kDebugMode 全量，release 仅 INFO+，走 developer.log / debugPrint
/// - 文件：appSupportDir/logs/app_YYYYMMDD.log，按天滚动，单文件 5MB 切分，保留 7 天 / 50MB
/// - 零侵入：业务直接使用预定义 Logger (AppLogger.game/info 等) 或快捷方法
/// - 异步落盘：队列批量 flush，不阻塞 UI
class AppLogger {
  AppLogger._();

  static bool _initialized = false;
  static bool get isInitialized => _initialized;

  // --- 预定义分类 Logger（建议按模块取用） ---
  static final Logger root = Logger('App');
  static final Logger system = Logger('App.System');
  static final Logger game = Logger('App.Game');
  static final Logger engine = Logger('App.Engine');
  static final Logger cache = Logger('App.Cache');
  static final Logger download = Logger('App.Download');
  static final Logger content = Logger('App.Content');
  static final Logger manifest = Logger('App.Content.Manifest');
  static final Logger mainPipe = Logger('App.Content.Main');
  static final Logger daily = Logger('App.Content.Daily');
  static final Logger events = Logger('App.Content.Events');
  static final Logger pack = Logger('App.Content.Pack');
  static final Logger network = Logger('App.Network');
  static final Logger webview = Logger('App.WebView');
  static final Logger sound = Logger('App.Sound');
  static final Logger repo = Logger('App.Repo');
  static final Logger ui = Logger('App.UI');
  static final Logger imageCache = Logger('App.ImageCache');
  static final Logger thumbnail = Logger('App.Thumbnail');
  static final Logger upscaler = Logger('App.Upscaler');

  // --- 文件落盘状态 ---
  static Directory? _logDir;
  static File? _currentFile;
  static IOSink? _sink;
  static String _currentDay = '';
  static int _currentFileIndex = 0;
  static const int _maxFileBytes = 5 * 1024 * 1024; // 5MB
  static const int _maxTotalBytes = 50 * 1024 * 1024; // 50MB
  static const int _retainDays = 7;
  static Timer? _flushTimer;
  static final List<String> _pendingLines = <String>[];
  static bool _fileEnabled = false;
  static Completer<void>? _initCompleter;

  /// 初始化日志系统，需在 main() 最早调用（WidgetsFlutterBinding 之后）
  static Future<void> init({Level? level}) async {
    if (_initialized) return;
    if (_initCompleter != null) {
      return _initCompleter!.future;
    }
    _initCompleter = Completer<void>();
    hierarchicalLoggingEnabled = true;

    // 级别：debug 全量，release 仅 INFO+
    Logger.root.level = level ??
        (kDebugMode ? Level.ALL : Level.INFO);

    // 监听所有 Logger
    Logger.root.onRecord.listen(_handleRecord);

    // 异步初始化文件目录（不阻塞）
    if (!kIsWeb) {
      unawaited(_initFileAppender());
    }

    _initialized = true;
    _initCompleter!.complete();
    // 自检日志
    system.info(
        'AppLogger initialized level=${Logger.root.level.name} fileEnabled=$_fileEnabled kDebugMode=$kDebugMode');
  }

  /// 动态调整全局级别（可接设置页开关）
  static void setLevel(Level level) {
    Logger.root.level = level;
    system.info('Log level changed to ${level.name}');
  }

  /// 快捷：是否可记录（用于守卫高频日志避免字符串拼接）
  static bool isLoggable(Logger logger, Level level) =>
      logger.isLoggable(level);

  // ---- 快捷静态方法（可选） ----
  static void trace(Logger logger, String msg,
          [Object? err, StackTrace? st, Map<String, Object?>? data]) =>
      _log(logger, Level.FINEST, msg, err, st, data);
  static void debug(Logger logger, String msg,
          [Object? err, StackTrace? st, Map<String, Object?>? data]) =>
      _log(logger, Level.FINE, msg, err, st, data);
  static void info(Logger logger, String msg,
          [Object? err, StackTrace? st, Map<String, Object?>? data]) =>
      _log(logger, Level.INFO, msg, err, st, data);
  static void warn(Logger logger, String msg,
          [Object? err, StackTrace? st, Map<String, Object?>? data]) =>
      _log(logger, Level.WARNING, msg, err, st, data);
  static void error(Logger logger, String msg,
          [Object? err, StackTrace? st, Map<String, Object?>? data]) =>
      _log(logger, Level.SEVERE, msg, err, st, data);
  static void fatal(Logger logger, String msg,
          [Object? err, StackTrace? st, Map<String, Object?>? data]) =>
      _log(logger, Level.SHOUT, msg, err, st, data);

  static void _log(Logger logger, Level level, String msg,
      [Object? err, StackTrace? st, Map<String, Object?>? data]) {
    if (!logger.isLoggable(level)) return;
    var fullMsg = msg;
    if (data != null && data.isNotEmpty) {
      fullMsg = '$msg | ${data.entries.map((e) => '${e.key}=${e.value}').join(' ')}';
    }
    logger.log(level, fullMsg, err, st);
  }

  // ---- 内部：处理每条日志记录 ----
  static void _handleRecord(LogRecord rec) {
    final timeStr = rec.time.toIso8601String();
    final levelStr = _levelToShort(rec.level);
    final loggerName = rec.loggerName;
    final msg = rec.message;
    final errStr = rec.error != null ? ' | error=${rec.error}' : '';
    final stackStr =
        rec.stackTrace != null ? '\n${rec.stackTrace}' : '';

    final line = '$timeStr [$levelStr] [$loggerName] $msg$errStr$stackStr';

    // 控制台
    _writeToConsole(rec, line);

    // 文件
    if (_fileEnabled) {
      _enqueueFileLine(line);
    }
  }

  static String _levelToShort(Level level) {
    if (level == Level.FINEST) return 'TRACE';
    if (level == Level.FINER) return 'TRACE';
    if (level == Level.FINE) return 'DEBUG';
    if (level == Level.CONFIG) return 'CONFIG';
    if (level == Level.INFO) return 'INFO';
    if (level == Level.WARNING) return 'WARN';
    if (level == Level.SEVERE) return 'ERROR';
    if (level == Level.SHOUT) return 'FATAL';
    return level.name;
  }

  static void _writeToConsole(LogRecord rec, String line) {
    // 测试环境静默，避免刷屏
    if (_isTest) return;
    // 使用 developer.log 便于 DevTools 过滤，level 映射
    final devLevel = rec.level.value;
    // 在 debug 模式同时走 debugPrint 保兼容
    if (kDebugMode) {
      // 超长行分段打印
      const chunk = 900;
      if (line.length <= chunk) {
        debugPrint(line);
      } else {
        for (var i = 0; i < line.length; i += chunk) {
          debugPrint(line.substring(
              i, i + chunk > line.length ? line.length : i + chunk));
        }
      }
    }
    // 同时发到 developer.log 便于 IDE 过滤
    try {
      developer.log(
        rec.message,
        time: rec.time,
        level: devLevel,
        name: rec.loggerName,
        error: rec.error,
        stackTrace: rec.stackTrace,
      );
    } catch (_) {}
  }

  static bool get _isTest {
    try {
      return WidgetsBinding.instance.runtimeType.toString().contains('Test');
    } catch (_) {
      return false;
    }
  }

  // ---- 文件落盘 ----
  static Future<void> _initFileAppender() async {
    try {
      final appSupportDir = await getApplicationSupportDirectory();
      _logDir = Directory(p.join(appSupportDir.path, 'logs'));
      if (!await _logDir!.exists()) {
        await _logDir!.create(recursive: true);
      }
      _fileEnabled = true;
      await _rotateIfNeeded(forceNewDay: true);
      _scheduleFlush();
      // 启动时清理旧日志
      unawaited(_cleanupOldLogs());
      system.info('FileAppender enabled dir=${_logDir!.path}');
    } catch (e, st) {
      _fileEnabled = false;
      debugPrint('[AppLogger:File] init failed: $e $st');
    }
  }

  static void _enqueueFileLine(String line) {
    _pendingLines.add(line);
    // 批量阈值或定时 flush
    if (_pendingLines.length >= 20) {
      unawaited(_flushToFile());
    }
  }

  static void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      if (_pendingLines.isNotEmpty) {
        unawaited(_flushToFile());
      }
    });
  }

  static Future<void> _flushToFile() async {
    if (!_fileEnabled || _logDir == null || _pendingLines.isEmpty) return;
    final lines = List<String>.from(_pendingLines);
    _pendingLines.clear();
    try {
      await _rotateIfNeeded();
      _sink ??= _currentFile!.openWrite(mode: FileMode.append);
      for (final l in lines) {
        _sink!.writeln(l);
      }
      await _sink!.flush();
      // 检查单文件大小
      final len = await _currentFile!.length();
      if (len > _maxFileBytes) {
        await _rotateToNextIndex();
      }
    } catch (e) {
      // 落盘失败静默，不影响业务；尝试重建 sink
      try {
        await _sink?.close();
      } catch (_) {}
      _sink = null;
      _fileEnabled = false;
      debugPrint('[AppLogger:File] flush failed: $e');
    }
  }

  static Future<void> _rotateIfNeeded({bool forceNewDay = false}) async {
    if (_logDir == null) return;
    final now = DateTime.now();
    final dayStr =
        '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final needNewDay = forceNewDay || _currentDay != dayStr || _currentFile == null;
    if (needNewDay) {
      _currentDay = dayStr;
      // 查找当日已有最大索引
      var maxIdx = 0;
      try {
        final files = _logDir!.listSync().whereType<File>().toList();
        for (final f in files) {
          final name = p.basename(f.path);
          final m = RegExp(r'^app_(\d{8})(?:_(\d+))?\.log$').firstMatch(name);
          if (m != null && m.group(1) == dayStr) {
            final idx = int.tryParse(m.group(2) ?? '0') ?? 0;
            if (idx > maxIdx) maxIdx = idx;
          }
        }
        // 若当天已有文件且未超限则续写，否则新建索引 0
        final candidate = File(p.join(_logDir!.path, 'app_$dayStr.log'));
        if (await candidate.exists()) {
          final len = await candidate.length();
          if (len < _maxFileBytes) {
            _currentFile = candidate;
            _currentFileIndex = 0;
            await _sink?.close();
            _sink = null;
            return;
          } else {
            maxIdx = 1;
          }
        }
        if (maxIdx == 0) {
          _currentFile = candidate;
          _currentFileIndex = 0;
        } else {
          // 已有超限，找下一个可用索引
          _currentFileIndex = maxIdx;
          var f = File(p.join(_logDir!.path, 'app_${dayStr}_$_currentFileIndex.log'));
          while (await f.exists() && await f.length() > _maxFileBytes) {
            _currentFileIndex++;
            f = File(p.join(_logDir!.path, 'app_${dayStr}_$_currentFileIndex.log'));
          }
          _currentFile = f;
        }
      } catch (_) {
        _currentFile = File(p.join(_logDir!.path, 'app_$dayStr.log'));
        _currentFileIndex = 0;
      }
      await _sink?.close();
      _sink = null;
      if (!await _currentFile!.exists()) {
        await _currentFile!.create(recursive: true);
      }
    }
  }

  static Future<void> _rotateToNextIndex() async {
    if (_logDir == null || _currentFile == null) return;
    try {
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    _currentFileIndex++;
    final next = File(p.join(_logDir!.path, 'app_${_currentDay}_$_currentFileIndex.log'));
    _currentFile = next;
    if (!await next.exists()) {
      await next.create(recursive: true);
    }
  }

  static Future<void> _cleanupOldLogs() async {
    if (_logDir == null) return;
    try {
      final now = DateTime.now();
      final files = _logDir!
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('app_'))
          .toList();
      // 按修改时间排序
      files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
      // 1. 按天数清理
      for (final f in List<File>.from(files)) {
        final stat = await f.stat();
        final age = now.difference(stat.modified).inDays;
        if (age > _retainDays) {
          try {
            await f.delete();
            files.remove(f);
          } catch (_) {}
        }
      }
      // 2. 按总大小清理（保留最新）
      var total = 0;
      for (final f in files) {
        total += await f.length();
      }
      while (total > _maxTotalBytes && files.isNotEmpty) {
        final oldest = files.removeAt(0);
        try {
          final len = await oldest.length();
          await oldest.delete();
          total -= len;
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 获取日志目录路径（供设置页“导出日志”使用）
  static String? get logDirPath => _logDir?.path;

  /// 获取当前日志文件路径
  static String? get currentLogPath => _currentFile?.path;

  /// 列出所有日志文件（按时间升序）
  static Future<List<File>> listLogFiles() async {
    if (_logDir == null || !await _logDir!.exists()) return [];
    final files = _logDir!
        .listSync()
        .whereType<File>()
        .where((f) => p.basename(f.path).startsWith('app_'))
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  /// 获取日志总大小可读字符串
  static Future<String> getFormattedLogSize() async {
    final files = await listLogFiles();
    var total = 0;
    for (final f in files) {
      try {
        total += await f.length();
      } catch (_) {}
    }
    if (total < 1024) return '$total B';
    if (total < 1024 * 1024) return '${(total / 1024).toStringAsFixed(1)} KB';
    return '${(total / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// 立即刷盘（用于页面退出前）
  static Future<void> flush() async {
    await _flushToFile();
    await _sink?.flush();
  }

  /// 清空所有日志
  static Future<void> clearAll() async {
    _pendingLines.clear();
    try {
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    if (_logDir != null && await _logDir!.exists()) {
      final files = await listLogFiles();
      for (final f in files) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
    await _rotateIfNeeded(forceNewDay: true);
  }

  /// 隐私脱敏：URL 保留 host + path 前缀
  static String sanitizeUrl(String url) {
    if (url.isEmpty) return '';
    try {
      final uri = Uri.parse(url);
      final host = uri.host;
      final path = uri.path;
      final truncated = path.length > 60 ? '${path.substring(0, 60)}...' : path;
      return '$host$truncated${url.length > 120 ? ' (len=${url.length})' : ''}';
    } catch (_) {
      return url.length > 80 ? '${url.substring(0, 80)}...' : url;
    }
  }

  /// 隐私脱敏：文件路径仅保留文件名
  static String sanitizePath(String path) {
    if (path.isEmpty) return '';
    return p.basename(path);
  }
}

// 避免未使用 unawaited 警告
void unawaited(Future<void> f) {}
