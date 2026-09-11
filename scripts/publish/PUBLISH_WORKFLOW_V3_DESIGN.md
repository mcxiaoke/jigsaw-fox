# jigsaw-data 素材发布工作流体系改进方案 (v3 设计定稿)

> 日期：2026-09-11  
> 状态：**设计定稿待实施**  
> 责任目录：`scripts/publish/`  
> 关联工具：[`studio/verify_data.py`](../../studio/verify_data.py)、[`scripts/publish/publish.py`](publish.py)、[`scripts/publish/ledger.py`](ledger.py)  
> 前序方案：[`docs/assets-publish-workflow-v2-20260910.md`](../../docs/assets-publish-workflow-v2-20260910.md)

---

## 1. 背景与核心问题定位

在 v2 方案的实际运行与推演中，暴露出三个关乎数据安全与发布可靠性的结构性隐患：

### 1.1 问题一：测试时序倒置，脏数据全量污染远端（先推后测）
- **现象**：当前 `publish.py all` 的执行链为：
  $$\text{prepare} \longrightarrow \mathbf{stage} \longrightarrow \text{verify(stage)} \longrightarrow \mathbf{release} \longrightarrow \mathbf{promote} \longrightarrow \text{verify(prod)}$$
- **隐患**：
  1. `prepare` 仅做了基础文件数与版本号递增判断，**未进行任何实质性数据体检**；
  2. 随后立即执行 `stage`，将 124MB+ 的全部数据（数百张图片、JSON、ZIP）**全量上传至云端 R2 的 `_stage/` 预演区**；
  3. 接着在 `release` 步骤中，将所有新增 ZIP 上传至 GitHub / Gitee Release 附件库；
  4. 甚至直到 `promote` 将数据全量推上生产环境 `release/` 后，才在生产环境跑 `verify(prod)`；
  5. 客户端真实数据模型解析测试（`flutter test`）甚至被排在最末尾，且只能走线上网络。
- **后果**：一旦 Studio 导出的数据存在坏图、损坏 ZIP、关卡配置缺漏或客户端反序列化异常：
  - 云端预演区直接被冲刷为脏数据；
  - Gitee / GitHub Release 产生无法轻易撤销的脏附件（Gitee 有 1GB 总额度硬限制且无便捷批量删除接口）；
  - 若意外带病生效生产，线上真实 App 将遭遇大面积关卡打不开或解析崩溃闪退；
  - 开发者白白耗费网络带宽与等待时间（传完上百兆数据才报错）。

### 1.2 问题二：各子命令缺乏状态机约束，乱序与越级执行无防护
- **现象**：子命令（`stage` / `release` / `promote` 等）内部仅做了参数与本地路径存在的浅校验，**完全不感知流水线前置执行状态**。
- **隐患**：
  - **越级 `promote` 致命事故**：若开发者在未执行 `prepare` / `stage` / `verify` 的情况下，直接运行 `python publish.py promote`，脚本仅根据 `rclone copy r2:_stage r2:release` 执行。如果云端 `_stage` 残留着历史半成品或脏数据，**将秒级同步覆盖到正式生产环境，造成生产瘫痪**；
  - **直接 `stage` 污染**：跳过 `prepare` 直接运行 `stage`，若本地 `publishRoot` 残留着旧数据，会直接把陈旧数据当最新包推上云端；
  - **直接 `release` 泄露**：未在本地或预演区完成验证，直接将 ZIP 包打入 Release 附件。

### 1.3 问题三：本地已有现成深度体检工具，但发布链未打通
- **现象**：`studio/verify_data.py` 已经具备极其完善的 7 大维度离线体检（引用文件、字段完整性、内容 Hash、字节大小、ZIP CRC32 与解压条目数、Manifest 自洽性、Taxonomy 标签白名单）。
- **现状**：发布侧的 `prepare` 没有复用该工具，也没有在推送前建立断网可跑的本地闭环门禁。

---

## 2. 核心架构设计原则

