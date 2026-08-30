import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import '../../services/app_logger.dart';

/// 任务调度引擎与并发限流器 (Engine Task Queue)
///
/// 核心特性：
/// 1. 严格受控的并发数 (Max Concurrency)：桌面端默认 4，移动端默认 2，支持外部配置；
/// 2. 请求合并去重 (Single Flight)：同一 Key 的任务并发请求时，自动合并为一个后台任务，避免重复计算；
/// 3. 先进先出队列 (FIFO Queue)：超出并发限制的任务平滑排队消费，彻底消除瞬时 CPU 洪峰。
class EngineTaskQueue {
  EngineTaskQueue({int? maxConcurrency}) {
    _maxConcurrency = maxConcurrency ?? _resolveDefaultConcurrency();
  }

  late int _maxConcurrency;

  /// 当前允许的最大后台并发执行数
  int get maxConcurrency => _maxConcurrency;
  set maxConcurrency(int value) {
    if (value > 0) {
      _maxConcurrency = value;
      _pump();
    }
  }

  int _runningCount = 0;
  final List<_QueuedTask<dynamic>> _queue = [];
  final Map<String, Future<dynamic>> _inFlightMap = {};

  /// 当前正在后台并发执行的任务数
  int get runningCount => _runningCount;

  /// 当前在队列中等待执行的任务数
  int get queuedCount => _queue.length;

  /// 解析当前平台的推荐默认并发数
  static int _resolveDefaultConcurrency() {
    if (kIsWeb) return 2;
    try {
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        final cores = Platform.numberOfProcessors;
        // 桌面端根据 CPU 线程数智能调度：最低 2，最高 6，默认取 cores/2 或 4
        return (cores >= 8) ? 4 : (cores >= 4 ? 3 : 2);
      }
    } catch (_) {}
    // 移动平台 (Android / iOS) 保持 2，防止大核发热降频
    return 2;
  }

  /// 调度并执行一个带 Key 的后台任务 (支持 Single Flight 与排队限流)
  Future<T> schedule<T>({
    required String key,
    required Future<T> Function() task,
  }) {
    // 1. Single Flight 检查：如果相同 Key 已在处理中，直接复用其 Future
    final inFlight = _inFlightMap[key];
    if (inFlight != null) {
      AppLogger.imageCache.fine('EngineTaskQueue single-flight hit key=$key');
      return inFlight as Future<T>;
    }

    final completer = Completer<T>();

    final queuedTask = _QueuedTask<T>(
      key: key,
      task: task,
      completer: completer,
    );

    _inFlightMap[key] = completer.future;
    _queue.add(queuedTask);

    _pump();

    return completer.future;
  }

  /// 推动队列调度
  void _pump() {
    while (_runningCount < _maxConcurrency && _queue.isNotEmpty) {
      final item = _queue.removeAt(0);
      _runningCount++;

      _executeTask(item);
    }
  }

  Future<void> _executeTask<T>(_QueuedTask<T> item) async {
    AppLogger.imageCache.fine('EngineTaskQueue start key=${item.key} running=$_runningCount queued=${_queue.length}');
    final sw = Stopwatch()..start();
    try {
      final result = await item.task();
      AppLogger.imageCache.fine('EngineTaskQueue success key=${item.key} ${sw.elapsedMilliseconds}ms');
      if (!item.completer.isCompleted) {
        item.completer.complete(result);
      }
    } catch (e, stack) {
      AppLogger.imageCache.warning('EngineTaskQueue failed key=${item.key} ${sw.elapsedMilliseconds}ms', e, stack);
      if (!item.completer.isCompleted) {
        item.completer.completeError(e, stack);
      }
    } finally {
      _inFlightMap.remove(item.key);
      _runningCount--;
      _pump();
    }
  }

  /// 清空等待队列 (正在执行的任务不受影响)
  void clearQueue() {
    for (final item in _queue) {
      _inFlightMap.remove(item.key);
      if (!item.completer.isCompleted) {
        item.completer.completeError(
          const CancellationException('Task cancelled due to queue clear'),
        );
      }
    }
    _queue.clear();
  }
}

class _QueuedTask<T> {
  _QueuedTask({
    required this.key,
    required this.task,
    required this.completer,
  });

  final String key;
  final Future<T> Function() task;
  final Completer<T> completer;
}

class CancellationException implements Exception {
  const CancellationException(this.message);
  final String message;

  @override
  String toString() => 'CancellationException: $message';
}
