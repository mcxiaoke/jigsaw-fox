# 拼图内容打包工具设计方案（Content Packaging Studio）v1.1

> **状态**：已实现原型（`scripts/packaging/`），待联调
> **日期**：2026-08-28（v1.1 对齐 tagging-spec 21 类）
> **关联规范**：`docs/puzzle-content-storage-and-expansion-design.md`（v3 存储与扩展）、`docs/jigsaw-image-tagging-specification.md`（v1.1 21 Tag 单主标签，已移除 Travel/Vintage/Cozy/Landmarks）
> **原型位置**：`scripts/packaging/server.py` + `scripts/packaging/index.html`（`python scripts/packaging/server.py --open`）
> **目标用户**：内容运营 / 策展（本地一次性打包）
> **运行形态**：按需启动的本地 `Python Server + 单页 HTML` 工具（`python scripts/packaging/server.py` 拉起浏览器即用，关掉即停）

---

## 1. 背景与目标

### 1.1 现状痛点

- `scripts/setup_test_server.py` 仅用 `predefined_tags:43` 随机打标生成 `X:\www\game\test -> http://192.168.1.118/data/www/game/test` 测试数据，无可视化校正，无法生产。
- `main.json:§4.1` 要求 `levels:[{url,tags,order}]` 的 `tags` 参与 `MainContentPipeline.filterByTag:42` 前台 Tab 筛选；现在无稳定产出链路。
- 活动 `events.json:§4.3` 需手写 `title/desc/coverUrl/status/type/zipUrl/displayOrder` 等元数据，易错。

### 1.2 本工具要解决什么

1.  **给任意本地图片目录加 Tag 并导出 `tags.json` 中间件**：承接 AI 自动打标的初筛结果，支持人工秒级校正。
2.  **一键导出生产就绪的 `main.json / events.json / daily YYYYMM.zip / manifest.json` 增量**：直接可用 `ContentManager.syncAll` 拉取验证。
3.  **零常驻、零构建**：单 `Python` 脚本 + 单 `HTML`，双击即用，平时不占用端口/服务。

### 1.3 非目标

- 不做在线 AI 推理（AI 打标在别处离线完成，本工具只消费其 `tags.json`）。
- 不做 CDN 自动发布（测试期手动复制到 `X:\www\game\test`，后期切 `GitHub Pages + Release` 见 §8）。
- 不改 `lib/logic/content/` 任何管线，仅按其既有解析规则产出数据。

---

## 2. 总体架构

```
[图片源目录] --(1.AI离线打标)--> tags.json --(2.本工具加载+人工校正)--> tags.json(已校正)
                                                        │
                                                        ├─► main.json + main/*.webp ─┐
                                                        ├─► events/events.json + events/*.zip ─┤─► 输出目录(outDir)
                                                        └─► daily/YYYYMM.zip ────────┘         │  手动复制
                                                                                              ▼
                                                                        X:\www\game\test  或  GitHub Release
```

**技术选型**：`Python 3.10+ http.server`（标准库）+ 纯原生 `HTML/CSS/JS` 单页，无 `npm` / 无框架。原型已落地于 `scripts/packaging/`。

- 启动：`python scripts/packaging/server.py --port 5173 --open`  自动打开 `http://127.0.0.1:5173`。
- 原理：Python 端只做两件事——① 目录扫描 + 缩略图 `GET /api/thumb?path=...` ② 读写 JSON/Zip。所有交互、筛选、拖拽都在前端内存完成，避免前后端状态同步复杂度。
- 备选降级：若 Python 完全不可用，可把 `index.html` 直接 `file://` 打开（用 `showDirectoryPicker`），但推荐 Python 形态以支持中文路径 + 大目录。

---

## 3. 核心数据格式

### 3.1 目录级 Tag 中间件 `tags.json`（本工具与 AI 的契约）

**定位**：图片目录的副作用文件，与图片同级存放，Git 可选忽略。AI 产出初版，人工在本工具校正后覆盖。

```json
// 实际由 scripts/ai_tag_images.py 产出的 tags.json 为扁平数组（本工具亦兼容此格式）：
// [{"path":"cat_01.jpg","sha1":"...","tag":"Pets","confidence":0.96,"subject":"cat","scene":"indoor home","reason":"...","review_required":false,"model":"qwen3-vl:4b","taxonomy_version":"jigsaw-tag-v1.1-21","correctedTag":"Pets?"}]
// 校正后本工具以 correctedTag 为准（effectiveTag = correctedTag || tag），导出时映射为 tags:["Pets"]
{
  "version": 1,
  "generatedAt": "2026-08-28T10:00:00+08:00",
  "generator": "qwen3-vl:8b jigsaw-tag-v1.1-21",
  "tagVocab": "jigsaw-image-tagging-spec v1.1 (21 tags, single primary)",
  "stats": { "total": 120, "byTag": { "Pets": 18, "Landscapes": 22 } },
  "images": [
    {
      "file": "cat_01.jpg",
      "tag": "Pets",
      "confidence": 0.96,
      "subject": "cat",
      "scene": "indoor home",
      "reason": "The cat is the clear visual subject.",
      "reviewRequired": false,
      "correctedTag": null
    },
    {
      "file": "mountain_lake_03.webp",
      "tag": "Landscapes",
      "confidence": 0.58,
      "reviewRequired": true,
      "correctedTag": "Nature"
    }
  ]
}
```

