# v5 素材生成管线审查整合报告（glm 汇编）

> 汇编时间：2026-09-01
> 输入：四份独立审查 + wb 的未完成工作（temp/ 计划与模拟文件 + scripts/ 未提交改动）
> 目的：合并结论、仲裁冲突、盘点已完成/未完成工作，输出唯一一份可执行的优先级清单。

## 0. 输入清单

| 来源 | 文件 | 方法特点 |
|---|---|---|
| glm | `scripts/v5_pipeline_review_glm.md` | 代码/数据静态审查（env 语义错配、死配置、商标风险、脚本工程项） |
| msf | `scripts/v5-audit-msf.md` | 对照 v4 基线（F3-F12）的定量画像：prompt 超长、detail 失效、env 取模 |
| gmp | `scripts/pipeline_review_report.gmp.md` | 工作流视角：分辨率瓶颈、构图模板套路化、磁盘/格式、筛选画廊 |
| wb | `scripts/v5-deep-audit-wb.md`（含 §11 Test2 修正） | 实证驱动：JigsawTest1（140 张）+ Test2（364 张/21 tag）跑 `puzzle_quality_analyzer`，modifier 去混淆归因 Δ_adj |
| wb 遗留 | `temp/plan_final.json`、`temp/plan_a_aggressive.json`、`temp/plan_b_conservative.json`、`temp/build_v5_library.py`、`temp/v5_modifier_sim.py`、`temp/sim_plans.txt`、`temp/sim_b.txt`、`temp/sim_b.err` | modifier 池改动方案（A 激进/B 保守/最终）+ 5 折交叉验证收益评估 + 库重建脚本 |

## 1. 四方结论仲裁（冲突以实证数据为准）

### 1.1 msf "v4 F3-F12 全部回退" → 被 wb 实证推翻

wb Test1/Test2 实测：Laplacian 中位 675（及格线 300），Nature 85 分、空间均衡达标率 90.9%——**去虚化没有破**。真正回退的是 **F11/F12（主体偏小/构图留白）** 与 **style 池选词**。msf §8 的回退对照表不成立，后续不要据此返工。

### 1.2 modifier 归因：Test1 → Test2 符号翻转，以 Test2 为准

样本从 140 → 364 后，14 个 modifier 有 7 个 Δ_adj 翻转（如 `realistic material rendering` +13.0 → -3.5）。wb §11.2 已主动修正。**最终裁决规则**（`temp/plan_final.json`）：只动 n≥24 且 |Δ_adj|≥3.4 的词，提权封顶 ×2（唯一例外 documentary ×3）。理由：样本内乐观值 +6.8，5 折样本外仅 +4.0~+4.6，收益主要来自精准删除而非提权。

**两批一致的稳定结论**（可信度最高）：
- 必删：`...with a clean finish`（-10.1/-5.5）、`fresh bright daylight tones`（-9.0）
- 优质：`documentary style photography`（+7.1，n=32，唯一两批验证的 photo 词）、`candy-bright multicolor palette`（+4.4，n=68）、`dappled sunlight`、`warm interior light`、`dramatic high-contrast lighting`（Test2 +5.6）
- **"clean" 类词汇是拼图素材的毒药**（style 池词条与 quality_suffix 的 "clean uncluttered" 双重独立证据收敛）

### 1.3 reseed：v4 默认 2 被 wb 数据反驳

Test2 182 组同 prompt 双 seed：极差中位 2.0 分、11% 组差 ≥10 分、取最好仅 +2.3 分。**86~89% 的 prompt 换 seed 无意义**，瓶颈在 prompt 质量。→ 算力投 `cards_per_subject`（不同 prompt），`reseed` 默认 1 保持不变。

### 1.4 分辨率：gmp "致命" → wb 取舍表收敛为共识

gmp 判定 1024² 是致命问题；wb §6 量化五种方案后结论：**1024 直出（Z-Image 原生分辨率，伪影最少）+ 人工精选后 2x upscale（单块 102px 进优秀档 70~110px）**。不在废片上浪费 GPU。glm/gmp/wb 三方最终一致。

### 1.5 glm 静态发现与 wb 实证的互相印证

