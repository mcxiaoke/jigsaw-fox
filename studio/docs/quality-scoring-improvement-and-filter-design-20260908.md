# 质检评分改进 + Smart Crop Ratio 感知 + 前端分数过滤 设计

> 创建日期: 2026-09-08
> 状态: 设计阶段 → 实施中
> 涉及文件: `quality_evaluator.py`, `app.js`, `index.html`, `studio.css`

---

## 1. 背景与目标

### 1.1 当前问题

1. **质检评分不够精细**：四周边框大片纯色/虚化但裁切后主体完整且尺寸充足的图片，当前被扣分降级，但实际上经过 smart crop 裁切后完全可做拼图素材。
2. **质检与导出 ratio 不一致**：质检不考虑最终导出比例，而导出时按 ratio 裁切；质检看到的"全图死区"与导出后"裁切框内死区"是两个不同视角。
3. **前端缺少分数过滤**：只能按 S/A/B/C/F 等级过滤，无法按具体分数区间过滤，也无法快速筛选"可升级"图片。
4. **详情页无裁切框预览**：质检结果显示裁切建议文字，但无法直观看到裁切框在原图上的位置。

### 1.2 设计目标

- 质检阶段复用导出管线中的 smart crop 算法，按与导出一致的 ratio 计算裁切框
- 当"边框死区高但裁切后主体短边≥1200px"时提分
- 前端增加分数区间过滤和可升级筛选
- 详情页大图上叠加裁切框 overlay

---

## 2. Ratio 口径

### 2.1 导出侧现状

`crop_compute.py` 中 `AUTO_FAMILIES = ("1:1", "4:3")`，即 `expand_ratio_families(["auto"])` 实际展开为 `["1:1", "4:3"]`。

导出管线 (`image_proc.py: normalize_export_image`) 的完整链路：
```
开图 → EXIF 矫正 → 长边阻断(8192px) 
  → compute_content_box(pil_img) → content_box=(x0,y0,x1,y1) [原图坐标]
  → build_ratio_pool(expand_ratio_families(target_ratios)) → ratio_pool=[(value,label)]
  → select_aspect(content_aspect, ratio_pool) → 选最小损失比例
  → smart_aspect_crop_box(img, content_box, target) → 最终裁切框
  → resize_long(cropped, 2000) → 转码
```

### 2.2 质检侧选择

质检侧直接引用 `crop_compute.AUTO_FAMILIES`，与导出侧完全一致：

```python
from studio.core.crop_compute import AUTO_FAMILIES  # ("1:1", "4:3")
QUALITY_EVAL_RATIO_POOL = build_ratio_pool(expand_ratio_families(list(AUTO_FAMILIES)))
```

这样质检和导出使用同一份常量定义，修改 `AUTO_FAMILIES` 时双方同步。

---

## 3. 质检算法改进 (`quality_evaluator.py`)

### 3.1 算法链路

在 `evaluate_image_bgr` → `_evaluate_crop` 之后、`_compute_score` 中，新增 `_compute_smart_crop(pil_img)` 方法：

```
_compute_smart_crop(pil_img):
  1. content_box = crop_compute.compute_content_box(pil_img)
     → 返回 (x0, y0, x1, y1) 原图坐标
  2. content_aspect = (x1-x0) / (y1-y0)
  3. target = crop_compute.select_aspect(content_aspect, QUALITY_EVAL_RATIOS)
     → 选最小损失的比例
  4. crop_box = crop_compute.smart_aspect_crop_box(pil_img, content_box, target)
     → 在 content_box 内按 target ratio 滑窗定位最佳裁切框
  5. subject_short_side = min(crop_box_width, crop_box_height)
  6. 返回 {content_box, crop_box, target_label, subject_short_side}
```

### 3.2 提分规则

在 `_compute_score` 中，当前评分逻辑：
```
base = texture_score(35) + color_score(30) + balance_score(35)  # 满分100
penalty: core_dead_ratio>0.02 扣分, border_dead_ratio>0.10 扣分, laplacian<50 扣分
score = max(0, base - penalty)
grade: S(>=85) / A(>=70) / B(>=55) / C(>=40) / F(<40)
```