字段说明：

| 字段 | 来源 | 含义 |
|---|---|---|
| `file` | 文件名（不含目录） | 与 `CanoncialId._cleanFilename:canoncial_id.dart:88` 对齐，导出时用于推导 `main:xxx` |
| `tag` | AI 初标 | 21 枚举之一（`Animals/Pets/Nature/Landscapes/Flowers/Ocean/Birds/Cities/Architecture/Food/Art/Fantasy/Space/Transportation/People/Sports/Seasons/Holidays/Abstract/Cartoon/Others`，已移除 Travel/Vintage/Cozy/Landmarks 并入 Architecture） |
| `confidence` | AI | `0.00-1.00`，`<0.75` 或 `Others` 自动 `reviewRequired=true`（对齐 tagging-spec §11） |
| `correctedTag` | 人工 | 本工具写入；非空时以它为准，空则以 `tag` 为准 |

> **单主标签约束**：每图仅 1 个 `Primary Tag`（v1.1 共 21 类）。`tags.json -> main.json` 时映射为 `tags: ["Pets"]` 单元素数组，兼容 `PuzzleLevelItem.tags: List<String>` 多标签模型（未来可扩展多标签，本期保持单标签以保证 `filterByTag` 命中率）。

### 3.2 导出产物 1：`main.json`（首页主线）

对齐 `puzzle-content-storage-and-expansion-design.md §4.1`：

```json
{
  "version": 121,
  "updatedAt": "2026-08-28T10:00:00+08:00",
  "levels": [
    { "url": "https://cdn.example.com/puzzle/main/101.webp", "tags": ["Pets"], "order": 101 },
    { "url": "https://cdn.example.com/puzzle/main/102.webp", "tags": ["Landscapes"], "order": 102 }
  ]
}
```

- `url` = `httpBase + "/main/" + file`（`file` 保留原扩展名或统一转 `webp`）。
- `order` 默认按文件名自然排序，可在工具中拖拽重排后持久化到 `tags.json` 的隐式 `order` 字段。
- `version` 每次导出自增（或取 `max(order)`）。

### 3.3 导出产物 2：`events.json`（活动中心）

对齐 `§4.3`，工具以“**1 个活动 = 1 个图片子目录 + 1 个表单**”组织：

```json
[
  {
    "id": "cyberpunk_2026",
    "title": "未来赛博都市 · 霓虹幻夜",
    "desc": "6 张限定赛博朋克风拼图",
    "coverUrl": "https://cdn.example.com/puzzle/events/cover_cyberpunk.jpg",
    "status": "active",
    "type": "zip",
    "zipUrl": "https://cdn.example.com/puzzle/events/cyberpunk_2026.zip",
    "displayOrder": 1,
    "startTime": "2026-08-01T00:00:00Z",
    "endTime": "2026-09-10T00:00:00Z"
  }
]
```

- `type: zip` 时工具自动将对应活动目录打包为 `events/{id}.zip`（扁平，仅图片，过滤非图片与 `tags.json`）。
- `type: array` 时 `levels` 填 `httpBase + "/events/{id}/" + file` 列表，无需打包。
- 支持增量：若 `outDir/events/events.json` 已存在，则按 `id` Upsert 合并。

### 3.4 导出产物 3：`daily/YYYYMM.zip`（每日挑战）

零元数据，仅需保证 Zip 内文件名为 `YYYYMMDD.webp` 且通过 `DailyContentPipeline._dailyFileRegex:19` 校验。工具提供“重命名预览”：

```
DSC_001.jpg -> 20260901.webp
IMG_2022.jpg -> 20260902.webp
```

非法日期（如 `20260230`）由 `DailyContentPipeline.isValidDate:86` 逻辑拦截并标红。

---

## 4. 工具功能分解

### 4.1 目录与配置