| # | 原则 | 规范说明 |
|---|---|---|
| **1** | **本地测试先行<br>(Local Gates First)** | **“本地全绿方可触网，预演全绿方可晋产”**。<br>向任何远端（R2 `_stage`、Release 附件、Git remote）发送任何一个字节之前，必须在本地离线环境下 100% 通过全部数据与客户端契约体检。 |
| **2** | **发布状态机强约束<br>(Pipeline State Machine)** | 为每次发布分配全局唯一 `runId`，并在 `.publish/run.json` 维护单调严格递增的发布状态。<br>所有子命令强制核验前置状态，**彻底杜绝跨阶段、越级执行**。 |
| **3** | **分层解耦与阶梯防御<br>(Layered Defense)** | - **Layer 1 本地门禁**：物理与静态完整性（`studio.verify_data`）+ 本地客户端模型解析契约；<br>- **Layer 2 预演网络门禁**：验证云端 R2 通路、CDN 缓存穿透、TLS 与状态码；<br>- **Layer 3 备源发布门禁**：Release 附件就位；<br>- **Layer 4 生产生效门禁**：秒级同步与生产巡检。 |
| **4** | **严格全链路幂等<br>(Strict Idempotency)** | 明确定义所有命令在重复执行、网络中断重试时的幂等行为与退出契约，避免重复发布造成版本回退或台账损坏。 |

---

## 3. 全新标准发布流水线架构 (v3)

```text
[Output (Studio 导出产物，只读)]
      │
      ▼ ─────────────────────────────────────────────────────────────
[Step 1] prepare  (本地构建与改写)
      │  • 白名单拷贝（排除 .git / 隐藏文件）
      │  • 注入 zipUrls（Gitee/GitHub 绝对地址）与 zipKey
      │  • 重算各模块 Hash 并回写 manifest.json
      │  • 初始化 run.json，状态设为 PREPARED
      ▼ ─────────────────────────────────────────────────────────────
[Step 2] check-local  (【核心前置本地门禁】—— 纯离线，0 网络，0 远端污染)
      │  • Gate A (静态体检 - studio.verify_data)：
      │    - 文件存在性：关卡图片、封面图、ZIP 包全部存在且非空
      │    - 字段完整性：各 index.json 必需字段 100% 具备
      │    - 内容一致性：sha256 与 fileSizeBytes 严格核对
      │    - ZIP 完整性：zipfile.testzip() CRC32 坏块校验 + 条目数等于 totalCount
      │    - Manifest 自洽性：各模块 index.json sha256 等于 manifest.modules.<m>.hash
      │    - 标签合规性：main 关卡 tags 位于 taxonomy.json 主标签白名单
      │  • Gate B (客户端模型反序列化 - Dart 本地契约测试)：
      │    - App 真实数据模型（RootManifest / PuzzleLevelItem / PuzzleEventItem /
      │      PuzzleCollectionItem）直接反序列化消费本地发布产物，断言 0 异常
      │  • 状态推进：LOCAL_VERIFIED（❌ 任何一项不通过，立刻终止，远端绝对干净）
      ▼ ─────────────────────────────────────────────────────────────
[Step 3] stage  (预演区同步)
      │  • 门禁前置：必须处于 LOCAL_VERIFIED 状态
      │  • rclone sync 本地 publishRoot -> r2:jigsaw-data/_stage
      │  • 状态推进：STAGED
      ▼ ─────────────────────────────────────────────────────────────
[Step 4] verify --env stage  (预演区网络巡检)
      │  • 门禁前置：必须处于 STAGED 状态
      │  • 巡检 https://jigsawdata.umao.top/_stage/ 下的 JSON / 图片 / ZIP 可达性
      │  • 状态推进：STAGE_VERIFIED
      ▼ ─────────────────────────────────────────────────────────────
[Step 5] release  (备源 Release 附件先行就位)
      │  • 门禁前置：必须处于 STAGE_VERIFIED 状态
      │  • 增量上传新增 zip 到 GitHub 和 Gitee Release 附件
      │  • 状态推进：RELEASED
      ▼ ─────────────────────────────────────────────────────────────
[Step 6] promote  (正式生产生效与巡检)
      │  • 门禁前置：必须处于 RELEASED 状态（严禁越级直接 promote！）
      │  • R2 桶内秒级 Server-Side Copy: _stage -> release
      │  • 自动触发 verify --env prod
      │  • 状态推进：PROMOTED，台账归档为 latest.json
      ▼ ─────────────────────────────────────────────────────────────
[Step 7] git  (Git 备份留底)
      │  • 门禁前置：必须处于 PROMOTED 状态
      │  • 提交并推送 jigsaw-data 的 JSON/WebP 到 origin 与 gitee master 分支
      │  • 状态推进：FINISHED
```

---

## 4. 状态机与顺序防护规范 (State Machine Specification)

### 4.1 状态枚举与单调流转

台账 `jigsaw-data/.publish/run.json` 中维护核心状态字段 `state`：

