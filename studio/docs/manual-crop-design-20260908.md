# 手动画裁切框设计方案

> 日期: 2026-09-08
> 状态: 待实施

## 1. 目标

在 Content Studio 大图查看器中，允许用户手动画裁切框（限定比例为 1:1 / 3:4 / 4:3 等），所见即所得。保存后导出时直接使用该框裁切，跳过自动 smart crop。未画框的图仍走系统自动算法。

## 2. 表结构决策：通用 vs 单独建表

### 背景

用户现有自定义参数包括但不限于：
- 手动裁切框（百分比坐标 + 比例）
- 用户显式设定的 tags
- 用户设定的 ratio 偏好

数据量最多几千张。

### 方案：单张 `user_overrides` 通用表 + JSON 扩展列

```sql
CREATE TABLE IF NOT EXISTS user_overrides (
    hash        TEXT PRIMARY KEY,   -- 与 file_cache.hash 关联
    crop_x0     REAL,                -- 手动裁切框百分比 0.0~1.0 (null=未设置)
    crop_y0     REAL,
    crop_x1     REAL,
    crop_y1     REAL,
    crop_ratio  TEXT,                -- '1:1' / '3:4' / '4:3' / null
    tags_json   TEXT DEFAULT '',     -- 用户显式 tags (JSON array, null=未设置)
    extras_json TEXT DEFAULT '',     -- 预留扩展字段 (JSON object)
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);
```

### 决策理由

| 考量 | 通用表 | 单独建表 |
|------|--------|---------|
| 数据量 | 几千张，SQLite 单表无压力 | 同左 |
| 查询 | 一条 JOIN 拿到所有用户覆盖 | 多表 JOIN，SQL 更长 |
| 扩展 | 加列即可，或塞 extras_json | 新建表 + 新 JOIN |
| 前端 merge | 一次请求拿到全部覆盖 | 多次请求或多端点 |
| 冲突可能 | 无，各字段语义独立 | 无 |

选通用表：数据量小、查询简单、扩展方便、前端一次 merge。裁切框用固定列（高频查询），tags 和未来扩展用 JSON 列（低频/灵活）。

`extras_json` 预留为 JSON object，未来任何用户自定义参数（ratio 偏好、自定义水印位置等）直接塞进去，不需改表结构。

## 3. 技术选型：Cropper.js v1

| 维度 | 选择 |
|------|------|
| 版本 | v1（v1 分支维护中，API 稳定） |
| 引入方式 | CDN（cdnjs），与现有 Vue 3 CDN 架构一致 |
| 体积 | ~50KB min+gzip |
| API 风格 | 命令式 `new Cropper(img, opts)` / `cropper.getData()` |
| 比例锁定 | `aspectRatio: 1` / `aspectRatio: 3/4` |
| Vue 兼容 | `onMounted` 初始化，`onBeforeUnmount` 销毁 |

CDN 链接：
```html
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/cropperjs/1.6.2/cropper.min.css">
<script src="https://cdnjs.cloudflare.com/ajax/libs/cropperjs/1.6.2/cropper.min.js"></script>
```

百分比坐标提取：
```js
const data = cropper.getData();           // {x, y, width, height} 原图像素
const imgData = cropper.getImageData();   // {naturalWidth, naturalHeight}
const box = {
  crop_x0: data.x / imgData.naturalWidth,
  crop_y0: data.y / imgData.naturalHeight,
  crop_x1: (data.x + data.width) / imgData.naturalWidth,
  crop_y1: (data.y + data.height) / imgData.naturalHeight,
};
```

## 4. 交互流程

```
大图查看器 (viewer)
  |
  ├── 默认模式
  │     ├── 显示图片 (object-fit: contain, 完整显示)
  │     ├── 绿色实线框 = auto content_box
  │     ├── 红色虚线框 = auto crop_box (smart crop)
  │     └── 蓝色实线框 = manual crop_box (如果已存在)
  |
  ├── 点击「画裁切框」按钮 → 进入裁切模式
  │     ├── Cropper.js 激活，覆盖在图片上
  │     ├── 比例选择按钮组: 1:1 | 3:4 | 4:3 | 自由
  │     ├── 拖拽画框、8 点调整、拖动移动
  │     ├── 底部显示: [保存裁切框] [取消]
  │     └── 已有手动框时预载到 Cropper
  |
  ├── 保存 → POST /api/crop/manual {hash, x0, y0, x1, y1, ratio}
  │     → 蓝框显示，缩略图角标 ✂️
  │     → Cropper 销毁，回到默认模式
  |
  └── 取消 → Cropper 销毁，不保存，回到默认模式
```

竖图修复：`viewer-content` 加 `min-height: 0`（flexbox 标准修复）。

## 5. 文件改动清单

### 5.1 `studio/core/cache_db.py` (+~60 行)

- `_init_tables` 中加 `CREATE TABLE IF NOT EXISTS user_overrides`
- `get_user_override(hash) -> dict | None`：查单条
- `set_user_override(hash, crop_box=None, crop_ratio=None, tags=None) -> bool`：插入/更新（REPLACE INTO 语义）
- `get_all_user_overrides() -> dict[str, dict]`：批量返回 `{hash: {crop_x0, crop_y0, ...}}`
- `delete_user_override(hash) -> bool`：删除单条（清除手动裁切框）

### 5.2 `studio/core/image_proc.py` (+~30 行)

`normalize_image` 函数签名加 `manual_box: tuple | None = None`：

```python
def normalize_image(
    src_path, dst_path,
    target_ratios=..., long_target=...,
    crop_mode="smart", trim_background=True,
    manual_box=None,                # 新增: (x0, y0, x1, y1) 像素坐标
) -> tuple[bool, str | None, dict | None]:
```

