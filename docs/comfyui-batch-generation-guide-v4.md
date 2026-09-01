# ComfyUI 批量生成拼图素材操作指南 v4

> **文档状态**：定稿 v4.4（diag2→diag8 六轮诊断验证，840 张全量检测通过）
> **创建日期**：2026-09-01
> **Python 环境**：`C:\Home\Develop\venv`（已预装 numpy / Pillow / opencv-python）
> **关联文档**：`docs/comfyui-batch-generation-guide.md`（v1.0 基础版，含模型选型与环境搭建）
> **配套文件**：`scripts/my_comfyui_batch_gen_v4.py`、`scripts/my_prompt_library_v4.json`、`scripts/zimage_api_workflow.json`、`scripts/diagnose_images.py`、`temp/build_v4_library.py`

---

## 1. v4 相对 v3 的变化

v4 在 v3（`my_prompt_library.json` v3.0 + `my_comfyui_batch_gen.py`）基础上经过 12 项修复（F1-F12），核心解决三个问题：

| 问题 | v3 现状 | v4 修复 | 修复编号 |
|---|---|---|---|
| **大面积虚化/浅景深** | quality_suffix 含 `focal point`、`close-up`、`shallow`、`soft` 等触发词 | 全部清除，替换为显式 `deep depth of field` | F3-F8 |
| **主体偏移到画框边缘** | 176/252 subject 用 `at the left edge` / `in the lower left` 等四象限定位 | 自动正则替换为 `at center` / `scattered across the foreground` | F11 |
| **主体偏小、周围空荡** | viewpoint 含 `wide-angle view` + Transportation optics 写死广角 | 移除广角指令，改为 `medium shot view` + `prominent and filling most of the frame` | F12 |

此外还有：

| 改进 | 说明 | 修复编号 |
|---|---|---|
| style 从全局 8 条（7/8 插画）改为按 tag 分池 | 现实类 tag 走摄影池（77%配额），插画类走插画池（23%） | — |
| subject 空间描述改写 | Nature:0000 / Cities:0000 从"前景元素堆叠"改为"场景+纵深" | F10 |
| 默认参数回归官方推荐 | cfg 1.1→1.0, steps 9→8（速度提升约 2.3 倍） | — |
| `--steps` / `--cfg` 命令行参数加范围校验 | steps 4-20, cfg 1.0-2.0 | — |

---

## 2. 文件清单

| 文件 | 用途 | 备注 |
|---|---|---|
| `scripts/my_comfyui_batch_gen_v4.py` | 批量生成脚本（运行时） | 纯标准库，无需 pip install |
| `scripts/my_prompt_library_v4.json` | v4 prompt 库（运行时读取） | 由 build 脚本生成，不要手编 |
| `scripts/zimage_api_workflow.json` | ComfyUI 工作流（API 格式） | 10 节点，已验证 |
| `scripts/diagnose_images.py` | 图片质检脚本 | 依赖 venv 的 numpy/PIL/cv2 |
| `temp/build_v4_library.py` | prompt 库生成器（开发时） | 从 `my_prompt_library.json` 生成 v4 库 |
| `temp/build_v4_library.py` 中的 SUBJECT_REWRITE | 手动 subject 改写表 | 目前只有 Nature:0 / Cities:0 |

---

## 3. 环境准备

### 3.1 ComfyUI

参见 v1.0 指南 §2（模型文件、启动参数）。启动参数不变：

```
--fast fp8_matrix_mult --fp8_e4m3fn-text-enc --use-ck-attention
```

### 3.2 Python venv

检测和质检脚本使用 `C:\Home\Develop\venv`，已预装 numpy / Pillow / opencv-python：

```powershell
# 验证环境
& "C:/Home/Develop/venv/Scripts/python.exe" -c "import numpy, PIL, cv2; print('OK')"
```

生成脚本 `my_comfyui_batch_gen_v4.py` 纯标准库，用任意 Python 3.10+ 即可。