```text
INIT
  │
  ▼ prepare
PREPARED
  │
  ▼ check-local
LOCAL_VERIFIED
  │
  ▼ stage
STAGED
  │
  ▼ verify(stage)
STAGE_VERIFIED
  │
  ▼ release
RELEASED
  │
  ▼ promote (含 verify prod)
PROMOTED
  │
  ▼ git
FINISHED
```

### 4.2 前置状态断言矩阵

每个子命令在执行实际动作之前，必须调用统一门禁函数 `assert_pipeline_state(doc, required_state)` 进行核验：

| 子命令 | 要求前置状态 | 执行成功后新状态 | 状态不满足时的拦截提示示例 |
|---|---|---|---|
| **`prepare`** | 任意（初始化或重置） | `PREPARED` | — |
| **`check-local`** | `PREPARED` 或更早通过项 | `LOCAL_VERIFIED` | `[FATAL] 请先运行 prepare 生成发布产物` |
| **`stage`** | `LOCAL_VERIFIED` | `STAGED` | `[FATAL] 本地测试未通过（当前状态: PREPARED），禁止向云端传输数据！请先运行 check-local` |
| **`verify (stage)`** | `STAGED` | `STAGE_VERIFIED` | `[FATAL] 预演区尚未同步数据（当前状态: LOCAL_VERIFIED），请先运行 stage` |
| **`release`** | `STAGE_VERIFIED` | `RELEASED` | `[FATAL] 预演区尚未巡检通过（当前状态: STAGED），严禁向 Release 附件推送未经测试的 ZIP！` |
| **`promote`** | `RELEASED` | `PROMOTED` | `[FATAL] 越级操作被阻断！当前发布未完成备源上传与预演验证（当前状态: None / STAGED）。严禁直接 promote 脏数据到生产！` |
| **`git`** | `PROMOTED` | `FINISHED` | `[FATAL] 生产发布尚未成功完成，禁止推送 Git 备份` |

### 4.3 异常中断、防死锁与全场景恢复机制 (Error Recovery & Anti-Deadlock)

状态机的设计必须服务于安全，**绝不能变成卡死正常开发流程的枷锁**。针对可能出现的各种中断与错误，体系提供以下 4 级清晰、无缝的自愈与恢复机制：

```text
               ┌──────────────── 任意步骤失败 / 数据有错 ───────────────┐
               │                                                          ▼
               │                                                [Studio 修改重导]
               │                                                          │
               ▼                                                          ▼
[失败步骤] ──原地重试──► [原前置状态合法，断点续跑]               [直接运行 prepare]
               ▲                                                          │
               │                                                          ▼
               └───────────────── 彻底放弃 / 清理环境 ◄──── [无条件开启全新 runId，重置状态]
                                       │
                                       ▼
                             [运行 publish.py reset]
```

#### 恢复场景 A：数据本身有问题，需要在 Studio 修改后重新发布（最常见场景）
- **现象**：在 `check-local` 发现图片损坏、关卡少 tags、或者客户端模型解析崩溃；或者甚至在 `stage` 后发现关卡内容不对。
- **解法**：**`prepare` 永远是无条件的「全新生命周期重置入口（Safe Reset Entry）」**。
  - **核心机制**：`prepare` 对前置状态的要求为 `ANY`。无论当前处于 `PREPARED`、`LOCAL_VERIFIED`、`STAGED`、还是中间报错状态，**只要用户重新运行 `prepare`，流水线立即认定为发起一次全新的发布迭代**；
  - **执行动作**：
    1. 立即作废旧的未完成会话，生成一个全新的全局唯一 `runId`（如 `20260911-124500`）；
    2. 状态强行重置回归至 `PREPARED`；
    3. 清空本地 `publishRoot`，重新从 Studio 的 `Output` 白名单拷贝、重新注入 `zipUrls`、重算哈希；
  - **关键防坑：版本基线防污染（Version Baseline Guard）**：
    `prepare` 在读取上一版 `main.version` 基线时，**绝对不读被废弃的本地半成品**，而是严格从**上一次真正成功发布归档的 `latest.json`**（或云端生产区）读取。
    即使刚才失败的半成品把版本改到了 5，重新 `prepare` 依然能准确识别线上基线为 4，判定新版本 5 依然严格递增，**绝不会发生“被自己刚才失败的半成品误判为版本相同或回退”的锁死现象**！

