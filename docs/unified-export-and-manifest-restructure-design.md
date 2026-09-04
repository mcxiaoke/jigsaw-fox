# 统一导出对话框与 manifest 纯路由改造方案

> **状态**：方案确认，实施中
> **日期**：2026-09-03
> **关联**：`docs/puzzle-content-packaging-tool-design.md`（v1.1 打包工具设计）、`docs/puzzle-content-storage-and-expansion-design.md`（v3 存储与扩展）
> **影响范围**：`scripts/packaging/server.py`、`scripts/packaging/index.html`、`lib/logic/content/`（Dart 侧 manifest 解析）

---

## 1. 背景与目标

### 1.1 现状

打包工具 (`scripts/packaging/`) 当前有三个独立导出入口：

| 按钮 | 函数 | 服务端处理 | 产物 |
|------|------|-----------|------|
| 📦 导出 main.json | `doExportMain()` | `_handle_export_main` | `main.json` + `main/*.jpg` |
| 📅 导出 daily ZIP | `doExportDaily()` | `_handle_export_daily` | `daily/YYYYMM.zip` |
| 🎉 导出 events.json | toast 提示未实现 | `_handle_export_events` (stub) | `events/events.json` |

问题：
- 三个入口各自独立，无统一参数（格式转换、重命名、标题等）
- events 导出未完成，collection 类型不存在
- manifest.json 中 daily 格式与 main/events 不一致（含 `currentMonth`/`zipUrlPattern`/`listUrlPattern`），不是纯路由
- 无导出日志

### 1.2 目标

1. **统一导出对话框**：一个按钮弹出 modal，支持四种类型 (main/daily/event/collection)，通用参数 + 类型专属参数
2. **manifest 纯路由化**：所有模块统一 `{url, version}`，具体数据在各自 JSON 内获取
3. **格式转换**：导出时可选转 WebP/JPEG/PNG（复用已有 PIL 依赖）
4. **自动重命名**：序号 (001/002...) 或日期 (YYYYMMDD) 或保持原名
5. **输出模式**：event/collection 支持 ZIP 整包或 Array 列表
6. **日志收集**：导出全过程日志，前端实时显示，可保存为 .log 文件

---

## 2. manifest.json 纯路由改造

### 2.1 改造前（当前）

```json
{
  "schemaVersion": 1,
  "modules": {
    "main": { "url": "https://cdn.example.com/puzzle/main.json", "version": 105 },
    "daily": {
      "currentMonth": "202608",
      "zipUrlPattern": "https://cdn.example.com/puzzle/daily/{YYYYMM}.zip",
      "listUrlPattern": "https://cdn.example.com/puzzle/daily/{YYYYMM}.json",
      "version": 20260827
    },
    "events": { "url": "https://cdn.example.com/puzzle/events.json", "version": 12 }
  }
}
```

问题：daily 模块把月份规则、URL 模板等业务数据塞进了 manifest 路由层，违反"manifest 只是路由"原则。

### 2.2 改造后（目标）

```json
{
  "schemaVersion": 1,
  "modules": {
    "main": { "url": "https://cdn.example.com/puzzle/main.json", "version": 105 },
    "daily": { "url": "https://cdn.example.com/puzzle/daily.json", "version": 20260827 },
    "events": { "url": "https://cdn.example.com/puzzle/events.json", "version": 12 },
    "collections": { "url": "https://cdn.example.com/puzzle/collections.json", "version": 1 }
  }
}
```

所有模块统一 `{url, version}`，manifest 不再承载任何业务数据。

### 2.3 新增 daily.json（从 manifest 迁出的业务数据）

```json
{
  "version": 20260827,
  "updatedAt": "2026-08-27T12:00:00Z",
  "currentMonth": "202608",
  "months": [
    {
      "month": "202608",
      "type": "zip",
      "url": "https://cdn.example.com/puzzle/daily/202608.zip"
    },
    {
      "month": "202607",
      "type": "zip",
      "url": "https://cdn.example.com/puzzle/daily/202607.zip"
    }
  ]
}
```