---

## 4. Prompt 库结构

`my_prompt_library_v4.json` 的顶层结构：

```
{
  "version": "4.4",
  "model_hint": "z-image-turbo-fp8 (Apache 2.0, 8 steps, CFG 1.0)",
  "generation": { "steps": 8, "cfg": 1.0, "sampler": "res_multistep", "scheduler": "simple" },
  "ratios": { "1:1": {...}, "2:3": {...}, "3:2": {...} },
  "quality_suffix": "deep depth of field, consistent sharpness across the whole image, ...",
  "modifiers": { "lighting": [...], "viewpoint": [...], "atmosphere": [...] },
  "style_pools": { "photo": [...8条], "illust": [...6条] },
  "tags": [
    {
      "id": "Transportation",
      "zh": "交通",
      "tier": "A",
      "quota": 140,
      "ratios": ["1:1", "2:3", "3:2"],
      "extra": "",
      "subjects": [...12条],
      "style_pool": "photo",
      "visual_anchors": [...4条],
      "optics": [...2条]
    },
    ...
  ]
}
```

### 4.1 Prompt 组装顺序

每个 prompt 由以下部分逗号拼接（全部正向，CFG=1.0 时 negative 无效）：

```
subject, tag.extra, visual_anchor, lighting, viewpoint, style, atmosphere, optics, quality_suffix
```

- `subject`：从 tag 的 12 个 subject 中按 round-robin 选取
- `lighting` / `viewpoint` / `atmosphere`：从 `modifiers` 池中随机选（viewpoint 有 per-tag deny list）
- `style`：从 `style_pools[tag.style_pool]` 随机选
- `optics`：从 `tag.optics` 随机选（部分 tag 为空）
- `quality_suffix`：全局固定后缀

### 4.2 Style 池分配

| 池 | 条数 | 使用 tag | 配额占比 |
|---|---|---|---|
| photo | 8 | Animals, Pets, Nature, Landscapes, Flowers, Ocean, Birds, Cities, Architecture, Food, Transportation, People, Sports, Seasons, Others | 77% |
| illust | 6 | Art, Fantasy, Space, Holidays, Abstract, Cartoon | 23% |

### 4.3 配额

不加 `--per-tag` 时按库内 `quota` 字段跑，全量合计 2280 prompt × 2 reseed = 4560 张。

| 级别 | tag | quota/tag |
|---|---|---|
| A（高配额） | Nature, Landscapes, Flowers, Cities, Architecture, Food, Art, Transportation, Seasons, Holidays | 140 |
| B（中配额） | Animals, Pets, Birds, Fantasy, People, Sports, Others | 50-100 |
| C（低配额） | Ocean, Space, Abstract, Cartoon | 50-80 |

---

## 5. 生成流程

### 5.1 重新生成 prompt 库（修改 prompt 后必做）

```powershell
& "C:/Home/Develop/venv/Scripts/python.exe" "C:/Home/Projects/jigsawpuzzle/temp/build_v4_library.py"
```

输出 `scripts/my_prompt_library_v4.json`，日志打印每条 fix 的 before→after。

### 5.2 干跑验证（不调 ComfyUI）

```powershell
& "C:/Home/Develop/venv/Scripts/python.exe" -u scripts/my_comfyui_batch_gen_v4.py --workflow scripts/zimage_api_workflow.json --dry-run --dry-run-count 5
```

确认节点探测正确（`[plan] nodes prompt=6 seed=3 size=5 save=9`）且 prompt 读起来合理。

### 5.3 小批量验证

```powershell
& "C:/Home/Develop/venv/Scripts/python.exe" -u scripts/my_comfyui_batch_gen_v4.py --workflow scripts/zimage_api_workflow.json --comfyui-root "F:/ai/ComfyUI/ComfyUI" --out "C:/Home/Temp/JigsawTest" --per-tag 2 --reseed 2 --seed-base 12345678
```

