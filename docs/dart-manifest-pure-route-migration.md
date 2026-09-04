# Dart 端 Manifest 纯路由改造迁移指南

> **关联文档**：[`unified-export-and-manifest-restructure-design.md`](./unified-export-and-manifest-restructure-design.md)
>
> **前置条件**：服务端 `daily.json` 已就绪且 `manifest.json` 已切换为纯路由格式。
>
> **改造目标**：`DailyModuleConfig` 从 `{currentMonth, zipUrlPattern, listUrlPattern, version}` 改为与 `MainModuleConfig`/`EventsModuleConfig` 一致的 `{url, version}` 纯路由，daily 业务数据从独立 `daily.json` 获取。

## 改造前后的 manifest.json daily 模块对比

```
改造前 (旧)                              改造后 (新)
┌─────────────────────────────┐         ┌──────────────────────┐
│ "daily": {                  │         │ "daily": {           │
│   "currentMonth": "202609", │         │   "url": ".../daily │
│   "zipUrlPattern": "...{..}",│        │        .json",       │
│   "listUrlPattern": "...",  │         │   "version": 3      │
│   "version": 3              │         │ }                    │
│ }                           │         └──────────────────────┘
└─────────────────────────────┘         业务数据 → daily.json
```

## daily.json 目标格式

```json
{
  "version": 3,
  "updatedAt": "2026-09-03T14:30:00Z",
  "currentMonth": "202609",
  "months": [
    {
      "month": "202609",
      "zipUrl": "http://cdn/daily/202609.zip",
      "updatedAt": "2026-09-30T23:59:00Z",
      "count": 30
    }
  ]
}
```

---

## 受影响文件清单（6 个）

| # | 文件 | 改动类型 | 说明 |
|---|------|----------|------|
| 1 | `lib/logic/content/models/root_manifest.dart` | **模型重构** | `DailyModuleConfig` 类定义改造 |
| 2 | `lib/logic/content/content_manager.dart` | **逻辑重写** | `syncAll` 和 `ensureDailyMonthReady` 中 daily 数据获取方式改变 |
| 3 | `lib/logic/content/pipelines/daily_content_pipeline.dart` | **接口变更** | `ensureMonthReady` 参数从 `zipUrlPattern` 改为 `zipUrl` |
| 4 | `lib/logic/content/pipelines/manifest_router.dart` | **兜底更新** | `_createDefaultFallbackManifest` 中 daily 兜底配置 |
| 5 | `lib/pages/tabs/daily_tab_view.dart` | **数据源切换** | `currentMonth` 从 manifest 改为 daily.json |
| 6 | `lib/logic/catalog_index.dart` | **数据源切换** | `currentMonth` 从 manifest 改为 daily.json |

---

## 逐文件改动方案

### 1. `root_manifest.dart` — 模型重构

**当前 `DailyModuleConfig`（第 82-110 行）**：

```dart
class DailyModuleConfig {
  const DailyModuleConfig({
    required this.currentMonth,
    required this.zipUrlPattern,
    required this.listUrlPattern,
    required this.version,
  });

  final String currentMonth;
  final String zipUrlPattern;
  final String listUrlPattern;
  final int version;
  // fromJson / toJson ...
}
```

**改为纯路由（与 `MainModuleConfig` 完全一致）**：

```dart
class DailyModuleConfig {
  const DailyModuleConfig({required this.url, required this.version});

  final String url;
  final int version;

  factory DailyModuleConfig.fromJson(Map<String, dynamic> json) {
    return DailyModuleConfig(
      url: json['url']?.toString() ?? '',
      version: (json['version'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {'url': url, 'version': version};
}
```

**同时新增 `DailyManifest` 模型类**（可放在同文件或新文件 `daily_manifest.dart`）：