- `currentMonth`：当前月份，客户端用于决定下载哪个月
- `months[]`：历史月份列表，客户端可回溯往期
- `type`：`zip`（整包下载）或 `array`（在线列表，降级方案）
- `url`：zip 下载地址或 array JSON 地址

### 2.4 Dart 侧影响

| 文件 | 当前逻辑 | 改造方向 |
|------|---------|---------|
| `lib/logic/content/models/root_manifest.dart` | `DailyModule{currentMonth, zipUrlPattern, listUrlPattern, version}` | 改为 `DailyModule{url, version}`，新增 `DailyContent` 模型解析 daily.json |
| `lib/logic/content/content_manager.dart` | 直接用 `manifest.dailyModule.currentMonth/zipUrlPattern` | 先 fetch `daily.json`，再用其内部 `currentMonth` 和 `months[]` |
| `lib/logic/content/pipelines/daily_content_pipeline.dart` | `ensureMonthReady(yyyyMm, zipUrlPattern)` | 改为 `ensureMonthReady(yyyyMm, zipUrl)`，URL 从 daily.json 的 `months[]` 中查找 |
| `lib/logic/content/pipelines/manifest_router.dart` | fallback manifest 含空 daily 字段 | fallback 改为 `DailyModule(url:'', version:0)` |
| `lib/pages/tabs/daily_tab_view.dart` | `manifest.dailyModule.currentMonth` | 改为从 daily.json 缓存中读取 |
| `lib/logic/catalog_index.dart` | 同上 | 同上 |

> **注意**：Dart 侧改造不在本次打包工具实施范围内，但需同步排期。打包工具侧会同时产出新格式的 daily.json。

---

## 3. 四种导出类型数据结构

### 3.1 Main 主线

**产物**：`main.json` + `main/*.webp`

```json
{
  "version": 122,
  "updatedAt": "2026-09-03T14:21:00Z",
  "levels": [
    { "url": "https://cdn.example.com/main/101.webp", "tags": ["Animals"], "order": 101 },
    { "url": "https://cdn.example.com/main/102.webp", "tags": ["Flowers"], "order": 102 }
  ]
}
```

| 参数 | 说明 | 默认值 |
|------|------|--------|
| version | 版本号，留空自增 | 现有 +1 |
| startOrder | 起始序号 | 101 |
| format | 图片格式转换 | webp |
| rename | 重命名规则 | sequence（序号） |

**manifest 联动**：`modules.main.version` → 新 version

### 3.2 Daily 每日

**产物**：`daily.json` + `daily/YYYYMM.zip`

`daily.json`：
```json
{
  "version": 20260903,
  "updatedAt": "2026-09-03T14:21:00Z",
  "currentMonth": "202609",
  "months": [
    { "month": "202609", "type": "zip", "url": "https://cdn.example.com/daily/202609.zip" },
    { "month": "202608", "type": "zip", "url": "https://cdn.example.com/daily/202608.zip" }
  ]
}
```

`202609.zip` 内部：
```
20260901.webp
20260902.webp
...
20260930.webp
```

| 参数 | 说明 | 默认值 |
|------|------|--------|
| month | YYYYMM | 当前月 |
| format | 图片格式转换 | webp |
| rename | 重命名规则 | date（YYYYMMDD） |

**manifest 联动**：`modules.daily.version` → 新 version

### 3.3 Event 活动

**产物**：`events/events.json` + `events/{id}.zip` 或 `events/{id}/*.webp`