新增提分逻辑（在 penalty 之后、grade 判定之前）：
```python
# Smart crop 提分
if smart_crop_info and smart_crop_info.get("subject_short_side", 0) >= 1200:
    border_dead = metrics.get("border_dead_ratio", 0)
    core_dead = metrics.get("core_dead_ratio", 0)
    # 条件：边框死区较高(>=15%) 但核心死区低(<8%)
    # 说明主体完整，只是四周大片纯色/虚化，裁切后质量好
    if border_dead >= 0.15 and core_dead < 0.08:
        # 计算裁切后的预估死区
        # 裁切框内的死区 ≈ core_dead（因为裁掉了边框死区）
        # 预估分数提升：惩罚分回补 border_dead 部分的扣分
        boost = min(penalty * 0.6, 20)  # 最多回补20分
        score = min(100, score + boost)
        score_boosted = True
```

提分后重新判定 grade。

### 3.3 新字段

`_empty_result` / `evaluate_image_bgr` 返回的 dict 中新增以下字段（塞入 `details` 子 dict，不改 quality_cache 表结构）：

| 字段 | 类型 | 说明 |
|------|------|------|
| `details.crop_box` | `[x0, y0, x1, y1]` | smart crop 裁切框原图坐标 |
| `details.content_box` | `[x0, y0, x1, y1]` | 主体内容边界框原图坐标 |
| `details.crop_ratio` | `str` | 选中的比例标签，如 "1:1" 或 "2:3" |
| `details.subject_short_side` | `int` | 裁切后主体短边像素值 |
| `details.score_boosted` | `bool` | 是否因 smart crop 提分 |
| `details.crop_w` | `int` | 裁切框宽度 |
| `details.crop_h` | `int` | 裁切框高度 |

`crop_suggestion` 文字描述更新为精确描述：
```
"✂️ 建议 2:3 裁切 → 1334×2000px (主体短边1334px)"
```

### 3.4 缓存兼容

- `quality_cache` 表的 `details_json` 列直接塞入新字段，不改表结构
- 已有 49 条缓存中 `crop_box` 为空 → 前端不显示 overlay，不影响现有功能
- 用户需 force 重评才能获得新字段

### 3.5 时间开销

- `compute_content_box`: ~10-30ms/张（PIL resize + numpy 窗口标准差 + 行列 march）
- `smart_aspect_crop_box`: ~5-15ms/张（能量积分图滑窗）
- 12 线程并行 500 张约增加 2-4s 总耗时，可接受

---

## 4. 前端分数过滤 (`app.js` + `index.html`)

### 4.1 新增 reactive 状态

```javascript
const filterScoreMin = ref("");   // 分数下限，空=不限
const filterScoreMax = ref("");   // 分数上限，空=不限
const filterUpgradeable = ref(false); // 仅看可升级(score_boosted)图片
```

### 4.2 filteredRecords 追加过滤

在 `filteredRecords` computed 中，品质评级过滤（步骤4）之后追加：

```javascript
// 4.5 分数区间过滤
if (filterScoreMin.value !== "") {
    list = list.filter((r) => r.quality && r.quality.score >= Number(filterScoreMin.value));
}
if (filterScoreMax.value !== "") {
    list = list.filter((r) => r.quality && r.quality.score <= Number(filterScoreMax.value));
}
// 4.6 可升级过滤
if (filterUpgradeable.value) {
    list = list.filter((r) => r.quality?.details?.score_boosted === true);
}
```

### 4.3 前端 UI (`index.html`)

在品质下拉框（`filterGrade`）右侧追加：