逻辑变更（在 step 1 之前）：
```python
if manual_box:
    # 有手动裁切框: 直接用，跳过 compute_content_box + select_aspect + smart_crop
    crop_box = manual_box
    mode = "manual"
    content_box = manual_box  # meta 记录用
    cw = max(1, crop_box[2] - crop_box[0])
    ch = max(1, crop_box[3] - crop_box[1])
    # 跳到 step 4 (resize_long)
else:
    # 原逻辑: compute_content_box → select_aspect → smart_aspect_crop_box
    ...
```

### 5.3 `studio/server.py` (+~100 行)

**新端点：**

- `POST /api/crop/manual`
  - body: `{hash, x0, y0, x1, y1, ratio}`
  - 调用 `cache_db.set_user_override`
  - 返回 `{ok: true}`

- `GET /api/crop/manual?dir=...`
  - 调用 `cache_db.get_all_user_overrides()`
  - 返回 `{ok: true, overrides: {hash: {crop_x0, crop_y0, crop_x1, crop_y1, crop_ratio}}}`

- `DELETE /api/crop/manual?hash=...`
  - 调用 `cache_db.delete_user_override`
  - 返回 `{ok: true}`

**导出端改动：**

在 `/api/export` 处理逻辑中，导出前批量查询 `user_overrides`，构建 `{hash: manual_box}` 字典（百分比→像素坐标转换），传入 `normalize_image`。

百分比 → 像素转换：
```python
W, H = im.size
x0 = int(override["crop_x0"] * W)
y0 = int(override["crop_y0"] * H)
x1 = int(override["crop_x1"] * W)
y1 = int(override["crop_y1"] * H)
manual_box = (x0, y0, x1, y1)
```

### 5.4 `studio/static/js/api.js` (+~30 行)

```js
async function saveManualCrop(hash, box) { ... }   // POST /api/crop/manual
async function fetchManualCrops(dir) { ... }        // GET /api/crop/manual
async function deleteManualCrop(hash) { ... }       // DELETE /api/crop/manual
```

### 5.5 `studio/static/js/app.js` (+~150 行)

- `manualCropCache` reactive ref：`{hash: {crop_x0, ...}}`
- `cropMode` reactive ref：`false`（是否在裁切模式）
- `cropAspectRatio` reactive ref：`1`（当前选定的比例）
- `cropperInstance` 变量：Cropper 实例引用
- `enterCropMode()`：初始化 Cropper，绑定到 viewer-img
- `exitCropMode(save)`：销毁 Cropper，save=true 时调 API 保存
- `onCropModeChange()`：切换比例时更新 Cropper aspectRatio
- `manualCropOverlayStyle` computed：蓝框样式（百分比定位）
- `fetchManualCrops` 在 scan 后调用，merge 到 records
- `hasManualCrop` computed：当前 viewer item 是否有手动裁切框

### 5.6 `studio/static/index.html` (+~40 行)

- `<head>` 加 Cropper.js CSS/JS CDN
- viewer-header 加「画裁切框」按钮
- viewer-content 下方加裁切模式工具栏（比例选择 + 保存/取消）
- 蓝框 overlay div（与现有红框 overlay 并列）
- 缩略图角标加 ✂️ 标记

### 5.7 `studio/static/css/studio.css` (+~30 行)

- `.viewer-content { min-height: 0; }`（竖图修复）
- `.manual-crop-overlay`（蓝框样式）
- `.crop-mode-toolbar`（裁切模式工具栏）
- `.crop-ratio-btn` / `.crop-ratio-btn.active`（比例按钮）
- `.thumbnail-badge.manual-crop`（缩略图角标）

## 6. 导出管线集成

```
导出请求
  |
  ├── 查询 user_overrides → {hash: override_dict}
  |
  ├── 遍历待导出图片
  │     ├── 有 manual override?
  │     │     └── 百分比→像素 → manual_box = (x0,y0,x1,y1)
  │     └── 无 → manual_box = None
  │
  └── normalize_image(src, dst, ..., manual_box=manual_box)
        ├── manual_box is not None → 直接 crop → resize_long
        └── manual_box is None → 原逻辑 (compute_content_box → select_aspect → smart_crop)
```

## 7. 数据流

```
scanDirectory()
  ├── GET /api/scan → records (含 quality scores)
  ├── GET /api/quality/scores → merge quality scores
  └── GET /api/crop/manual → merge manual crop overrides
        └── record.manualCrop = {x0_pct, y0_pct, x1_pct, y1_pct, ratio} | null

viewer 打开
  └── cropOverlayStyle (红框, auto) + manualCropOverlayStyle (蓝框, manual) 并列显示

保存手动裁切框
  └── POST /api/crop/manual → DB 写入 → 前端 reactive 更新 → 蓝框显示

导出
  └── server 查 user_overrides → 传 manual_box → normalize_image
```

## 8. 边界与约束

- **hash 关联**：图片内容变 → hash 变 → 旧 override 自动失效（孤儿数据不清理也不影响，量小）
- **trim_background=false + manual_box**：manual_box 优先，trim_background 不生效（符合预期：手动框就是最终框）
- **crop_mode != smart + manual_box**：manual_box 优先（同上）
- **source 长边不足阻断**：仍然生效，manual_box 不跳过长边检查
- **Cropper.js CDN 不可用**：裁切功能不可用，但不影响查看和自动裁切（graceful degradation）
- **多实例并发**：user_overrides 写操作用 REPLACE INTO，无并发问题
