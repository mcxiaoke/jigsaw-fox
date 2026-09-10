/// 泛型单飞（Single-Flight）助手：同 key 的并发调用复用同一个进行中的 Future。
///
/// 内容管线（main / collections / events / daily）此前各自内联一份"查表→存入→
/// identical 复核→清除"样板，此处统一收口（P1-7），消除同资源并发下载互删
/// 临时目录的竞态，同时避免网络/解压重复执行。
library;

import 'dart:async';

/// 执行单飞任务：
///
/// - 若 [inFlight] 中已存在 [key] 对应的进行中 Future，直接返回它（复用）；
/// - 否则由 [create] 创建 Future 存入 [inFlight]，并在其完成/失败回调中
///   以 `identical(inFlight[key], future)` 复核通过后才移除记录，
///   防止旧任务完成后误删已被新任务替换的记录（ABA 竞态）。
Future<T> runSingleFlight<T>(
  Map<String, Future<T>> inFlight,
  String key,
  Future<T> Function() create,
) {
  final existing = inFlight[key];
  if (existing != null) {
    return existing;
  }
  final future = create();
  inFlight[key] = future;
  // 清理记录是副作用回调：结果与错误均有意忽略（原 future 由调用者 await 处理），
  // 必须用 ignore() 屏蔽 whenComplete 派生链，否则原 future 以 error 完成时
  // 派生链的错误无人接，会触发未处理异步错误。
  future.whenComplete(() {
    if (identical(inFlight[key], future)) {
      // ignore: discarded_futures  // remove 返回被删的 value，清理记录无需等待
      inFlight.remove(key);
    }
  }).ignore();
  return future;
}