#### 恢复场景 B：纯外部偶发故障（网络闪断 / API 超时），需要原地重试
- **现象**：数据本身没有问题，但在 `stage`（rclone 上传网络超时）、`release`（GitHub/Gitee API 502/超时）等步骤意外中断。
- **解法**：**原地直接重跑刚才失败的子命令（In-place Retry / Resume）**。
  - **状态机保障**：当某个子命令失败抛错退出时，`run.json` 中的 `state` **保持在上一通过状态不变**（例如 `stage` 失败，状态依然停留在 `LOCAL_VERIFIED`）；
  - **重试动作**：开发者网络恢复后，直接在控制台敲刚才失败的命令（如 `python publish.py stage` 或 `python publish.py release`）；
  - **幂等自愈**：
    - `stage` 再次启动，其前置状态依然满足 `LOCAL_VERIFIED`；`rclone --checksum` 自动断点续传已传完的文件，只补齐未完成的部分；
    - `release` 再次启动，其前置状态依然满足 `STAGE_VERIFIED`；已有附件自动跳过，仅补传缺失 zip；
    - 执行成功后，状态顺畅推进到下一阶段，继续后续流程。

#### 恢复场景 C：彻底放弃本次发布 / 清理现场
- **现象**：发布推到一半突然决定今天不发了，或者环境被改乱，想彻底复位。
- **解法**：运行专属重置命令：
  ```bash
  python scripts/publish/publish.py reset
  ```
  - **动作**：
    1. 安全删除正在进行中的 `.publish/run.json`；
    2. 将流水线状态完全复位至 `INIT`；
    3. 清理本地未提交的临时发布产物（保留历史基线 `latest.json` 不受影响）。

#### 恢复场景 D：紧急运维逃生通道（Escape Hatch）
- **现象**：线上突发重大事故需紧急热修复或回滚，不想被本地全量测试或前置状态流转耗费时间。
- **解法**：所有子命令均支持 `--force` 参数：
  ```bash
  python scripts/publish/publish.py promote --force
  ```
  - **行为**：跳过前置状态断言，控制台打印高亮警告日志 `[warn] 触发 --force 逃生通道，强制绕过前置状态校验！` 并继续执行。确保极端情况下开发者拥有绝对掌控权。

---

## 5. 各命令幂等性规格说明书

| 命令 | 幂等分类 | 重复运行行为 | 幂等保证机制与异常防范 |
|---|:---:|---|---|
| **`prepare`** | **有条件幂等** | 连续重复运行第 2 次：<br>1. 若数据未改动：命中台账「无变化检测」，直接退出码 3 终止流水线；<br>2. 若显式加 `--force`：按原输入重新生成，输出内容恒定。 | **防基线漂移**：`prev_version` 必须在清空 `publishRoot` 前先从历史归档 `latest.json` 或云端生产区读取，严禁将刚刚生成的未发布产物作为自身的递增基线。 |
| **`check-local`** | **严格幂等** | 任意重复运行，纯只读计算，控制台打印体检报告。 | 0 状态修改，0 磁盘写入，0 网络开销。 |
| **`stage`** | **严格幂等** | 重复运行第 2 次，`rclone` 检测文件 Checksum 完全一致，**0 字节上传传输**，秒级返回成功。 | 基于内容的 Sha256 / MD5 哈希比对。 |
| **`verify`** | **严格幂等** | 纯网络探测与 HTTP GET/HEAD 校验，任意执行无副作用。 | 只读幂等。 |
| **`release`** | **操作幂等** | 读取 GitHub / Gitee 已有附件列表：同名附件跳过，仅上传缺失文件。第 2 次执行输出“附件已全部就位，无需上传”。 | 文件名自带 `-r{rev}` 保证内容不可变；若强制重传需显式 `--force`。 |
| **`promote`** | **操作幂等<br>状态单次** | `rclone copy` 检测源与目标一致，0 文件拷贝。首次完成归档台账；重复执行识别到已被 promote，直接返回成功。 | 生产区为只追加不删除策略，避免历史关卡资产被破坏。 |
| **`git`** | **严格幂等** | 重复运行提示 `working tree clean` 与 `Everything up-to-date`，脚本捕获并正常返回 0。 | Git 原生幂等。 |

---

## 6. 本地门禁（`check-local`）核心实现规划

### 6.1 模块一：复用 `studio.verify_data`
在 `scripts/publish/publish.py` 或独立的 `scripts/publish/check_local.py` 中直接导入或调用 `studio.verify_data`：

```python
from studio.verify_data import verify_root, load_taxonomy_tags

def run_static_checks(publish_root: Path, repo_root: Path) -> tuple[bool, list[str]]:
    taxonomy_p = repo_root / "data" / "taxonomy.json"
    tags = load_taxonomy_tags(taxonomy_p) if taxonomy_p.is_file() else None
    
    report = verify_root(publish_root, name="LocalPublishGate", tag_whitelist=tags)
    return report.failed == 0, report.problems
```

