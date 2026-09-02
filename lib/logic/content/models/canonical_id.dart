/// 全局关卡 Canonical ID 动态合成与解析工具类
///
/// 统一遵循 `{模块前缀}:{上下文/分组}:{纯文件名(无后缀)}` 规范
class CanonicalId {
  const CanonicalId._();

  static const String prefixMain = 'main';
  static const String prefixDaily = 'daily';
  static const String prefixEvent = 'event';
  static const String prefixPack = 'pack';
  static const String prefixUgc = 'ugc';

  /// 生成首页关卡 ID (如 "main:101")
  static String forMain(dynamic seqOrName) {
    final name = _cleanFilename(seqOrName.toString());
    return '$prefixMain:$name';
  }

  /// 生成每日挑战关卡 ID (如 "daily:20260827")
  static String forDaily(String dateOrFilename) {
    final clean = _cleanFilename(dateOrFilename);
    return '$prefixDaily:$clean';
  }

  /// 生成活动关卡 ID (如 "event:cyberpunk_2026:01")
  static String forEvent(String eventId, String filename) {
    final cleanEvent = _cleanFilename(eventId);
    final cleanFile = _cleanFilename(filename);
    return '$prefixEvent:$cleanEvent:$cleanFile';
  }

  /// 生成扩展包关卡 ID (如 "pack:world_art:mona_lisa")
  static String forPack(String packId, String filename) {
    final cleanPack = _cleanFilename(packId);
    final cleanFile = _cleanFilename(filename);
    return '$prefixPack:$cleanPack:$cleanFile';
  }

  /// 生成本地 UGC 自制关卡 ID (如 "ugc:1787548651000")
  static String forUgc(String timestampOrName) {
    final clean = _cleanFilename(timestampOrName);
    return '$prefixUgc:$clean';
  }

  /// 从 URL 或本地文件名推导 Canonical ID
  static String fromSource({
    required String sourceModule,
    required String pathOrUrl,
    String? contextId,
  }) {
    final filename = pathOrUrl.split('/').last.split('\\').last;
    switch (sourceModule) {
      case prefixMain:
        return forMain(filename);
      case prefixDaily:
        return forDaily(filename);
      case prefixEvent:
        return forEvent(contextId ?? 'unknown', filename);
      case prefixPack:
        return forPack(contextId ?? 'custom', filename);
      case prefixUgc:
        return forUgc(filename);
      default:
        return '$sourceModule:${_cleanFilename(filename)}';
    }
  }

  /// 解析 Canonical ID 为结构化信息
  static CanonicalIdInfo parse(String id) {
    final parts = id.split(':');
    if (parts.isEmpty) {
      return const CanonicalIdInfo(module: 'unknown', name: '');
    }
    if (parts.length == 1) {
      return CanonicalIdInfo(module: 'unknown', name: parts[0]);
    }
    if (parts.length == 2) {
      return CanonicalIdInfo(module: parts[0], name: parts[1]);
    }
    return CanonicalIdInfo(
      module: parts[0],
      context: parts[1],
      name: parts.sublist(2).join(':'),
    );
  }

  /// 剥离文件扩展名并清洗特殊字符
  static String _cleanFilename(String raw) {
    var str = raw.trim();
    // 去除 url query 参数
    if (str.contains('?')) {
      str = str.split('?').first;
    }
    // 仅保留文件名本身
    if (str.contains('/') || str.contains('\\')) {
      str = str.split('/').last.split('\\').last;
    }
    // 去除扩展名
    final dotIndex = str.lastIndexOf('.');
    if (dotIndex > 0) {
      str = str.substring(0, dotIndex);
    }
    return str;
  }
}

class CanonicalIdInfo {
  const CanonicalIdInfo({
    required this.module,
    required this.name,
    this.context,
  });

  final String module;
  final String? context;
  final String name;

  @override
  String toString() =>
      'CanonicalIdInfo(module: $module, context: $context, name: $name)';
}