events.json 是一个数组，导出时 **upsert**（按 id 合并到已有 events.json）：
```json
[
  {
    "id": "cyberpunk_2026",
    "title": "未来赛博都市",
    "desc": "穿梭于流光溢彩的摩天楼群",
    "coverUrl": "https://cdn.example.com/events/cyberpunk_cover.webp",
    "status": "active",
    "type": "zip",
    "zipUrl": "https://cdn.example.com/events/cyberpunk_2026.zip",
    "startTime": "2026-08-01T00:00:00Z",
    "endTime": "2026-09-01T00:00:00Z",
    "displayOrder": 1
  },
  {
    "id": "classic_art",
    "title": "卢浮宫名画特辑",
    "desc": "精选世界传世油画名作",
    "coverUrl": "https://cdn.example.com/events/art_cover.webp",
    "status": "active",
    "type": "array",
    "levels": [
      "https://cdn.example.com/events/art/01_mona_lisa.webp",
      "https://cdn.example.com/events/art/02_starry_night.webp"
    ],
    "startTime": "2026-08-15T00:00:00Z",
    "endTime": "2026-09-15T00:00:00Z",
    "displayOrder": 2
  }
]
```

| 参数 | 说明 | 默认值 |
|------|------|--------|
| eventId | 活动 ID | 必填 |
| title | 活动标题 | 从对话框 title 字段 |
| desc | 描述 | 可选 |
| status | 状态 | active |
| startTime/endTime | 时间范围 | 可选 |
| displayOrder | 显示顺序 | 1 |
| outputMode | zip/array | zip |
| format | 图片格式转换 | 原格式 |
| rename | 重命名规则 | 不重命名 |

**manifest 联动**：`modules.events.version` → +1

### 3.4 Collection 图集（新增）

**产物**：`collections.json` + `collections/{id}.zip` 或 `collections/{id}/*.webp`

结构与 event 类似，但无 status/startTime/endTime（图集是常驻内容，无生命周期）：
```json
[
  {
    "id": "world_art",
    "title": "世界名画合集",
    "desc": "精选世界传世油画名作",
    "coverUrl": "https://cdn.example.com/collections/world_art_cover.webp",
    "type": "zip",
    "zipUrl": "https://cdn.example.com/collections/world_art.zip",
    "displayOrder": 1
  },
  {
    "id": "bestiary",
    "title": "动物图鉴",
    "desc": "全球野生动物精选",
    "coverUrl": "https://cdn.example.com/collections/bestiary_cover.webp",
    "type": "array",
    "levels": [
      "https://cdn.example.com/collections/bestiary/01_lion.webp",
      "https://cdn.example.com/collections/bestiary/02_tiger.webp"
    ],
    "displayOrder": 2
  }
]
```

| 参数 | 说明 | 默认值 |
|------|------|--------|
| collectionId | 图集 ID | 必填 |
| title | 图集标题 | 从对话框 title 字段 |
| desc | 描述 | 可选 |
| displayOrder | 显示顺序 | 1 |
| outputMode | zip/array | zip |
| format | 图片格式转换 | 原格式 |
| rename | 重命名规则 | 不重命名 |

**manifest 联动**：新增 `modules.collections = {url, version}`

> **Canonical ID**：`collection:{id}:{文件名}`（已在存储设计 §5 中预留扩展包命名空间）

---

## 4. 服务端目录结构

```
outDir/                                # 输出根目录（对应 httpBase）
├── manifest.json                      # 根路由清单（纯 {url, version}）
├── main.json                          # 主线关卡列表
├── main/                              # 主线图片目录
│   ├── 101.webp
│   ├── 102.webp
│   └── ...
├── daily.json                         # 每日挑战路由+月份列表（新增）
├── daily/                             # 每月 zip 目录
│   ├── 202609.zip
│   ├── 202608.zip
│   └── ...
├── events/
│   ├── events.json                    # 活动列表
│   ├── cyberpunk_2026.zip             # zip 模式活动包
│   ├── cyberpunk_cover.webp           # 活动封面
│   └── classic_art/                   # array 模式活动图片目录
│       ├── 01_mona_lisa.webp
│       └── 02_starry_night.webp
├── collections/                       # 图集目录（新增）
│   ├── collections.json               # 图集列表
│   ├── world_art.zip
│   ├── world_art_cover.webp
│   └── bestiary/                      # array 模式图集图片目录
│       ├── 01_lion.webp
│       └── 02_tiger.webp
└── export-logs/                       # 导出日志归档（可选）
    └── 20260903-142100.log
```