- glm 的"env 语义错配"：wb 实证深化——问题不止取模非随机（msf P0-2），**根源是可组合性**：Pets 的 env 全是桌面级小物件，物理上填不满 1:1 画幅 → 必须换空间级环境（wb 已做），且 msf 的 `rng.sample` 单独不够，还需 subject→env affinity 映射
- glm 的"quality_suffix 否定句反噬"：与 msf P0-4、wb "clean 毒药" 结论收敛，但 **quality_suffix 本身至今未改**（见 §3 未完成）
- glm 的商标/肖像风险清单：msf P0-5 部分重叠（People 肖像、Art 名画），但 LEGO/Harley/Vespa/VW/Ghibli/Pixar/Shinkai 等商标词只有 glm 提出 → 均未处理

## 2. wb 已完成工作盘点（scripts/my_prompt_library_v5.json 未提交 diff）

对照 `temp/plan_final.json` 逐项核对，**plan_final 已 100% 应用**：

| 项 | 内容 | 状态 |
|---|---|---|
| model_hint 修正 | "9 steps, CFG 1.1" → "8 steps, CFG 1.0"（364 条 metadata 之前全错） | ✅ |
| lighting 删 3 词 | `golden hour light` / `crisp bright daylight` / `raking low sunlight` | ✅ |
| atmosphere 删 1 词 | `fresh bright daylight tones`（最差词 -9.0） | ✅ |
| photo style 删 1 词 | `high detail photographic rendering with a clean finish` | ✅ |
| 提权（重复条目实现权重） | dramatic high-contrast ×2、dappled ×2、warm interior ×2、candy-bright ×2、high contrast bold colors ×2、documentary ×3、photorealistic ×2、painterly illust ×2 | ✅ |
| Pets env 整体替换 | 桌面小物件 → 9 个空间级环境（dog park / grooming salon / barn…） | ✅ |
| Pets 模板组 | `animal` → `object`（去掉 "in the distance" 槽位，修复 47.4 分/33% F 率的根因） | ✅ |

同时 `temp/build_v5_library.py` 已同步这些改动（MODIFIER_DROPS/BOOSTS、MODEL_HINT_FIX、Pets env 表、模板组映射），**重建可复现当前 diff**。

## 3. wb 未完成工作盘点（剩余项，按来源归属）

### 3.1 catalog 高危词清洗（msf P0-5 + glm + wb §4.1，全部未动）

当前 JSON 仍包含：
- **肖像权**（People）：`kimono girl walking under cherry blossoms`、`Indian sari dancer`、`Venice carnival costumed nobility`
- **名画 IP**（Art）：`Mona Lisa`、`The Last Supper`
- **拼图灾难词**（Abstract）：`kaleidoscope symmetric pattern`、`Islamic mosaic tile pattern`、`mandala concentric circle totem`、`Mandelbrot and Julia set fractals`
- **死区/bokeh 触发**：`aged parchment background`（Flowers）、`black hole accretion disk`（Space）、`tropical lagoon shallows`（Ocean，`shallow` 是 F7 bokeh 触发词）
- **商标**（仅 glm 提出）：`Studio Ghibli style`、`Pixar 3D style`、`Shinkai-style`（Cartoon）；`LEGO`（Others）；`Harley-Davidson`、`Vespa`、`VW T1`、`F1 racing car`、`Mini Cooper`、`antique Rolls-Royce`（Transportation）
- **写实儿童**（People）：`child building sandcastle on beach`

⚠️ 注意：`build_v5_library.py` 的 CN_TO_EN 同样包含这些词（还有 `Disney 3D style`、`Ford Mustang`、`Lamborghini`、`Ferrari` 等更多商标），**且没有清洗逻辑——直接重跑 build 会把风险词原样带回**。清洗必须落在 catalog md、CN_TO_EN 或 build 后置过滤器三处之一。

### 3.2 quality_suffix 未改（msf P0-3/P0-4 + wb "clean 毒药"）