```html
<!-- 分数区间过滤 -->
<div style="display: flex; align-items: center; gap: 4px; font-size: 12px; color: var(--text-muted);">
    <span>分数:</span>
    <input v-model="filterScoreMin" type="number" min="0" max="100" placeholder="min"
           style="width: 42px; border: 1px solid var(--line); border-radius: 4px; padding: 3px 4px; font-size: 12px;" />
    <span>~</span>
    <input v-model="filterScoreMax" type="number" min="0" max="100" placeholder="max"
           style="width: 42px; border: 1px solid var(--line); border-radius: 4px; padding: 3px 4px; font-size: 12px;" />
    <label style="display: flex; align-items: center; gap: 2px; cursor: pointer; white-space: nowrap;">
        <input type="checkbox" v-model="filterUpgradeable" style="margin: 0;" />
        <span>可升级</span>
    </label>
    <!-- 快捷按钮组 -->
    <button class="btn xs" @click="filterScoreMin='80'; filterScoreMax=''; filterGrade=''; filterUpgradeable=false;"
            style="padding: 1px 6px; font-size: 11px;">≥80</button>
    <button class="btn xs" @click="filterScoreMin='60'; filterScoreMax='79'; filterGrade=''; filterUpgradeable=false;"
            style="padding: 1px 6px; font-size: 11px;">60-79</button>
    <button class="btn xs" @click="filterScoreMin=''; filterScoreMax='44'; filterGrade=''; filterUpgradeable=false;"
            style="padding: 1px 6px; font-size: 11px;">&lt;45</button>
    <button class="btn xs" @click="filterScoreMin=''; filterScoreMax=''; filterGrade=''; filterUpgradeable=true;"
            style="padding: 1px 6px; font-size: 11px;">⬆ 可升级</button>
    <button class="btn xs" @click="filterScoreMin=''; filterScoreMax=''; filterGrade=''; filterUpgradeable=false;"
            style="padding: 1px 6px; font-size: 11px;">清除</button>
</div>
```

### 4.4 return 暴露

在 `return` 对象中追加：
```javascript
filterScoreMin,
filterScoreMax,
filterUpgradeable,
```

---

## 5. 详情页裁切框展示 (`app.js` + `index.html` + `studio.css`)

### 5.1 大图查看器 overlay

在 `viewer-content` 中的 `<img class="viewer-img">` 之后追加一个 overlay div：

```html
<div class="viewer-content" style="position: relative;">
    <button class="viewer-nav-btn prev" @click="prevViewer">❮</button>
    <img ... class="viewer-img" ref="viewerImg" @load="onViewerImgLoad" />
    <!-- Smart Crop 裁切框 overlay -->
    <div
        v-if="currentViewerItem?.quality?.details?.crop_box && viewerImgRect.width > 0"
        class="crop-overlay"
        :style="cropOverlayStyle"
    >
        <div class="crop-overlay-label">
            {{ currentViewerItem.quality.details.crop_ratio }} | 
            {{ currentViewerItem.quality.details.crop_w }}×{{ currentViewerItem.quality.details.crop_h }}px
            <span v-if="currentViewerItem.quality.details.score_boosted">⬆</span>
        </div>
    </div>
    <button class="viewer-nav-btn next" @click="nextViewer">❯</button>
</div>
```

### 5.2 overlay 定位计算

`viewer-img` 使用 `object-fit: contain`，图片在容器内居中显示，实际显示区域可能小于容器。需要计算图片实际渲染区域。

```javascript
const viewerImgRect = ref({ width: 0, height: 0, left: 0, top: 0 });

const onViewerImgLoad = () => {
    nextTick(() => {
        const img = ref(null); // 需绑定 ref
        // ... 获取 img 元素的 getBoundingClientRect()
    });
};

const cropOverlayStyle = computed(() => {
    const item = currentViewerItem.value;
    if (!item?.quality?.details?.crop_box) return {};
    const [x0, y0, x1, y1] = item.quality.details.crop_box;
    const imgW = item.width || 0;   // 原图宽度
    const imgH = item.height || 0;  // 原图高度
    if (!imgW || !imgH) return {};
    // 裁切框在原图上的百分比
    const leftPct = (x0 / imgW) * 100;
    const topPct = (y0 / imgH) * 100;
    const widthPct = ((x1 - x0) / imgW) * 100;
    const heightPct = ((y1 - y0) / imgH) * 100;
    return {
        left: leftPct + '%',
        top: topPct + '%',
        width: widthPct + '%',
        height: heightPct + '%',
    };
});
```