---

## 5. 统一导出 API

### 5.1 端点

`POST /api/export`

### 5.2 请求体

```json
{
  "type": "main",
  "srcDir": "D:\\puzzle\\raw\\home_202609",
  "outDir": "X:\\www\\game\\test",
  "httpBase": "http://192.168.1.118/data/www/game/test",

  "format": "webp",
  "rename": "sequence",
  "title": "202609 月度更新",

  "version": 122,
  "startOrder": 101,

  "month": "202609",
  "eventId": "cyberpunk_2026",
  "description": "...",
  "status": "active",
  "startTime": "2026-08-01T00:00:00Z",
  "endTime": "2026-09-01T00:00:00Z",
  "displayOrder": 1,
  "outputMode": "zip",

  "tagsRecords": []
}
```

通用字段（所有类型）：

| 字段 | 类型 | 说明 |
|------|------|------|
| type | string | `main` / `daily` / `event` / `collection` |
| srcDir | string | 源图片目录 |
| outDir | string | 输出目录 |
| httpBase | string | CDN 前缀 |
| format | string | `original` / `webp` / `jpg` / `png` |
| rename | string | `none` / `sequence` / `date` |
| title | string | 标题（可选） |
| tagsRecords | array | 内存中的 tags 记录（前端 recordMap 转 array） |

类型专属字段：

| 字段 | 适用类型 | 说明 |
|------|---------|------|
| version | main | 版本号，留空自增 |
| startOrder | main | 起始序号，默认 101 |
| month | daily | YYYYMM |
| eventId | event | 活动 ID |
| description | event, collection | 描述 |
| status | event | upcoming/active/outdated/disabled |
| startTime | event | ISO8601 |
| endTime | event | ISO8601 |
| displayOrder | event, collection | 显示顺序 |
| outputMode | event, collection | `zip` / `array` |
| collectionId | collection | 图集 ID |

### 5.3 响应体

```json
{
  "ok": true,
  "type": "main",
  "summary": "69 张图片 -> main.json (version=122)",
  "files": [
    "X:\\www\\game\\test\\main.json",
    "X:\\www\\game\\test\\main\\101.webp",
    "X:\\www\\game\\test\\manifest.json"
  ],
  "logs": [
    { "t": "22:15:01", "level": "info", "msg": "开始导出 main..." },
    { "t": "22:15:01", "level": "info", "msg": "扫描到 69 张图片" },
    { "t": "22:15:02", "level": "info", "msg": "格式转换: 69/69 jpg -> webp" },
    { "t": "22:15:05", "level": "ok", "msg": "main.json 已写入 (version=122)" },
    { "t": "22:15:05", "level": "ok", "msg": "manifest.json main.version -> 122" }
  ]
}
```

### 5.4 日志级别

| level | 颜色 | 用途 |
|-------|------|------|
| info | 灰 | 进度信息 |
| ok | 绿 | 成功完成 |
| warn | 黄 | 警告（如 Others 跳过） |
| err | 红 | 错误 |

---

## 6. 导出对话框设计

### 6.1 对话框布局