- **源目录**：任意本地文件夹（支持 `webkitdirectory` 选择），递归扫描 `*.jpg/*.jpeg/*.png/*.webp`。
- **输出目录**：默认为源目录同级的 `out/` 或直接指定 `X:\www\game\test`。
- **HTTP Base**：文本框，默认 `http://192.168.1.118/data/www/game/test`，导出时用于拼接 `url/zipUrl`。
- **记忆**：`localStorage` 保存最近 5 个路径与 `httpBase/version`。

### 4.2 AI 结果接入

- 自动检测源目录下 `tags.json` / `puzzle_tags.json` / `ai_tags.json`，有则加载 `tag/confidence/reviewRequired`。
- 无则全部置为 `tag=Others, confidence=0, reviewRequired=true` 待人工补标。
- 支持“重新导入”覆盖已校正项（二次确认）。

### 4.3 图片网格（核心交互）

- **虚拟滚动网格**：缩略图 `120px` 方形，懒加载；点击放大；文件名 + `CanonicalId` 预览（`main:xxx` / `event:xxx:xxx`）。
- **标记态**：
  - 绿点：已校正确认
  - 黄点：`confidence < 0.75` 或 `Others` 待复核
  - 红点：未打标
- **筛选**：按 `tag / reviewRequired / 未校正` 过滤；按 `tag` 分组统计。
- **批量操作**：框选/Shift 连选/Ctrl 点选 -> 底部浮条“一键设为 Pets / Landscapes / …”。
- **单图校正**：点击图 -> 右侧抽屉 21 个 Tag 单选（中文+英文对照，见 tagging-spec v1.1 表），`confidence` 只读展示。

### 4.4 导出

- **首页导出**：按钮“导出 main.json” -> 校验（是否有 `Others` 残留、是否全量已确认）-> 写 `out/main.json` + 复制图片到 `out/main/`（可选 WebP 转码复用 `export_selected_puzzles.py:183`）。
- **活动导出**：活动面板“新增活动”表单 -> 绑定子目录 -> 导出 `out/events/events.json` + 若 `zip` 则 `out/events/{id}.zip` + 封面复制。
- **每日导出**：选中 `YYYYMM` -> 一键 `out/daily/YYYYMM.zip`。
- **Manifest 联动**：可选勾选“同步更新 manifest.json”，自动 bump `modules.main.version / events.version / daily.currentMonth`。

---

## 5. 前后端接口（Python Server 极简版）

> 全部 `GET/POST` 同源，无鉴权，仅本地回环。

| 方法 | 路径 | 说明 |
|---|---|---|
| `GET /` | 单页 HTML | 工具主界面 |
| `GET /api/scan?dir=D:\raw` | 扫描目录，返回 `[{file,size,w,h,mime}]` + 若存在 `tags.json` 则一并返回 |
| `GET /api/thumb?path=D:\raw\cat.jpg&s=240` | 返回 `image/jpeg` 缩略图（Pillow 等比缩略，`w* h <= 240`） |
| `GET /api/tags?dir=D:\raw` | 读取 `tags.json` |
| `POST /api/tags` `body:{dir, images:[{file,correctedTag}]}` | 原子写回 `tags.json`（先写 `.tmp` 再 `rename`） |
| `POST /api/export/main` `body:{srcDir,outDir,httpBase,version}` | 生成 `main.json` + 复制图片，返回日志 |
| `POST /api/export/events` | 生成 `events.json` + Zip |
| `POST /api/export/daily` | 生成 `daily/YYYYMM.zip` |

前端也支持纯离线模式：不调接口，直接在浏览器内存中生成 JSON/ZIP 供下载（`File System Access API` 不可用时的降级）。

---

## 6. UI 线框（ASCII）

```
┌─ 标题栏：Content Studio  [源: D:\raw\home_202609 ▾] [输出: X:\www\game\test ▾] [httpBase] [版本121] ─┐
├─ 统计条：共120  已确认98  待复核22 (Others 3, 低置信19)  [仅看待复核] [按Tag: Pets 18 ...] ─┤
├─────────────────┬─────────────────────────────────────────┬─────────────────────┤
│ 活动/每日侧栏   │  缩略图网格（3-6列自适应）              │  右侧：校正面板   │
│  [首页]         │  ┌────┐ ┌────┐ ┌────┐ ┌────┐          │  选中: cat_01.jpg │
│  活动:          │  │cat │ │mtn │ │city│ │food│  ...     │  AI: Pets 0.96    │
│   + cyberpunk   │  │Pets│ │Land│ │City│ │Food│          │  [25 Tag 单选]   │
│   + nature      │  └────┘ └────┘ └────┘ └────┘          │  ○ Animals  ○Pets│
│  每日: 202609   │  批量浮条: 已选8  [设为 Pets] [清除]    │  ○ Nature ...    │
│                 │                                         │  [确认] [下一个] │
├─────────────────┴─────────────────────────────────────────┴─────────────────────┤
│ 底部：[保存 tags.json]  [导出 main.json]  [导出 events.zip]  [导出 daily.zip]  日志区        │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 7. 与现有链路的衔接

1.  **AI 侧**：在 `scripts/` 或外部流水线中用 `ollama + qwen3-vl:8b` 按 `tagging-spec §9 JSON Schema + §7 System Prompt` 批量产出 `tags.json`（`temperature=0, format=SCHEMA`），与本工具解耦。
2.  **人工侧**：本工具消费 `tags.json`，校正后覆盖写回。
3.  **测试验证**：导出到 `X:\www\game\test` 后，直接用 `ContentManager` 的 `MainContentPipeline/EventsContentPipeline` 本地同步验证（或 `flutter test`）。
4.  **发布**：后期 `out/` 推送到 `GitHub Repo`，`manifest.json` 指向 `https://cdn.jsdelivr.net/gh/.../main.json` 或 `raw.githubusercontent.com`，Zip 作为 `Release Asset`。