先跑 84 张（21 tag × 2 × 2），看显存、耗时、画质。

### 5.4 全量挂机

```powershell
& "C:/Home/Develop/venv/Scripts/python.exe" -u scripts/my_comfyui_batch_gen_v4.py --workflow scripts/zimage_api_workflow.json --comfyui-root "F:/ai/ComfyUI/ComfyUI" --out "C:/Home/Temp/JigsawV4" --reseed 2 --seed-base 12345678
```

不加 `--per-tag`，按库内 quota 全量跑，预计 ~4560 张。

### 5.5 断点续跑

重跑同一条命令即可，脚本读 `_progress.json` 自动跳过已完成。换 prompt 库后加 `--no-resume`。

---

## 6. 命令行参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--workflow` | — | **必填**，API 格式 JSON |
| `--comfyui-root` | — | **必填**，ComfyUI 安装目录 |
| `--out` | `jigsaw_raw` | 输出根目录 |
| `--tags` | 全部 21 tag | 逗号分隔，限定跑哪些 tag |
| `--per-tag` | 库内 quota | 覆盖每 tag prompt 数（小批量测试用） |
| `--reseed` | 2 | 每 prompt 跑 N 个不同 seed |
| `--seed-base` | `20260830` | 改它可整体重洗所有 prompt |
| `--steps` | 8（库内） | 覆盖采样步数，合法范围 4-20 |
| `--cfg` | 1.0（库内） | 覆盖 CFG，合法范围 1.0-2.0 |
| `--no-resume` | off | 忽略进度重跑 |
| `--dry-run` | off | 只打印 prompt 不调 ComfyUI |
| `--timeout` / `--retries` | 300 / 2 | 单张超时与重试 |
| `--clean-every` | 100 | 每 N 张深度清理显存 |
| `--hard-reset-minutes` | 10 | 每 N 分钟强制卸载模型 |

> **steps/cfg 优先级**：命令行参数 > prompt 库 `generation` 字段 > workflow JSON 默认值。

---

## 7. 图片质检

生成完成后用 `diagnose_images.py` 检测两类问题：

1. **色彩过少**（color poverty）：量化后唯一色数 < 1500
2. **大面积纯色/虚化渐变**：低方差块占比 > 35% + 边缘密度 < 1.5%

### 7.1 基本用法

```powershell
# 扫描目录
& "C:/Home/Develop/venv/Scripts/python.exe" scripts/diagnose_images.py "C:/Home/Temp/JigsawV4" -r

# 带 JSON + HTML 报告
& "C:/Home/Develop/venv/Scripts/python.exe" scripts/diagnose_images.py "C:/Home/Temp/JigsawV4" -r --json "C:/Home/Temp/JigsawV4_diag.json" --html "C:/Home/Temp/JigsawV4_diag.html" -v
```

### 7.2 检测指标

| 指标 | 含义 | 阈值 | 触发 |
|---|---|---|---|
| unique_colors | 量化后唯一色数（quant_levels=16 → 最多 4096） | < 1500 | 色彩过少 |
| top1_ratio | 单色覆盖率 | > 15% | 纯色区 |
| top10_ratio | 前10色覆盖率 | > 50% | 多样性低 |
| low_var_ratio | 32×32 低方差块占比 | > 35% | 虚化/平涂 |
| edge_density | Canny 边缘密度 | < 1.5% | 模糊 |

判定：2+ 项超限 = FAIL，1 项 = WARN，0 项 = PASS。

> **注意**：Z-Image fp8 的固有色彩数集中在 800-1300（量化后），`min_colors=1500` 阈值偏严，WARN 中大量是色彩少但无其他问题的图。真正需关注的是 FAIL（同时有色彩少 + 虚化 + 单色主导）。

### 7.3 可调阈值

```powershell
& "C:/Home/Develop/venv/Scripts/python.exe" scripts/diagnose_images.py "C:/Home/Temp/JigsawV4" -r --min-colors 800 --max-low-var 0.35 --min-edge 0.015
```