`plan_final` 只覆盖 modifier 池，quality_suffix 原样：仍 515 char、仍含 `clean uncluttered composition`、仍是 `no ...` 否定式、仍在句尾（Qwen 前部权重高，尾部约束最易被截）。msf 建议拆 `quality_prefix`（前置 ~180 char）+ `quality_tail`，总量 <250 char，干跑均长目标 <650 char（当前 859）。

### 3.3 脚本 `my_comfyui_batch_gen_v5.py` 完全未动

| 问题 | 来源 | 要点 |
|---|---|---|
| `{detail}` 占位符失效 | msf P0-1 | scene/special 6 条模板不含 `{detail}`，~35% 产能丢失纹理描述；一行兜底：`if "{detail}" not in template: prompt_body += ", " + detail` |
| env 取模非随机 | msf P0-2 / wb | `env[i % len]` → 先做 affinity 映射再 `rng.sample`；`rng.sample` 单独不够 |
| progress 每 10 张落盘 | wb §4.3 / glm | driver hang 时丢 9 张进度；改每张落盘（文件 100B 级，开销可忽略） |
| history 错误状态未检查 | glm | `status.status_str=="error"`（OOM/VAE 失败）被误报为 "no image file found (check --comfyui-root)"，排障方向完全错误 |
| 超时重试孤儿文件 | glm/wb | 重试前 `/interrupt` + 检查 `/queue`；relocate 失败只标孤儿清单不 retry |
| relocate/磁盘预检 | wb §4.3 | 启动时写权限测试；`shutil.disk_usage` 预警 |
| `--prune-missing` | wb §4.3 | 人工筛走文件后 resume 能补生成（与 glm 的"磁盘反推 done 集"可合并实现） |
| batch_per_tag 打散 reseed 缓存 | msf P1-1 | reseed>1 时禁用交错排序，保 conditioning cache |
| shift 固定 3.0 | msf/wb | 暴露 `--shift`，按 max(w,h) 动态（1024→3.0 / 1344→3.5） |
| inject 静默失败 | msf P1-2 | RandomNoise+SamplerCustom 工作流下 steps/cfg 注入无告警 |
| usage 示例旧文件名 / --rounds 与 --cards-per-subject 重复 | glm | 顺手清理 |

### 3.4 工作流 `zimage_api_workflow_v5.json` 未动

- `EmptySD3LatentImage` 仍写死 **896×1344**，与 `active_ratios:["1:1"]→1024` 失配（msf P0 #5：首次手工验证易误判）
- 无 upscale 环节——按 §1.4 共识**不需要加在生成工作流里**，精选后单独跑 2x（新脚本 `upscale_for_packaging.py`，读 keep.txt + sidecar）

### 3.5 build 脚本与 JSON 的漂移

`temp/build_v5_library.py` 的 CN_TO_EN 已扩充（Nature 多肉系列、Landscapes Yosemite、Sports 完整动作短语如 `volley shot`/`tomahawk dunk`、Food/Others 增补），**当前 JSON 是旧版构建产物**。重跑 build 会带来：
- 正面：Sports subject 从裸名词（"soccer"）变为完整动作短语——顺带修复 glm 提出的 "a single soccer" 语法崩坏
- 负面：风险词回归（§3.1），必须先加清洗再重建

另有 `temp/v5_modifier_sim.py` 的 `KeyError: 'style/photo'`（sim_b.err，`show()` 里 pool 索引 bug）；sim_b.txt 显示后续已跑通，err 文件疑似陈旧，收尾时可清理。

### 3.6 筛选工作台（wb §7 / gmp §3，未开始）

`机检打分 → sidecar .qa.json → HTML 画廊（复用 packaging/index.html，grade 染色+按分排序）→ 键盘流 keep/skip → keep.txt → 2x upscale → manifest 打包`。wb 实证提醒：**质检测不出"提示词是否被遵守"**（Animals_0002 89 分但 env 未体现），机检只能前置 30~40% 硬淘汰，不能替代人工终筛。

## 4. 合并后的最终优先级清单

### P0（全量挂机前必须完成）

