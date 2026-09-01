# v5 素材管线修复与改进计划

> 依据：`scripts/v5-review-integrated_glm.md`（四份审查整合结论）
> 制定：2026-09-01 | 状态：**阶段 0/1/2/3/4 已完成（2026-09-01 20:53，见 docs/CHANGES-20260901.md）**，待执行阶段 5 小批验证
> 原则：每阶段独立可验证；先小批实测再全量挂机；不自发 commit。
>
> 执行备注：
> - D1/D2 均按推荐执行（JSON 原位编辑 + Animals 只做气候分组）
> - 偏离计划一处：dragon boat 保留 Holidays 的端午场景（内容更丰富），删 Transportation 的裸船体词条
> - dry-run 实测：最长 prompt 931→765 char；87/1207 超 700 char（告警已打印，属长 optics+style 组合，可接受）

## 前置决策（需确认）

**D1：JSON 直接改 vs 重跑 build 脚本**

- 现状：`my_prompt_library_v5.json` 的未提交改动（modifier 池 + Pets）已与 `temp/build_v5_library.py` 同步；但 build 的 CN\_TO\_EN 还有一批**未进 JSON** 的扩充（Sports 动作短语、Nature 多肉、Food/Others 增补），以及更多商标词（Disney/Ferrari/Lamborghini 等）。

- **推荐：JSON 原位编辑**（改动可控、可 diff），同时在 build 脚本加清洗表，保证未来重建不回归。不建议现在重跑 build——会把未实测的扩充一股脑带进来，混入变量。

- 备选：重跑 build（如果想顺便吃下 Sports 短语修复），但必须先完成阶段 1 的清洗表并接受"一次引入两组变量"。

**D2：Animals affinity 映射范围**

- 1211 个 subject 全建亲和表工作量太大。**推荐：只给 Animals 建气候分组**（错配重灾区：北极熊配火山），其余 tag 依赖"env 本身是中性空间级环境"（Pets 已换）+ `rng.sample` 随机。后续按淘汰数据再补（P2 反馈环）。

## 阶段 0：tag 分层与生成配额（新增，依据 mostplayed 统计）

> 数据依据：`docs/mostplayed-puzzle-stats-and-selection-guide.md`（168 张热门榜）
> 结论：21 tag 不删（游戏关卡多样性需要），但生成配额按市场需求分层；
> 市场实证的 8 类需求 vs 21 tag 存在双向错配——7 个 tag（Sports/Space/Fantasy/
> Transportation/Birds/Ocean/Art，约 350 subject）零市场证据；手工艺平铺
> （10.1% 需求）只有 5 个词条。

### 0.1 配额分层（生成命令用 --tags 控制，不改库结构）

| 层 | 配额       | Tag                                                            | 依据                                                 |
| - | -------- | -------------------------------------------------------------- | -------------------------------------------------- |
| A | \~70%    | Nature, Landscapes, Architecture, Food, Others, Abstract       | 市场需求实证（前 6 大类）+ wb 实测高分                            |
| B | \~25%    | Flowers, Animals, Pets, Ocean, Seasons, Holidays, Art, Cartoon | 中等需求 / 游戏多样性                                       |
| C | \~5% 或按需 | Cities, Transportation, People, Sports, Space, Fantasy, Birds  | 零市场证据；Cities/Transportation 与"避免现代都市/汽车"冲突；关卡需要时再补 |

### 0.2 数据修正（并入阶段 1 的 JSON 编辑）

1. **Others 扩充彩色平铺 subject**（+20\~30 条）：毛线团阵列、玻璃弹珠、彩色纽扣、糖果罐阵列、彩铅笔、缝纫线轴、珠串、彩粉、马卡龙色布料 sample 等——对应市场 10.1% 手工艺纺织 + 19.6% 多彩平铺需求；这些 object 类 tag 保持 flat lay 允许（wb 实测 +3.5，市场数据 \~40% 覆盖率）
2. **Abstract 风格池拆分**：彩色阵列类 subject（terrazzo/glass marbles/buttons 类若保留）用 photo 池；纯纹理/流体类维持 illust
3. Cities/Transportation 保留但不进 A/B 层（市场避免清单：现代都市/汽车/冷峻建筑）

## 阶段 1：catalog 高危词清洗（P0）

**文件**：`scripts/my_prompt_library_v5.json` + `temp/build_v5_library.py`

### 1.1 删除/替换清单（JSON 原位）