```dart
class DailyManifest {
  const DailyManifest({
    required this.version,
    required this.updatedAt,
    required this.currentMonth,
    required this.months,
  });

  final int version;
  final DateTime updatedAt;
  final String currentMonth;
  final List<DailyMonthEntry> months;

  factory DailyManifest.fromJson(Map<String, dynamic> json) {
    return DailyManifest(
      version: (json['version'] as num?)?.toInt() ?? 0,
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '') ?? DateTime.now(),
      currentMonth: json['currentMonth']?.toString() ?? '',
      months: (json['months'] as List?)
          ?.map((e) => DailyMonthEntry.fromJson(e as Map<String, dynamic>))
          .toList() ?? const [],
    );
  }
}

class DailyMonthEntry {
  const DailyMonthEntry({
    required this.month,
    required this.zipUrl,
    required this.updatedAt,
    required this.count,
  });

  final String month;
  final String zipUrl;
  final DateTime updatedAt;
  final int count;

  factory DailyMonthEntry.fromJson(Map<String, dynamic> json) {
    return DailyMonthEntry(
      month: json['month']?.toString() ?? '',
      zipUrl: json['zipUrl']?.toString() ?? '',
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '') ?? DateTime.now(),
      count: (json['count'] as num?)?.toInt() ?? 0,
    );
  }
}
```

---

### 2. `content_manager.dart` — 逻辑重写

**当前问题**：第 106-124 行直接从 `manifest.dailyModule.currentMonth` 和 `manifest.dailyModule.zipUrlPattern` 获取数据。

**改动要点**：

1. `syncAll` 中先请求 `daily.json`（通过 `manifest.dailyModule.url`），解析为 `DailyManifest`，再用其中的 `currentMonth` 和 `months[].zipUrl` 驱动 `ensureMonthReady`。

2. 缓存 `DailyManifest` 实例到 `ContentManager` 成员变量。

```dart
// 新增成员
DailyManifest? _dailyManifest;
DailyManifest? get dailyManifest => _dailyManifest;

// syncAll 中的 daily 部分（替换第 105-125 行）：
() async {
  final dailyUrl = manifest.dailyModule.url;
  if (dailyUrl.isEmpty) {
    AppLogger.content.fine('daily url empty, skip');
    return;
  }
  try {
    final dailyJson = await _httpClient.fetchJson(dailyUrl);
    _dailyManifest = DailyManifest.fromJson(dailyJson);
    final currentMonth = overrideToday != null
        ? _formatCurrentMonth(overrideToday)
        : (_dailyManifest!.currentMonth.isNotEmpty
              ? _dailyManifest!.currentMonth
              : _formatCurrentMonth(DateTime.now()));
    final monthEntry = _dailyManifest!.months
        .where((m) => m.month == currentMonth)
        .firstOrNull;
    if (monthEntry != null && monthEntry.zipUrl.isNotEmpty) {
      final ok = await dailyPipeline.ensureMonthReady(
        yyyyMm: currentMonth,
        zipUrl: monthEntry.zipUrl,  // ← 直接传完整 URL
        overrideToday: overrideToday,
      );
      AppLogger.content.info(
        'daily ensureMonthReady $currentMonth ok=$ok',
      );
    }
  } catch (e, st) {
    AppLogger.content.warning('daily.json fetch failed', e, st);
  }
}(),
```

3. `ensureDailyMonthReady`（第 167-174 行）同样改用缓存 `_dailyManifest`：

```dart
Future<bool> ensureDailyMonthReady(String yyyyMm, {DateTime? overrideToday}) {
  final entry = _dailyManifest?.months
      .where((m) => m.month == yyyyMm)
      .firstOrNull;
  final zipUrl = entry?.zipUrl ?? '';
  return dailyPipeline.ensureMonthReady(
    yyyyMm: yyyyMm,
    zipUrl: zipUrl,
    overrideToday: overrideToday,
  );
}
```

---

### 3. `daily_content_pipeline.dart` — 接口变更

**当前 `ensureMonthReady`（第 25-44 行）**：参数为 `zipUrlPattern`，内部做 `zipUrlPattern.replaceAll('{YYYYMM}', yyyyMm)` 拼接。

**改为直接接收完整 `zipUrl`**：

