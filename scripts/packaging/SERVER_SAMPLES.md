# 服务端目录结构与 JSON 示例

本文档描述拼图内容打包工具产出的服务端目录结构，以及各类 JSON 文件的格式示例。

## 目录结构

```
www/game/test/                     # httpBase 指向此目录
├── manifest.json                  # 路由清单（纯路由，不含业务数据）
├── main.json                      # main 模块数据
├── daily.json                     # daily 模块数据（新版，独立文件）
├── events.json                    # events 模块数据
├── collections.json               # collections 模块数据（App 端暂未实现）
├── main/                           # main 图片目录
│   ├── 101.webp
│   ├── 102.webp
│   └── ...
├── daily/                          # daily 打包目录
│   ├── 20260901.zip
│   ├── 20260902.zip
│   └── 202610.zip                  # 月度汇总 zip
├── events/                         # events 目录
│   ├── halloween2026.zip          # zip 模式产出
│   ├── halloween2026_cover.webp   # 封面
│   ├── midautumn2026/
│   │   ├── 01.webp                # array 模式产出
│   │   └── 02.webp
│   └── ...
└── collections/                    # collections 目录
    ├── spring2026.zip
    └── ...
```

## manifest.json（路由清单）

manifest.json 只做路由，每个模块仅包含 `url` 和 `version`，具体业务数据从 `url` 指向的独立 JSON 获取。

```json
{
  "version": 1,
  "updatedAt": "2026-09-03T14:30:00Z",
  "modules": {
    "main": {
      "url": "http://192.168.1.118/data/www/game/test/main.json",
      "version": 5
    },
    "daily": {
      "url": "http://192.168.1.118/data/www/game/test/daily.json",
      "version": 3
    },
    "events": {
      "url": "http://192.168.1.118/data/www/game/test/events/events.json",
      "version": 2
    },
    "collections": {
      "url": "http://192.168.1.118/data/www/game/test/collections/collections.json",
      "version": 1
    }
  }
}
```

### 改造说明

daily 模块从旧格式（含 `currentMonth`/`zipUrlPattern`/`listUrlPattern`）改为与 main/events 一致的纯路由格式 `{url, version}`。原 daily 的业务数据（月份列表、zip URL 等）迁移到独立的 `daily.json`。

## main.json

```json
{
  "version": 5,
  "updatedAt": "2026-09-03T14:30:00Z",
  "levels": [
    {
      "order": 101,
      "url": "http://192.168.1.118/data/www/game/test/main/101.webp",
      "tag": "Animals",
      "subject": "Cat",
      "scene": "Garden"
    },
    {
      "order": 102,
      "url": "http://192.168.1.118/data/www/game/test/main/102.webp",
      "tag": "Landscape",
      "subject": "Mountain",
      "scene": "Sunset"
    }
  ]
}
```

## daily.json

```json
{
  "version": 3,
  "updatedAt": "2026-09-03T14:30:00Z",
  "currentMonth": "202609",
  "months": [
    {
      "month": "202609",
      "zipUrl": "http://192.168.1.118/data/www/game/test/daily/202609.zip",
      "updatedAt": "2026-09-30T23:59:00Z",
      "count": 30
    },
    {
      "month": "202608",
      "zipUrl": "http://192.168.1.118/data/www/game/test/daily/202608.zip",
      "updatedAt": "2026-08-31T23:59:00Z",
      "count": 31
    }
  ]
}
```

### 字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `version` | int | 每次导出自增 |
| `updatedAt` | string (ISO 8601) | 最后更新时间 |
| `currentMonth` | string (YYYYMM) | 当前最新月份，App 据此判断是否有新内容 |
| `months[]` | array | 历史月份记录，按时间倒序排列 |
| `months[].month` | string | YYYYMM |
| `months[].zipUrl` | string | 该月份 zip 包的完整 URL |
| `months[].updatedAt` | string | 该月份最后更新时间 |
| `months[].count` | int | 该月份包含的图片数 |

### daily zip 内部结构

zip 内每个文件名为 `YYYYMMDD.webp`（或按重命名规则生成），解压后按日期排列：

```
202609.zip
├── 20260901.webp
├── 20260902.webp
├── 20260903.webp
└── ...
```

## events.json