| 类别                  | 词条 → 处理                                                                                                                                                                                                                                                                                                                                                                                                             |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 肖像权 (People)        | `kimono girl walking under cherry blossoms` → `kimono festival procession on busy Japanese street`；`Indian sari dancer` → `colorful Indian wedding celebration crowd`；`Venice carnival costumed nobility` → `Venice carnival masked crowd scene`                                                                                                                                                                    |
| 写实儿童 (People)       | `child building sandcastle on beach` → `family building sandcastle on beach`                                                                                                                                                                                                                                                                                                                                        |
| 名画 IP (Art)         | `Mona Lisa`、`The Last Supper` → 删（同 tag 备选充足）                                                                                                                                                                                                                                                                                                                                                                       |
| 拼图灾难 (Abstract)     | `kaleidoscope symmetric pattern`、`mandala concentric circle totem`、`Mandelbrot and Julia set fractals`、`Islamic mosaic tile pattern` → 删；`mystical symbol decorative mandala`、`alchemy symbol magic circle` → 评估后删或改 `asymmetrical` 变体                                                                                                                                                                              |
| 死区/bokeh            | `aged parchment background` (Flowers) → 删；`black hole accretion disk...` (Space) → 删；`tropical lagoon shallows` (Ocean) → `turquoise lagoon with coral heads`                                                                                                                                                                                                                                                       |
| 商标 (Cartoon)        | `Studio Ghibli style landscape` → `hand-drawn anime film landscape with vivid cumulus skies`；`Pixar 3D style` → `stylized 3D animated film look`；`Shinkai-style windmill...` → `vivid anime film style windmill railway crossing...`                                                                                                                                                                                |
| 商标 (Transportation) | `Harley-Davidson motorcycle` → `classic American cruiser motorcycle`；`Vespa scooter` → `vintage Italian scooter`；`VW T1 camper van` → `retro camper van`；`VW Beetle` → `vintage compact car`；`F1 racing car` / `F1 car cornering` → `open-wheel race car`；`Mini Cooper` → `classic British compact car`；`antique Rolls-Royce` → `antique luxury limousine`                                                          |
| 商标 (Others)         | `LEGO medieval castle with minifigures` → `colorful interlocking brick castle with tiny figures`                                                                                                                                                                                                                                                                                                                    |
| 跨 tag 重复            | `green iguana`（Pets 删，Animals 留）；`humpback whale`/`blue whale`/`manatee`/`dolphin`（Animals 删，Ocean 留）；`coastal cliffs`（Ocean 删，Landscapes 留）；`coastal lighthouse`（Landscapes 删，Architecture 留）；`covered bridge`（Landscapes 删，Architecture 留）；`dragon boat`（Holidays 删，Transportation 留）；`open field hot air balloons`/`Cappadocia hot air balloon group` 各留其一；`Dutch windmill fields`/`Dutch windmill village` 各留其一 |

### 1.2 build 脚本同步清洗

- `build_v5_library.py` 增加 `SUBJECT_REWRITES`（替换表）+ `SUBJECT_BLOCKLIST`（删除表），在 translate 后应用；

- 覆盖 CN\_TO\_EN 里的额外商标：`Disney 3D style`、`Ford Mustang`、`Lamborghini`、`Ferrari`、`Land Rover`、`Cadillac`、`Chevrolet Corvette`、`Glacier Express` 等 → 泛化或删；

- 构建末尾加断言：输出 JSON 中 grep 关键词（LEGO|Ghibli|Pixar|Mona Lisa|kaleidoscope|mandala|Mandelbrot|parchment|accretion|Harley|Vespa|F1 ...）必须 0 命中，否则 exit 1。

**验收**：`--dry-run --dry-run-count 100` 输出 0 命中风险词；`git diff` 逐条对应清单。

## 阶段 2：quality\_suffix 重写（P0）

**文件**：JSON + 脚本 `build_jobs`（组装逻辑）

1. 拆分为 `quality_prefix`（\~180 char，组装时**前置**在 subject 之后）+ `quality_tail`（精简，留尾部）：

   - prefix：`full-bleed corner-to-corner dense detail, deep depth of field with consistent sharpness, busy composition with clear visual hierarchy, varied shape color and scale between regions`

   - tail：`textured sky with cloud detail, rich micro texture variation, full-bleed artwork`
2. 删除全部 `no ...` 否定式与 `clean uncluttered composition`（"clean" 双重实证毒药）；
3. per-tag 覆写支持：`"quality_suffix_override"` 字段——Ocean 去 sky/water 约束（海洋本身是主体）、Art 单色媒介（charcoal/engraving）改 `rich tonal range`；
4. 脚本组装序调整：`subject → quality_prefix → lighting → viewpoint → optics → style → atmosphere → quality_tail`。

**验收**：dry-run 均长 <650 char（当前 859）；无 `no large/no excessive/no repetitive` 字样。

## 阶段 3：脚本修复（P0）

**文件**：`scripts/my_comfyui_batch_gen_v5.py`（全部为函数级小改）