| # | 改动 | 位置 | 状态 |
|---|---|---|---|
| 1 | modifier 池 drop/boost + Pets env/模板组 + model_hint | my_prompt_library_v5.json | ✅ 已完成（未提交） |
| 2 | catalog 高危词清洗（肖像/名画/重复歧义/死区/商标/写实儿童） | JSON + build_v5_library.py（需同步加清洗逻辑） | ⬜ |
| 3 | quality_suffix 压缩拆分 + 去 "clean" + 否定句改正面 + 前置 | JSON + build | ⬜ |
| 4 | `{detail}` 兜底 + env 改 affinity 映射 + rng.sample | my_comfyui_batch_gen_v5.py | ⬜ |
| 5 | workflow 默认 1024×1024 + 暴露 --shift | zimage_api_workflow_v5.json + 脚本 | ⬜ |
| 6 | progress 每张落盘 + history status 检查 | 脚本 | ⬜ |

### P1（下一批）

- 组装序调整（quality 前置）+ prompt >700 char 告警
- reseed>1 禁用交错排序；重试前 /interrupt + 孤儿清单
- Pets/Flowers 补 optics；Flowers/Food/Others 加 `viewpoint_deny: flat lay`（wb 数据：flat lay +3.5 但仅限无生命物体 tag）
- 跨 tag subject 去重（glm：green iguana / 鲸类 / coastal cliffs / 灯塔 / 龙舟等）+ `--check-duplicates` 自检
- 筛选工作台四件套（sidecar/画廊染色/快捷键/keep.txt）
- 精选后 2x upscale 脚本（`upscale_for_packaging.py`，目标 2048）

### P2（长期）

- 比例按 tag 差异化（Landscapes/Cities 3:2、People 2:3，配合 cropLoss<15%）
- 沉淀淘汰 prompt 特征回库，env/subject 亲和表按 PASS/S/A 优胜劣汰
- 构图模板多样化（gmp：对角线/微距满幅/框架式——注意微距与 F3 bokeh 触发词的冲突需措辞规避）
- reseed batch_size 化提速（glm，30~40% 时间）

## 5. 挂机前最小验证（整合版）

```powershell
# 1) 干跑：确认 0 命中风险词 / 拖分词，prompt 长度回落
& "C:/Home/Develop/venv/Scripts/python.exe" -u scripts/my_comfyui_batch_gen_v5.py `
  --workflow scripts/zimage_api_workflow_v5.json `
  --dry-run --dry-run-count 100 2>&1 `
  | Select-String -Pattern 'clean finish|fresh bright daylight|golden hour|Mona Lisa|kaleidoscope|mandala|parchment|accretion disk|Ghibli|LEGO|a single soccer'

# 2) 小批 168 张（21 tag × 8 subject）
& "C:/Home/Develop/venv/Scripts/python.exe" -u scripts/my_comfyui_batch_gen_v5.py `
  --workflow scripts/zimage_api_workflow_v5.json `
  --comfyui-root "F:/ai/ComfyUI/ComfyUI" `
  --out "C:/Home/Temp/JigsawV5_fix2" `
  --per-tag 8 --seed-base 87654321

# 3) 机检对比 Test2 基线（69.6 分 / S+A 66.2% / F 5.2%）
& "C:/Home/Develop/venv/Scripts/python.exe" -u temp/jigsaw_qa_report.py "C:/Home/Temp/JigsawV5_fix2"
# 预期：总均分 ≥73，Pets ≥60，色相熵达标率 ≥70%，F ≤3%
# 注意：当前未提交改动只含 modifier 池+Pets，色相熵短板（59.9% 达标）主要靠
# P0 #3（quality_suffix）和 #2（死区词）才能达标，小批验证建议在 #2~#6 完成后做
```

## 6. 结论

四份审查高度互补且大体收敛：msf 提供结构化问题清单（其中"F3-F12 回退"被实证推翻）、gmp 补工作流与筛选体验、glm 补法律风险与脚本工程、wb 用 364 张实测数据把"该删哪个词"变成可执行决策。wb 的 P0 第一步（modifier 池 + Pets 根因修复）已落地为未提交 diff，预期 honest gain +4.0~+4.6 分；剩余 P0 集中在 catalog 清洗、quality_suffix、脚本四个函数级修复和工作流默认值，完成后按 §5 验证再全量挂机。