> 注意：`object-fit: contain` 下图片有 letterbox，overlay 需基于图片实际显示区域而非容器。简化方案：让 overlay div 与 img 处于同一 flex 层，overlay 用 `position: absolute` 参照 img 实际边界。由于 `object-fit: contain` 的复杂性，实际实现时需要用 `onLoad` 事件获取 img 的 `naturalWidth/naturalHeight` 和 `getBoundingClientRect()` 计算实际渲染偏移。或者更简单的方案：把 overlay 包在一个与图片同等大小的 wrapper div 里。

### 5.3 CSS (`studio.css`)

```css
.crop-overlay {
    position: absolute;
    border: 2px dashed rgba(239, 68, 68, 0.8);
    background: rgba(239, 68, 68, 0.08);
    pointer-events: none;
    box-sizing: border-box;
    z-index: 10;
}
.crop-overlay-label {
    position: absolute;
    bottom: 100%;
    left: 0;
    background: rgba(239, 68, 68, 0.9);
    color: #fff;
    font-size: 11px;
    padding: 1px 6px;
    border-radius: 3px;
    white-space: nowrap;
    margin-bottom: 2px;
}
```

### 5.4 旧缓存兼容

当 `details.crop_box` 不存在或为 null 时，`v-if` 条件不满足，overlay 不渲染，无影响。

---

## 6. 不改动的文件

| 文件 | 原因 |
|------|------|
| `crop_compute.py` | 只读复用其 `compute_content_box` / `select_aspect` / `smart_aspect_crop_box` / `RatioValue` |
| `server.py` | 不新增端点，`POST /api/quality/batch` 返回的 details 已包含新字段，前端直接读取 |
| `cache_db.py` | 新字段塞入 `details_json`，不改表结构 |

---

## 7. 实施顺序

1. **备份** `quality_evaluator.py`, `app.js`, `index.html` → `temp/backups/`
2. **后端** `quality_evaluator.py`: 
   - import `crop_compute` 
   - 定义 `QUALITY_EVAL_RATIOS`
   - 新增 `_compute_smart_crop(pil_img)` 方法
   - 在 `evaluate_image_bgr` 中调用 `_compute_smart_crop`
   - 在 `_compute_score` 中实现提分逻辑
   - 新字段写入 `details` dict
   - 更新 `crop_suggestion` 文字
3. **前端过滤** `index.html` + `app.js`:
   - 加分数 min/max 输入 + 可升级复选框 + 快捷按钮
   - 加 reactive 和 filteredRecords 过滤
4. **详情页 overlay** `index.html` + `app.js` + `studio.css`:
   - 加 crop overlay div
   - 加 `cropOverlayStyle` computed
   - 加 `onViewerImgLoad` 处理
   - 加 CSS
5. **测试验证**:
   - `python -m py_compile quality_evaluator.py`
   - `node --check app.js` (如果环境支持)
   - `python -m pytest test_studio.py -k quality`
   - curl 端到端：`POST /api/quality/batch` + `GET /api/job/status` 检查 details 含新字段
   - 浏览器验证分数过滤和裁切框 overlay

---

## 8. 风险与注意事项

1. **Ratio 口径差异**：用户口述 auto 档 1:1+2:3，但代码 `AUTO_FAMILIES=("1:1","4:3")`。质检侧硬编码 1:1+2:3，不影响导出侧。若后续需统一，需改 `crop_compute.py`。
2. **性能**：smart crop 每张增加 15-45ms，12 线程并行 500 张约增 2-4s 总耗时，可接受。
3. **旧缓存**：已有缓存不含新字段，需 force 重评。前端在 `crop_box` 为空时不显示 overlay，不影响现有功能。
4. **overlay 定位精度**：`object-fit: contain` 下图片有 letterbox，overlay 需基于图片实际显示区域。实现时需用 img 的 `getBoundingClientRect()` 或 `onLoad` 事件计算偏移。如果精度不够，降级为不显示 overlay。