| #   | 改动                | 位置                   | 说明                                                                                                                              |
| --- | ----------------- | -------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| 3.1 | `{detail}` 兜底     | `build_jobs`         | `if "{detail}" not in template: prompt_body += ", " + detail`                                                                   |
| 3.2 | env 随机 + affinity | `build_jobs`         | `rng.sample(cat_env, k=3)` 替换取模；Animals 加 `env_groups`（arctic/savanna/forest/ocean/desert）+ subject 可选 `env_group` 字段，命中则在子集内采样 |
| 3.3 | progress 每张落盘     | 主循环                  | `save_progress` 改为每张成功/失败后调用（100B 文件，开销可忽略）                                                                                     |
| 3.4 | history 错误检查      | `wait_for_image`/主循环 | `history["status"]["status_str"]=="error"` 时提取 node error 信息抛出真实错误，不再误报 "check --comfyui-root"                                  |
| 3.5 | reseed 保缓存        | `build_jobs` 排序      | `reseed>1` 时跳过 batch\_per\_tag 交错                                                                                               |
| 3.6 | 重试前 interrupt     | 重试分支                 | 先 `POST /interrupt` + 探测 `/queue`，避免重复排队与孤儿文件                                                                                   |
| 3.7 | `--shift` 注入      | `inject_workflow`    | 探测 `ModelSamplingAuraFlow` 节点，按 `max(w,h)` 默认 1024→3.0 / 1344→3.5，可 CLI 覆盖                                                      |
| 3.8 | prompt 长度告警       | `build_jobs` 后       | >700 char 打印 warning                                                                                                            |
| 3.9 | 顺手清理              | 文件头                  | usage 示例文件名改 `my_comfyui_batch_gen_v5.py`                                                                                       |

**验收**：`--dry-run` 正常；`--list-tags` 不变；手动构造 error history 单测（可用临时脚本 mock）。

## 阶段 4：工作流默认值（P0）

**文件**：`scripts/zimage_api_workflow_v5.json`

- `EmptySD3LatentImage` 896×1344 → **1024×1024**（与 `active_ratios:["1:1"]` 一致，脚本会覆盖但默认值不再误导手工验证）。

- 不加 upscale 节点（共识：1024 直出，精选后单独放大）。

## 阶段 5：小批验证 → 全量挂机（P0 出口门槛）

```powershell
# 1) 干跑风险词 + 长度
# 2) 168 张（21 tag × 8 subject）--per-tag 8 --seed-base 87654321
# 3) temp/jigsaw_qa_report.py 机检，对比 Test2 基线 69.6 / S+A 66.2% / F 5.2%
```

**达标线**：总均分 ≥73、Pets ≥60、色相熵达标率 ≥70%、F ≤3% → 全量；未达标 → 回归分析（优先查 quality\_suffix 与清洗是否生效）再决定。

**全量挂机按阶段 0 分层跑**（A 层先跑满，B 层跟进，C 层按游戏关卡需要单独触发）：

```powershell
# A 层（~70% 配额）
... --tags Nature,Landscapes,Architecture,Food,Others,Abstract --cards-per-subject 2
# B 层（~25%）
... --tags Flowers,Animals,Pets,Ocean,Seasons,Holidays,Art,Cartoon --cards-per-subject 1
# C 层：按需，例如游戏关卡缺 Space 素材时
... --tags Space --cards-per-subject 1
```

## 阶段 6：P1（全量跑完、人工筛选阶段配套）

| 项                          | 说明                                                                                                                                    |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| optics 补齐                  | Pets/Flowers 补 `small aperture f/8, deep focus`；Flowers/Food/Others 加 `viewpoint_deny: flat lay overhead view`（flat lay +3.5 仅限无生命物体） |
| `--check-duplicates`       | 跨 tag subject 重复自检（阶段 1 手动去重后的防回归）                                                                                                    |
| 筛选工作台                      | `puzzle_quality_analyzer.py` 加 `--sidecar`；packaging/index.html 加 grade 染色 + 按分排序 + K/Space 快捷键 → keep.txt                            |
| `upscale_for_packaging.py` | 读 keep.txt，对 ≥B 级图 2x 放大到 2048（单块 102px 优秀档）                                                                                          |
| `--prune-missing`          | resume 时扫磁盘反推 done 集 + 人工筛走后补生成                                                                                                       |
| 磁盘预检                       | 启动时 `shutil.disk_usage` 不足预警                                                                                                          |
| 死配置清理                      | `avoid`/`active_ratios`/`generation.sampler` 要么消费要么删                                                                                  |

## 阶段 7：P2（长期，按数据驱动）

- 比例按 tag 差异化（Landscapes/Cities 3:2、People 2:3；需先确认游戏内置关卡比例需求）

- 构图模板多样化（对角线/框架式/微距满幅——微距措辞需规避 F3 bokeh 触发词）

- env/subject 亲和表按 PASS/S/A 率优胜劣汰（反馈环）

- reseed batch\_size 化（同 prompt N seed 一次推理，预估省 30-40% 时间）

## 执行顺序与变更记录

- 阶段 1→2→3→4 依次做（1、2 改数据，3、4 改代码，互不阻塞但 dry-run 验证依赖全部完成）；

- 每阶段完成后跑对应验收；全部 P0 完成后按阶段 5 小批实测；

- 关键代码变更（阶段 3）与数据变更（阶段 1/2）摘要记入 `docs/CHANGES-20260901.md` 顶部；

- commit 时机由你决定——建议阶段 1-4 完成并 dry-run 通过后提交一次（当前 wb 的未提交 modifier 池改动可并入或先单独提交）。