**涵盖核验点**：
1. 引用完整性：`main` 关卡图片全存在、`events/collections` 封面全存在、`daily/events/collections` 的 ZIP 全存在且大小非空；
2. 物理损坏排查：对每个 ZIP 执行 `zipfile.ZipFile.testzip()`，任何 CRC32 损坏或格式错误当场捕获；
3. 压缩包条目计数：ZIP 包内文件数量与 index.json 的 `totalCount` 必须严格一致，且不含 0 字节空文件；
4. 字段规范与哈希：`modules.*.hash` 等于 index.json 字节的 sha256，所有 `fileSizeBytes` 与 `zipSha256` 与本地实体对齐；
5. 标签体系：主线关卡标签必须 100% 命中 `data/taxonomy.json` 中的英文标签白名单。

### 6.2 模块二：Dart 客户端反序列化契约测试
编写轻量本地测试 `test/logic/jigsawdata_local_verify_test.dart`，支持通过环境变量或 `--dart-define` 指定本地路径：

```bash
flutter test test/logic/jigsawdata_local_verify_test.dart \
  --dart-define=LOCAL_DATA_DIR="F:/Pictures/JigsawGame/jigsaw-data/release"
```

**核验逻辑**：
- 直接使用 App 核心模型：`RootManifest.fromJson`、`PuzzleLevelItem.fromJson`、`PuzzleEventItem.fromJson`、`PuzzleCollectionItem.fromJson`；
- 读取本地 JSON 字符串反序列化，断言所有字段解析 0 抛错、类型强校验合格；
- 确保 App 生产代码与本次产物协议完全兼容。

---

## 7. 开发者常用操作指南 (SOP)

### 7.1 一键全自动安全发布（推荐日常使用）
```bash
python scripts/publish/publish.py all
```
> **流程保障**：内部自动按 `prepare -> check-local -> stage -> verify(stage) -> release -> promote` 严格链式执行。**在第 2 步本地测试通过前，绝不产生任何网络流量**。

### 7.2 单步手动排查与分步发布
```bash
# 1. 本地准备
python scripts/publish/publish.py prepare

# 2. 本地深度体检（断网可用）
python scripts/publish/publish.py test

# 3. 预演同步与巡检
python scripts/publish/publish.py stage
python scripts/publish/publish.py verify --env stage

# 4. 备源 Release 附件就位
python scripts/publish/publish.py release

# 5. 正式生产秒级生效与全量巡检
python scripts/publish/publish.py promote

# 6. 代码与配置备份
python scripts/publish/publish.py git -m "publish assets 20260911"
```

> **状态机拦截保障**：若跳过 Step 2 直接运行 Step 3/5，脚本将立刻抛出 `[FATAL] 状态不满足` 并安全中断，绝不盲目上传。

### 7.3 异常重置
```bash
# 放弃当前处于中间态的发布，重置回初始状态
python scripts/publish/publish.py reset
```

---

## 8. 实施改造任务清单 (Implementation Checklist)

- [ ] **Task 1: 台账状态机升级 (`scripts/publish/ledger.py`)**
  - 增加流水线状态枚举：`INIT`, `PREPARED`, `LOCAL_VERIFIED`, `STAGED`, `STAGE_VERIFIED`, `RELEASED`, `PROMOTED`, `FINISHED`；
  - 提供 `assert_pipeline_state` 与 `set_pipeline_state` 方法；
  - 修复 `prepare` 重复运行读取版本基线漂移的问题。
- [ ] **Task 2: 新增本地门禁子命令 (`publish.py test` / `check-local`)**
  - 集成 `studio/verify_data.py` 的校验能力；
  - 集成 WebP 图片解码完整性校验（确保图片非空且有效）；
  - 支持运行 Dart 本地反序列化契约测试。
- [ ] **Task 3: 重构 `publish.py` 编排逻辑**
  - 为所有子命令（`stage`, `verify`, `release`, `promote`, `git`）注入前置状态拦截器；
  - 调整 `do_all` 流程，将本地测试前置为首个网络动作前的硬门禁；
  - 增加 `reset` 子命令用于异常重置。
- [ ] **Task 4: 新增 Dart 本地契约测试**
  - 创建 `test/logic/jigsawdata_local_verify_test.dart`，无需网络，直接断言本地 release 目录下的模型解析。
- [ ] **Task 5: 更新文档与使用手册**
  - 更新 `scripts/publish/README.md`，明确标注各命令的幂等性与状态机流转。
