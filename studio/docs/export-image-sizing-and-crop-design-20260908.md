# Export 图片规格化（目标比例 + 智能裁切 + 长边缩放）方案

> **日期**：2026-09-08（v2 修订：长边 1920、ratio 多选、auto 池收紧、抽公共模块）
> **性质**：需求/设计定稿，未改代码
> **一句话**：export 端复用 `scripts/imgcrop.py` 的成熟算法（抽到公共模块 `crop_compute.py`），把导出图"先按目标比例裁切、再按长边缩放"，让产物落到 `puzzle-image-selection-standard.md` 的规范档位，而不是当前的原图照转。

---

## 1. 现状核查（结论先行）

| 环节 | 现状 | 依据 |
|---|---|---|
| Export 图片尺寸 | 纯格式转码，**不裁不减**，原图分辨率原样输出 | [image_proc.py::convert_image](file:///c:/Home/Projects/jigsawpuzzle/studio/core/image_proc.py#L156-L204) 只 `im.save(...)` |
| 比例"识别" | 在 **Flutter 客户端**，用真实 `width/height` 经 `PuzzleAspectRatio.fromSize()` 归类 | [puzzle_model.dart::fromSize](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/puzzle_model.dart#L123-L139) |
| 比例定义 | 5 档：1:1 / 2:3 / 3:2 / 3:4 / 4:3（2:3/3:2 为一族，4:3/3:4 为一族） | [puzzle_model.dart](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/puzzle_model.dart#L54-L85) |
| 素材规范 | 短边 1080–2160（及格 1080，推荐 1440–1920）；长边 ≤3000；裁切损失 <15% | [puzzle-image-selection-standard.md](file:///c:/Home/Projects/jigsawpuzzle/docs/puzzle-image-selection-standard.md#L26-L31) |
| 客户端硬下限 | 裁切页要求原图短边 ≥1080 px（`kMinOriginalCropPixels = 1080`），低于则锁定 1.0x 不放大 | [crop_puzzle_page.dart](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/crop_puzzle_page.dart#L58-L102) |
| 现成算法 | `scripts/imgcrop.py` 已实现：去背景裁切、自动/强制比例、主体感知 `--smart` 智能裁切、长边缩放、报告 CSV | [imgcrop.py](file:///c:/Home/Projects/jigsawpuzzle/scripts/imgcrop.py) |

**结论**：现有 export 不满足规范（不卡长边、不落档位）。要做"export 时指定尺寸"，直接把 `imgcrop.py` 的核心算法**抽到公共模块** `studio/core/crop_compute.py`，export 与 imgcrop 共用同一份，不复制、不同步，不重复造轮子。

---

## 2. 目标（需求确认）

用户已选定**方案 B：强制目标比例 + 智能裁切 + 长边缩放**：

1. 导出前对每张图做"内容感知框定"（可关）。
2. 按目标比例裁切（自动选档 / 手动多选档）。
3. **等比缩放到长边 = 1920**（只缩小，不放大）。
4. 转码输出（webp/jpg/png，quality 沿用现有参数）。
5. **原图长边 <1920 的图：导出时直接阻断报错**（官方只发布高清图，不做 upscale）。扫描阶段提前警告。

产物做到：**每张导出图落到目标档位、长边固定在 1920、短边按比例自动落在 1440–1920**，与客户端 `fromSize` 归类、裁切页 1080 下限、规范文档三者对齐。

> 五档在 **长边=1920** 下的短边：
> | 档位 | 短边 |
> |---|---|
> | 1:1 | 1920 |
> | 4:3（横）/ 3:4（竖） | 1440 |
> | 3:2（横）/ 2:3（竖） | 1280 |
>
> 全部落在推荐/优质区间，天然规避"长边≤3000"与"短边1080检查"的旧矛盾。

---

## 3. 参数契约（export 请求新增字段）

沿用"六件套必须同口径"原则，试/正式导出同一参数。新增字段如下：

| 字段 | 类型 | 缺省 | 语义 |
|---|---|---|---|
| `targetRatios` | string[] | `["auto"]` | 多选比例族。`"auto"` = 默认池 `{1:1, 4:3族}`；或手动子集 `1:1 / 4:3 / 2:3`（见下"比例族与镜像"） |
| `longTarget` | int | `1920` | **长边**目标（px）。只缩小不放大；建议常量 `1920`，后续不合适直接改常量即可 |
| `cropMode` | string | `"smart"` | `"none"` 不裁切（仅缩放）；`"center"` 居中几何裁切；`"smart"` 主体感知智能裁切 |
| `trimBackground` | bool | `true` | 是否先做去背景裁切（对应 imgcrop `--no-trim` 的反向） |

### 比例族与镜像（自适应，UI 不重复）

- ratio 按**朝向自适应**：每个档位只需一个代表值，内部对原图直接输出匹配朝向的镜像，**不给成对重复选项**。
  - `4:3` 族：横 → `4:3`，竖 → `3:4`（同族，自适应）。
  - `2:3` 族：竖 → `2:3`，横 → `3:2`（同族，自适应）。
  - `1:1` 族：正方形，无镜像。
- `auto` 候选池 = `{1:1, 4:3族}`（**不含 2:3 族**，2:3/3:2 长宽比过窄、手机上体验差，仅手动指定才可用）。
- 手动多选可选：`1:1 / 4:3 / 2:3` 任意子集（`4:3`/`2:3` 内部按朝向自适应出镜像）。

### 约束校验

- **阻断**：原图**长边 < `longTarget`(1920)** 时（无论是否规格化）直接报错拒绝该张导出，提示"原图长边不足"；不放大、不降级放行。
- `targetRatios` 为空或全非法 → 回退 `["auto"]`；含非法值 → 剔除该值。
- `cropMode="none"` 时忽略 `trimBackground`（仅做长边缩放）。
- `longTarget` 建议保持常量固定，不开放给 UI（改需求时改常量）。

---

## 4. 代码落点（后端）

### 4.1 公共算法模块（新增：studio/core/crop_compute.py）

把 `imgcrop.py` 的核心、无 IO、纯计算函数**抽到新增模块** `studio/core/crop_compute.py`，供 imgcrop 与 export 共用，避免双份维护：

```python
# studio/core/crop_compute.py —— 几何/能量裁剪纯函数（无 IO，可复用）
compute_content_box, aspect_crop_box, smart_aspect_crop_box,
compute_saliency_energy, resize_long, select_aspect,
build_ratio_pool, parse/expand_ratio_family
```

- `imgcrop.py` 改为 `from studio.core.crop_compute import ...`（保留自身 CLI/CSV/report_only 外壳，行为不变）。
- `image_proc.py` 新增 `normalize_export_image`，同样从 `crop_compute` 取函数。

### 4.2 规格化入口（image_proc.py 新增）

```python
def normalize_export_image(
    src, dst, *,
    fmt, quality,
    target_ratios=("auto",),      # 多选比例族；"auto" 或 "1:1"/"4:3"/"2:3"
    long_target=1920,
    crop_mode="smart",             # none / center / smart
    trim_background=True,
):
    """打开 → EXIF 校正 → 长边<1920 阻断 → (可选)去背景框定 → 比例裁切 → 长边=1920 → 转码写盘。
    返回 (ok, err, meta)，meta 记录 orig_size/ratio_family/crop_box/out_size。
    阻断时 (False, '源图长边 X < 1920', None)。"""
```

- `auto`/每个手动 ratio 用 `build_ratio_pool` + `expand_ratio_family` 展开成完整候选（5 档），`select_aspect` 取最小损失档，输出该档当前朝向（横/竖自适应）。
- 关键差异：**输出长边取 `long_target`**，对 `aspect` 后状态做"长边=1920 等比缩小"；转码走现有 `fmt/quality`（webp/jpg/png 同 convert_image 分支）。
- `format="original"` 或未开规格化：仍走现有 `convert_image` 原样行为，保证向后兼容；但**原图长边 <1920 的阻断校验对所有导出生效**。

### 4.3 调用点（3 处导出器）

- `main_exporter` / `daily_exporter` / `pack_exporter_base`：现在都是 `convert_images_parallel(tasks)` → `_convert_one_parallel` → `convert_image`（[main_exporter.py#L269](file:///c:/Home/Projects/jigsawpuzzle/studio/exporters/main_exporter.py#L269)、[daily_exporter.py#L172](file:///c:/Home/Projects/jigsawpuzzle/studio/exporters/daily_exporter.py#L172)、[pack_exporter_base.py#L207](file:///c:/Home/Projects/jigsawpuzzle/studio/exporters/pack_exporter_base.py#L207)）。
  改法：在 task 构建时塞入规格化参数，`_convert_one_parallel` 或新 worker 优先调用 `normalize_export_image`；未带规格化参数时退化为 `convert_image`。

### 4.4 manifest / 记录与日志

- **导出数据记录**：试导出 `source_map.json` / 账本 `cropInfo` 字段补记 `normalize` 元数据，**必须含**：
  - `ratio_family` 与最终 `ratio`（如 `4:3` / `3:4`）
  - 源图 `orig_size`（w×h）、内容框 `content_box`、裁窗 `crop_box`（w/h）、输出 `out_size`（w×h）、`out_size_long`/`out_size_short`
  - 便于核对产物是否符合规范。
- **导出进度日志**：`report_progress` / `on_progress` 打点里对每张带规格化的图，除 srс/dst 外**追加 ratio 与 out w×h**（如 `<ratio=4:3 w=1920 h=1620>`），让运营在导出日志里一眼看到每张产物比例与尺寸，无需再翻产物。

### 4.5 依赖

- `crop_compute.py` 依赖 **numpy**（能量图/积分图用）。沿用统一 Python 环境 `C:\Home\Develop\venv`，在 studio 依赖清单增补 `numpy`。imgcrop 本身已在用 numpy，无新增运行负担。

---

## 5. 前端改动（导出工作台第①步）

- 在"导出顺序排序"附近的**新规格设置区**新增：
  - **目标比例（多选）**：`自动（推荐，1:1+4:3） / 1:1 / 4:3 / 2:3`。提示"4:3 竖图自动按 3:4 输出、2:3 横图自动按 3:2 输出；2:3 族仅手动指定"。
  - **裁切方式**：`主体智能裁切（smart，推荐）/ 几何居中 / 不裁切`。
  - 提示文案：说明"长边固定 1920、只缩小不放大；不裁切时仍保证长边缩放到 1920；原图长边<1920 会被阻断"。
- **长边 1920 不开放为 UI 选项**（作为常量，改需求时改代码）。
- 预检（`/api/export/preview` 或前端统计）可加"输出规格摘要"：比例族 × 长边 1920 × 短边估算。
- 试/正式导出共用该参数，试导出产物即按规格生效（所见即所得）。
- **导出范围**：移除导出面板"全部图片"单选，**仅支持按勾选导出**（`openExport` 强制 `exportScope="selected"`，`runExport` 未勾选即中止提示），避免把未勾选/分辨率不足/已导出图混入导出。
- **侧边栏伪分类**：左侧 tag 列表下方新增「✅已导出」(`__exported`) 与「⚠️不合格/像素不足」(`__small_long`) 分类，分别只显示已导出图与长边 <1920 的图（`filteredRecords` 分流，新增 `smallLongCount`）；保留工具栏"隐藏已导出"开关，不激进隐藏这两类图。

---

## 6. 与试导出（trial）的联动

- `trial` 测试时若 `cropMode != none`，会真实执行裁切，需在 `_trial_meta/source_map.json` 里记录 normalize 结果，便于运营肉眼核对"裁切后主体是否完整"。
- 试导出不改 .studio，规格化产物只进 `_trial_{ts}/`，与已实现的 zero-write 约束不冲突。
- 试导出同样受**长边<1920 阻断**约束（试/正式同口径）。

---

## 7. 扫描与导出联动（新增）

- **扫描阶段**：对源图长边 `<1920` 的素材，扫描记录里**标记** `too_small_long` + `long_side`（随 `get_image_info` / `merge_scanned_images` 逐条透传到前端记录），便于运营换图，但扫描不阻断。
- **选图阶段（前端）**：主界面选中卡片时，凡 `too_small_long`（分辨率不足）或 `exported`（已导出）的图一律**置灰不可选**：
  - checkbox `:disabled` + 半透明/灰度卡片 + 角标（"⚠ 分辨率不足" / 已导出的 ✔ 角标）；
  - 统一 `isUnselectable(item)` 判定，`toggleSelect`/`全选`/`反选`/`选待复核`/`选未导出` 全部直接跳过这类图，从源头阻止入选导出。
- **导出阶段**：任何源图长边 `<1920` 时**直接阻断**该张导出并报错（返回失败原因），不放大、不降级放行；`main`/`daily`/`pack` 的 `excludeExported` 继续负责剔除已导出历史图。客户端对第三方图的 upscale 逻辑与官方发布无关，官方只发布高清图。

---

## 8. 验证

1. **单测**（新增）：
   - `normalize_export_image` 对 `1600×2400` 原图（长边 2400 ≥1920，ratio 0.667）强制 `2:3` → 输出短边 1440、**长边 = 1920**。
   - `auto` 只从 `{1:1, 4:3族}` 选档（**不会**落到 2:3/3:2）；从不去背景的图验证 `select_aspect` 按 content_box 口径选档。
   - `cropMode=center` vs `smart` 输出存在（尺寸一致但裁窗可能不同）；`cropMode=none` 不裁、仅长边缩放。
   - **阻断**：源图长边 `1500`、`longTarget=1920` ⇒ 返回 `(False, 阻断提示)`。
   - 退回路径：`format=original` 不触发裁切。
   - 镜像自适应：横图 `4:3` → 输出 `4:3`（1600短×1920长）；竖图 → 输出 `3:4`。
2. **端到端（Playwright，沿用试导出实测方法）**：选 3 张不同比例图，指定 `targetRatios=["1:1"]` + 长边 1920，正式/试导出后核验 out 图长边与比例。
3. **规范对照**：抽样满足"长边=1920、短边在 1440–1920、比例落五档、无强制时裁切损失 <15%"。

---

## 9. 风险与边界

- **像素损失**：`auto`（1:1+4:3）且原图比例接近目标时裁切损失极小；极端图（长宽比 >2.5:1）会损失大，建议 `smart` 或提示换图（对齐规范 §2.5）。2:3 族因比例更窄，手动指定时裁切损失可能偏大，需在 UI 提示。
- **阻断体验**：长边<1920 直接拒导可能让一批历史素材无法导出。对策：扫描提前 warning + 试导出可见报错，运营据此换图；官方图源本就以高清为主，影响面可控。
- **性能**：`smart` 含积分图滑窗 + 能量图，较 `center` 慢；仅在导出（本就耗时）阶段开启，量级可接受。如需可加 `STUDIO_CROP_WORKERS` 并行（复用现有进程池）。`crop_compute` 为纯函数，进程池 worker 可 pickle。
- **口径差异**：export `auto` 按 **content_box（去背景后）比例**选档，客户端 `fromSize` 按**全图比例**归类，两者允许不一致（content_box 更贴合主体，客户端未实现是给的兜底，后续需要再加）。文档不再宣称"口径一致"。
- **向后兼容**：未传新字段时行为与现在完全一致（不裁不减）；唯一新增约束是**长边<1920 阻断**，此规则对所有导出统一生效。

---

## 10. 改动清单摘要

| 文件 | 改动 |
|---|---|
| `studio/core/crop_compute.py`（新增） | 从 imgcrop 抽取 `compute_content_box / aspect_crop_box / smart_aspect_crop_box / compute_saliency_energy / resize_long / select_aspect / build_ratio_pool / expand_ratio_family` 等纯函数 |
| `scripts/imgcrop.py` | 改为 `from studio.core.crop_compute import ...`，保留 CLI/CSV 外壳，行为不变 |
| `studio/core/image_proc.py` | 新增 `normalize_export_image`（长边<1920 阻断 + 比例族裁切 + 长边=1920 缩放 + 转码）；`_convert_one_parallel` 支持规格化 task；标注 numpy 依赖 |
| `studio/exporters/main_exporter.py` / `daily_exporter.py` / `pack_exporter_base.py` | plans/zip_entries 透传规格化参数；source_map 记 normalize 元数据 |
| studio 扫描器 | 源图长边 `<1920` 记 `too_small_long` warning |
| `studio/static/js/app.js` / `index.html` / `css/studio.css` | 导出第①步新增比例多选 + 裁切方式设置（长边 1920 固定） |
| `studio/test_studio.py` + 新增 `test_image_proc.py` / `test_crop_compute.py` | 规格化单测 + 端到端实测 |
| `studio` 依赖清单 | 增补 `numpy`（用 `C:\Home\Develop\venv`） |

> 注：`docs/puzzle-image-selection-standard.md`（长边≤3000）为较早的人工选图标准，本次**不改动**，仅 studio 侧导出按长边 1920 产出。

> 待用户确认后进入实现。当前仅方案，未改任何代码。