```dart
Future<bool> ensureMonthReady({
  required String yyyyMm,
  required String zipUrl,   // ← 改名：zipUrlPattern → zipUrl
  DateTime? overrideToday,
}) async {
  // ... 同前 ...
  if (zipUrl.isEmpty) {
    AppLogger.daily.warning('ensureMonthReady empty zipUrl for $yyyyMm');
    return false;
  }
  // 删除 replaceAll('{YYYYMM}', yyyyMm) 拼接逻辑
  // 直接使用 zipUrl 下载
  final zipFile = await _httpClient.downloadFile(zipUrl, tempZipPath);
  // ... 后续不变 ...
}
```

**关键差异**：

| 旧 | 新 |
|----|----|
| `zipUrlPattern: "http://cdn/daily/{YYYYMM}.zip"` | `zipUrl: "http://cdn/daily/202609.zip"` |
| 内部 `replaceAll('{YYYYMM}', yyyyMm)` | 直接使用，无需拼接 |

---

### 4. `manifest_router.dart` — 兜底更新

**当前兜底（第 146-151 行）**：

```dart
dailyModule: const DailyModuleConfig(
  currentMonth: '',
  zipUrlPattern: '',
  listUrlPattern: '',
  version: 0,
),
```

**改为**：

```dart
dailyModule: const DailyModuleConfig(url: '', version: 0),
```

---

### 5. `daily_tab_view.dart` — 数据源切换

**当前（第 120-124 行）**：

```dart
final manifestMonth =
    AppContent.instance.manager.currentManifest?.dailyModule.currentMonth;
```

**改为从缓存的 `dailyManifest` 获取**：

```dart
final manifestMonth =
    AppContent.instance.manager.dailyManifest?.currentMonth;
```

---

### 6. `catalog_index.dart` — 数据源切换

**当前（第 100-109 行）**：

```dart
final currentMonth =
    AppContent.instance.manager.currentManifest?.dailyModule.currentMonth ?? '';
```

**改为**：

```dart
final currentMonth =
    AppContent.instance.manager.dailyManifest?.currentMonth ?? '';
```

---

## 向后兼容策略

### 方案 A：一刀切（推荐）

服务端数据就绪后，直接发布新版 App。旧版 App 从旧 manifest 获取 `currentMonth`/`zipUrlPattern` 会得到空值（因为服务端 manifest 已改为纯路由格式），daily 模块静默降级为不可用——不会崩溃，只是无每日挑战内容。

### 方案 B：过渡期兼容（可选）

如果需要灰度发布，`DailyModuleConfig.fromJson` 可做双格式兼容：

```dart
factory DailyModuleConfig.fromJson(Map<String, dynamic> json) {
  // 新格式优先
  if (json['url'] != null) {
    return DailyModuleConfig(
      url: json['url']?.toString() ?? '',
      version: (json['version'] as num?)?.toInt() ?? 0,
    );
  }
  // 旧格式兜底（过渡期）
  final zipPattern = json['zipUrlPattern']?.toString() ?? '';
  return DailyModuleConfig(
    url: '',  // 旧格式无 url，daily.json 不可用
    version: (json['version'] as num?)?.toInt() ?? 0,
  );
}
```

> 过渡期结束后删除旧格式兼容分支。

---

## 测试检查清单

- [ ] 离线兜底：`manifest_router._createDefaultFallbackManifest` 生成的新格式 `DailyModuleConfig(url: '', version: 0)` 不崩溃
- [ ] 首次启动：App 从 `manifest.dailyModule.url` 请求 `daily.json`，解析 `DailyManifest` 成功
- [ ] 当月下载：`ensureMonthReady` 使用 `daily.json` 中 `months[].zipUrl` 直接下载，不再做 `{YYYYMM}` 拼接
- [ ] daily_tab_view：`currentMonth` 从 `dailyManifest` 获取，月份列表正确显示
- [ ] catalog_index：搜索/目录索引中 daily 条目正确
- [ ] `flutter analyze` 0 警告 0 错误
- [ ] `flutter test` 全量通过
- [ ] `flutter build windows --debug` 编译成功