```json
[
  {
    "id": "halloween2026",
    "title": "万圣节 2026",
    "desc": "Trick or Treat! 万圣节限定拼图合集",
    "coverUrls": "http://192.168.1.118/data/www/game/test/events/halloween2026_cover.webp",
    "status": "active",
    "startTime": "2026-10-01",
    "endTime": "2026-10-31",
    "displayOrder": 1,
    "type": "zip",
    "zipUrl": "http://192.168.1.118/data/www/game/test/events/halloween2026.zip"
  },
  {
    "id": "midautumn2026",
    "title": "中秋 2026",
    "desc": "月圆人团圆",
    "coverUrls": "http://192.168.1.118/data/www/game/test/events/midautumn2026/01.webp",
    "status": "ended",
    "startTime": "2026-09-01",
    "endTime": "2026-09-30",
    "displayOrder": 2,
    "type": "array",
    "levels": [
      "http://192.168.1.118/data/www/game/test/events/midautumn2026/01.webp",
      "http://192.168.1.118/data/www/game/test/events/midautumn2026/02.webp",
      "http://192.168.1.118/data/www/game/test/events/midautumn2026/03.webp"
    ]
  }
]
```

### 字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | string | 活动 ID，唯一标识 |
| `title` | string | 活动标题 |
| `desc` | string | 描述 |
| `coverUrls` | string | 封面图 URL |
| `status` | string | `active` / `ended` / `upcoming` |
| `startTime` | string | 开始日期 |
| `endTime` | string | 结束日期 |
| `displayOrder` | int | 排序权重，数字越小越靠前 |
| `type` | string | `zip`（打包）或 `array`（散列） |
| `zipUrl` | string | type=zip 时的下载 URL |
| `levels[]` | string[] | type=array 时的逐图 URL 列表 |

## collections.json

结构与 events.json 完全一致，区别在于 `id` 使用 `collectionId`、不含 `status`/`startTime`/`endTime` 等活动时间字段：

```json
[
  {
    "id": "spring2026",
    "title": "春日合集",
    "desc": "春暖花开系列拼图",
    "coverUrls": "http://192.168.1.118/data/www/game/test/collections/spring2026_cover.webp",
    "displayOrder": 1,
    "type": "zip",
    "zipUrl": "http://192.168.1.118/data/www/game/test/collections/spring2026.zip"
  },
  {
    "id": "cityscape",
    "title": "城市风光",
    "desc": "世界名城拼图合集",
    "coverUrls": "http://192.168.1.118/data/www/game/test/collections/cityscape/01.webp",
    "displayOrder": 2,
    "type": "array",
    "levels": [
      "http://192.168.1.118/data/www/game/test/collections/cityscape/01.webp",
      "http://192.168.1.118/data/www/game/test/collections/cityscape/02.webp"
    ]
  }
]
```

> **注意**: collections 类型 App 端暂未实现，服务端已预留端点和数据结构。

## 导出 API

### POST /api/export

统一导出端点，通过 `type` 字段区分四种导出类型。

#### 请求体（通用字段）

```json
{
  "type": "main",
  "srcDir": "D:\\puzzle\\raw\\home_202609",
  "outDir": "X:\\www\\game\\test",
  "httpBase": "http://192.168.1.118/data/www/game/test",
  "format": "webp",
  "rename": "sequence",
  "tagsRecords": []
}
```

#### 类型专属字段

| type | 专属字段 | 说明 |
|------|----------|------|
| `main` | `version`, `tagsRecords` | version 留空自动自增 |
| `daily` | `month` | YYYYMM 格式，必填 |
| `event` | `eventId`, `title`, `description`, `status`, `startTime`, `endTime`, `outputMode` | outputMode: `zip`/`array` |
| `collection` | `collectionId`, `title`, `description`, `outputMode` | 同 event，无时间字段 |

#### 响应体

```json
{
  "ok": true,
  "type": "main",
  "summary": "30 张 -> main.json (version=5)",
  "files": [
    "X:\\www\\game\\test\\main.json",
    "X:\\www\\game\\test\\manifest.json"
  ],
  "logs": [
    { "t": "22:30:00", "level": "info", "msg": "开始导出 main..." },
    { "t": "22:30:01", "level": "ok", "msg": "导出完成" }
  ]
}
```

#### 日志级别

| level | 颜色 | 说明 |
|-------|------|------|
| `info` | 蓝色 | 信息 |
| `ok` | 绿色 | 成功 |
| `warn` | 黄色 | 警告 |
| `err` | 红色 | 错误 |