---

## 8. 输出结构

```
C:/Home/Temp/JigsawV4/
├── Animals/
│   └── Animals_0000_2070660966_896x1344.png
├── Cities/
├── ...（21 个 tag 目录）
├── _metadata/
│   ├── Animals.jsonl          # 每张图的 prompt / seed / 尺寸 / 时间戳
│   └── Cities.jsonl
└── _progress.json             # 断点续跑进度
```

文件名格式：`<tag>_<序号>_<seed>_<宽>x<高>.png`

---

## 9. v4 修复历程（F1-F12）

| 编号 | 内容 | 效果 |
|---|---|---|
| F1-F2 | 移除 `as the focal subject` 肖像框定 + `behind` → `in the distance` | 减少背景虚化 |
| F3 | `close-up view` → `detailed near view with full depth of field` | 消除最强 bokeh 触发词 |
| F4 | `one clear focal point` → `clear visual hierarchy` | `focal point` 暗示主体隔离→虚化 |
| F7 | `shallow stream/water` → `rocky stream/clear water` | 模型把 `shallow` 读成景深指令 |
| F8 | `soft overcast/ambient` → `even overcast/ambient` | `soft` 暗示柔焦 |
| F9 | OPTICS 条目去重 `wide-angle view` 前缀 | 防止与 viewpoint 重复 |
| F10 | Nature:0000 / Cities:0000 subject 空间改写 | 前景堆叠→场景纵深 |
| F11 | 176/252 subject 边缘定位词自动替换 | `at the left edge` → `at center` 等 |
| F12 | viewpoint 移除 `wide-angle view` + Transportation optics 改为主体突出 | 主体从 ~25% 增大到 ~50-60% |

### 诊断验证历程

| 轮次 | 范围 | 结果 |
|---|---|---|
| diag2 | 3 tag × 8 × 2 = 48 张 | 发现 5 个 prompt 层触发词 |
| diag3-5 | 48 张/轮 | F3-F10 逐步修复，残余虚化定位到 subject |
| diag6（2x16） | 21 tag × 20 = 840 张 | 全量检测：34% FAIL，发现 176 subject 边缘定位问题 |
| diag7 | 21 tag × 2 × 2 = 84 张 | F11 验证：主体不再偏移到边缘 |
| diag8 | 21 tag × 2 × 2 = 84 张 | F12 验证：Transportation 主体从 ~25% 增大到 ~50-60%，虚化块 27%→18% |

---

## 10. 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `steps/cfg 参数不对` | 库 `generation` 字段覆写了命令行 | 确认 `my_prompt_library_v4.json` 的 `generation` 字段为 `steps:8, cfg:1.0` |
| 主体偏小/周围空荡 | viewpoint 随机选中 `wide-angle view` | v4.4 已移除，确认库版本为 4.4 |
| 主体在角落 | subject 含 `at the left edge` 等定位词 | v4.4 已自动替换，运行 `build_v4_library.py` 重新生成 |
| 色彩少但无虚化 | Z-Image fp8 固有特征 | 不是问题，WARN 可接受 |
| prompt 没变化 | 进度文件记录了已完成 | `--no-resume` 或换 `--seed-base` |
| 驱动卡死 | 长跑显存碎片累积 | `--hard-reset-minutes 5`，重启后续跑 |

---

## 11. 挂机前检查清单

- [ ] `build_v4_library.py` 已重新生成 `my_prompt_library_v4.json`
- [ ] `--dry-run` 通过，节点探测正确
- [ ] 小批量 `--per-tag 2 --reseed 2` 跑过，显存和耗时可接受
- [ ] 磁盘剩余 > 40 GB
- [ ] 关闭 Windows 睡眠
- [ ] ComfyUI 启动参数含 `--fast fp8_matrix_mult --fp8_e4m3fn-text-enc`
- [ ] `--comfyui-root` 路径正确