---

## 8. 部署演进

| 阶段 | 部署方式 | manifest 指向 |
|---|---|---|
| 测试期（当前） | 本工具 `outDir = X:\www\game\test`，手动复制 | `http://192.168.1.118/data/www/game/test/manifest.json` |
| 过渡期 | `out/` 提交到私有 Git 仓库 | `https://raw.githubusercontent.com/<org>/puzzle-content/main/manifest.json` |
| 生产期 | GitHub Release 附 Zip + `jsDelivr` 加速 JSON | 主 `jsDelivr` + 备 `raw.githubusercontent` 双 URL（`ManifestRouter` 主备容灾） |

---

## 9. 实施计划（原型已完成 1-3）

| 步骤 | 内容 | 产出 | 状态 |
|---|---|---|---|
| 1 | 冻结 `tagVocab` 21 枚举，前端常量 `TAGS_21` | `scripts/packaging/index.html` 内联 | ✅ 完成 |
| 2 | Python Server `scripts/packaging/server.py`（scan/thumb/tags/export） | 可运行服务 `has_pil` | ✅ 完成 |
| 3 | 单页 HTML（网格+单选+批量+筛选+保存） | `scripts/packaging/index.html` | ✅ 完成 |
| 4 | 导出：main / events / daily 联调，`X:` 盘实测 | `main.json` 自检通过 | ⏳ 待你本地验证 |
| 5 | 打磨：拖拽排序、manifest bump、WebP 可选、GitHub Release | v1.1 发布 | 计划中 |

---

## 10. 附录：21 Tag 前台展示映射（与 tagging-spec v1.1 一致，供前端 Tab 用）

`Animals/ Pets/ Nature/ Landscapes/ Flowers/ Ocean/ Birds/ Cities/ Architecture/ Food/ Art/ Fantasy/ Space/ Transportation/ People/ Sports/ Seasons/ Holidays/ Abstract/ Cartoon/ Others`

> 已移除：`Travel`（归入 Cities/Architecture/Landscapes/Ocean）、`Vintage`（按主体归类）、`Cozy`（归入 Interiors 用户层）、`Landmarks`（并入 Architecture），见 tagging-spec v1.1 §1。

- 首页 Tab 建议默认展示 `全部 + 高频 6-8`（如 `Pets/Landscapes/Nature/Cities/Art/Food/Animals/Ocean`），其余在“更多”中；筛选公式保持 `currentTag == 'all' || level.tags.contains(currentTag)`。
- 统计看板应对 `Others` 单独告警（`Others > 5%` 提示复核，见 tagging-spec §11）。

---

## 11. 原型使用（已可用）

```powershell
# 启动原型（推荐 --open 自动打开浏览器）
python scripts/packaging/server.py --port 5173 --open
# 或后台常驻：python scripts/packaging/server.py --host 127.0.0.1 --port 5173

# 1) 准备 tags.json（AI 侧）
python scripts/ai_tag_images.py D:\raw\home_202609 --output D:\raw\home_202609\tags.json

# 2) 在网页中：填 源目录=D:\raw\home_202609，输出目录=X:\www\game\test，点 扫描
#    网格中单击校正、Ctrl多选批量设标签、保存 tags.json
# 3) 点 导出 main.json → 在 X:\www\game\test\main.json 与 main/*.jpg 验证
#    flutter test / ContentManager.syncAll 可直接拉取
```

- 原型目录：`scripts/packaging/server.py`（API）+ `scripts/packaging/index.html`（前端）+ `scripts/packaging/README.md`。
- 已验证：`api/health`、`api/scan`（69 张）、`api/export/main`（自动 bump version、复制图片、更新 manifest 可选）。