```
┌─────────────────────────────────────────────┐
│  导出拼图内容包                          ×   │
├─────────────────────────────────────────────┤
│  [主线 Main] [每日 Daily] [活动 Event] [图集] │  ← 类型切换 tab
├─────────────────────────────────────────────┤
│  通用设置                                     │
│  输出目录: [___________________________]      │
│  HTTP Base: [___________________________]     │
│  标题: [___________________________]          │
│  图片格式: [保持原格式 ▼]  重命名: [序号 ▼]   │
├─────────────────────────────────────────────┤
│  Main 专属参数                                │
│  版本号: [自动+1]  起始序号: [101]            │
├─────────────────────────────────────────────┤
│  输出模式与日志                                │
│  输出形态: [ZIP 整包 ▼]                       │
│  ┌─────────────────────────────────────┐     │
│  │ [22:15:01] 开始导出 main...         │     │
│  │ [22:15:02] 格式转换: 69/69          │     │
│  │ [22:15:05] main.json 已写入        │     │  ← 日志区域
│  └─────────────────────────────────────┘     │
├─────────────────────────────────────────────┤
│  69 张图片 · 预计 3.2MB    [保存日志] [导出] │
└─────────────────────────────────────────────┘
```

### 6.2 类型切换

切换 tab 时下方的"专属参数"区域动态切换：

| 类型 | 专属字段 | 输出模式 | 默认格式 | 默认重命名 |
|------|---------|---------|---------|-----------|
| main | version, startOrder | 固定 array | webp | sequence |
| daily | month | 固定 zip | webp | date |
| event | eventId, desc, status, startTime, endTime, displayOrder | zip/array 可选 | original | none |
| collection | collectionId, desc, displayOrder | zip/array 可选 | original | none |

### 6.3 交互流程

1. 用户点"导出"按钮 → 弹出对话框，默认选中 main tab
2. 通用字段自动从 config bar 填充（srcDir, outDir, httpBase）
3. 切换类型时专属字段动态填充，默认值按上表设置
4. 用户点"开始导出" → 前端校验必填字段 → POST /api/export
5. 等待响应（同步），日志区域显示返回的 logs
6. 成功后 toast 提示，日志区域可"保存日志"下载 .log 文件

### 6.4 校验规则

- **所有类型**：srcDir 和 outDir 必填
- **main**：有 Others 图片时 confirm 确认
- **daily**：month 格式 YYYYMM
- **event**：eventId 必填
- **collection**：collectionId 必填

---

## 7. 实施步骤

### P0：server.py 统一导出端点

1. 新增 `convert_image()` 函数（复用 PIL，支持 webp/jpg/png）
2. 新增 `rename_file()` 函数（支持 none/sequence/date）
3. 新增 `_handle_export()` 统一入口，通过 type 分发
4. 重构 `_handle_export_main` 为 `_export_main()` 内部函数，增加格式转换和重命名
5. 重构 `_handle_export_daily` 为 `_export_daily()`，产出 daily.json + zip
6. 完善 `_handle_export_events` 为 `_export_event()`，支持 upsert + zip/array
7. 新增 `_export_collection()`（复用 event 逻辑）
8. 新增 manifest 更新逻辑（统一 `_update_manifest()` 函数，支持四个模块）
9. 日志收集器贯穿所有导出函数

### P0：index.html 导出对话框

1. 替换 3 个导出按钮为 1 个"导出"按钮
2. 新增 modal HTML 结构（overlay + card + body + footer）
3. 新增 EXPORT_CONFIGS 配置（四种类型的字段定义和默认值）
4. 新增 `switchExportType()` 函数动态切换字段
5. 新增 `doExport()` 函数提交导出请求
6. 新增日志显示和保存逻辑
7. 保留旧的 `/api/export/main`、`/api/export/daily`、`/api/export/events` 端点做兼容

### P1：samples 文档

1. `scripts/packaging/server-samples.md`：服务端目录结构 + JSON 示例

### P1：changelog

1. `docs/CHANGES-20260903.md` 顶部追加变更摘要

---

## 8. 向后兼容

- 旧的 `/api/export/main`、`/api/export/daily`、`/api/export/events` 端点保留，内部重定向到新统一逻辑
- manifest.json 同时写入新旧 daily 字段（过渡期），Dart 侧迁移完成后移除旧字段
- 前端旧导出按钮替换为统一入口，但 `doExportMain`/`doExportDaily` 函数保留为内部调用
