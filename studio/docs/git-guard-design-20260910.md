# .studio 目录 Git 版本化与导出节点自动提交设计

> 日期：2026-09-10
> 状态：已评审，实施中
> 关联：`core/workspace.py`（.studio 目录拓扑）、`server.py`（导出/回滚任务调度）、`docs/export-ledger-operations-and-rollback-design-20260909.md`

## 一、背景与目标

素材工作台在源素材库目录下维护私有工作区 `.studio/`，其中 tags.json（标签）、
ledger/exports.json（导出账本）、logs/*.jsonl（审计流水）是核心结构化元数据，
一旦误改/误删很难恢复，也无法回答"某次导出时账本是什么状态"这类历史问题。

目标：

1. 将 `.studio/` 纳入独立 git 仓库管理（仓库建在 `src_dir/.studio` 内，自包含）；
2. 导出、回滚等节点事件自动 checkpoint / commit，形成可追溯的时间线；
3. 支持 strict 守卫模式：导出前若 `.studio` 存在未提交变更则拦截导出；
4. git 不可用时优雅降级，绝不阻塞业务主流程（strict 模式除外）。

非目标：

- 不版本化素材图片本身（源素材库主体不建 git，避免 2.5 万张图的 status 扫描开销）；
- 不做远端 push / 多机同步；
- 不改变现有账本/回滚的语义，git 快照仅作为只读的历史参照与兜底恢复手段。

## 二、仓库布局与跟踪范围

repo 位置：`<src_dir>/.studio/`（即 `StudioWorkspace.studio_dir`），所有 git 操作
统一以该目录为 work tree，避免把 src_dir 下的海量素材纳入 git 扫描。

`.gitignore`（由 git_guard 在每次 `ensure_repo` 时**校准**，非整文件覆盖）：

```gitignore
# >>> studio git guard managed, do not edit >>>
# 高频二进制缓存、构建镜像与 rollback 快照（可重建，勿入库）
cache/
staging/
release/
ledger/backups/

# 兜底：.studio 只版本化文本元数据（tags/ledger/logs），压缩包与图片产物
# 一律不属于版本化范围
*.zip
*.png
*.jpg
*.webp
# <<< studio git guard managed <<<
```

**托管区机制（2026-09-10 修正）**：guard 只维护两个标记之间的内容，标记之外
是用户自由区——用户追加的任何规则都会被保留，**绝不会被静默抹掉**；模板升级
（如新增 `ledger/backups/`）仍能通过替换托管区下发到老仓库。无标记的老文件
（历史遗留）则原样保留并在末尾追加托管区，不丢任何既有行。

`ledger/backups/` 必须忽略：① 每次回滚前的账本快照 `exports-*.json`
（单份 200~300KB，随导出持续新增）；② 回滚把 release 镜像里被移除的产物移入
`trashed-<op>/` 保留而非物理删除，其中含 `*.zip` / `*.webp`。此前模板未覆盖
该目录，导致 2.1MB zip 与 52KB webp 被 `git add -A` 提交进仓库（见变更日志）。

跟踪范围（即提交内容）：

| 路径 | 性质 | 说明 |
|---|---|---|
| `tags.json` | 文本 | 标签主数据 |
| `ledger/exports.json` | 文本 | 导出账本（回滚依据之一） |
| `logs/operations.jsonl` | 追加文本 | 操作审计流水 |
| `logs/exports.jsonl` | 追加文本 | 导出审计流水 |
| `.gitignore`、`.gitattributes` | 文本 | 仓库自身配置 |

未在白名单内的其余文件（如未来新增的临时文件）按 .gitignore 结果处理：git_guard
提交时使用 `git add -A`，因此 ignore 之外的任何新增文件也会被提交——这保证
"clean" 的语义严格成立（strict 模式下不 clean 就拦截），不依赖白名单的完备性。

**反过来说这也是必须守的纪律**：`git add -A` 不区分文件来源，任何新增的
guard/回滚产物目录（如 `ledger/backups/`）一旦没进托管区，就会连着体积大的
zip/webp 一起被提交（2026-09-10 已发生一次）。新增此类目录时**必须同步更新
`GITIGNORE_MANAGED_BODY`**。

由于「目录名白名单不可能穷尽」，托管区额外按**扩展名兜底**忽略
`*.zip` / `*.png` / `*.jpg` / `*.webp`：`.studio` 的版本化范围只有文本元数据，
仓库内出现的压缩包与图片按定义都属于构建产物或回滚残渣，不存在误伤场景。
这条兜底与 `release/`、`ledger/backups/` 构成两层防线（正常路径 + 未知路径）。

### 关键防坑配置

- `core.autocrlf=false`（repo 局部）：与主仓库决策一致，杜绝 CRLF 污染；
- `.gitattributes` 写 `* -text`：彻底关闭行尾转换，jsonl/json 按原样存储；
- `user.name=studio` / `user.email=studio@local`（repo 局部）：机器未配置全局
  git 身份时 commit 仍可执行；
- `gc.auto=0`：小仓库无需自动 gc，避免导出过程中触发 gc 造成的偶发卡顿；
- `status.showUntrackedFiles=all` 默认即可，无需额外配置。

## 三、守卫模式（gitGuard）

配置来源：`.studio/git_guard.json`（不存在时视为默认值 `auto`）。字段：

```json
{ "mode": "auto" }
```

| mode | 行为 |
|---|---|
| `off` | git_guard 完全不参与导出/回滚流程（不 init、不 commit、不校验） |
| `auto`（默认） | 导出前自动 checkpoint（有变更才 commit）；导出/回滚成功后自动 commit |
| `strict` | 在 auto 基础上，导出前若存在未提交变更且自动 commit 失败，则拦截导出 |

### 模式语义细节

- `auto` 模式下导出前的 checkpoint 是"尽力而为"：commit 失败（如 .studio 被
  其他进程占用）只记 warning，导出继续——因为账本本身还有两阶段发布与
  snapshot 兜底，git 只是额外保险；
- `strict` 模式下"不 clean 就拦截"的实现为：先尝试自动 checkpoint，只有
  commit 也失败、仓库仍有未提交变更时才拦截；纯只读的 dirty 检查会被自动
  checkpoint 化解，避免用户被无意义的脏状态卡住；
- 试导出（trial）不产生任何 git 操作（不 checkpoint 也不 commit），它不写
  账本与 release，没有需要记录的状态变化；
- 素材标签的日常单条修改不触发 commit（避免 jsonl 每追加一行就产生碎片
  commit）；未来如需"标签批量整理快照"，可暴露手动入口，本设计暂不实现。

## 四、commit 节点与消息规范

| 节点 | 时机 | 消息格式 |
|---|---|---|
| 初始导入 | repo 首次初始化 | `chore: init studio git guard` |
| 导出前 checkpoint | `_handle_export` 正式导出发起时（validate 之前） | `checkpoint(pre-export): <exp_type> (auto)` |
| 导出后 | 正式导出成功收尾处 | `export(<exp_type>): <n> images`（n=result.count=len(images)） |
| 导出失败 | 正式导出失败收尾处（有变更才提交，记录失败现场） | `export(<exp_type>): failed after checkpoint (auto)` |
| 回滚后 | `undo_op` 成功且非 dryRun 后 | `rollback(<modules>): op=<opId> <reason或msg>` |

- 消息首行为单行摘要，无正文，保证 `git log --oneline` 可读；
- `<n>` 的取值：`ExportResult.count`（由各导出器回填 `len(images)`，即本次实际
  产出图片数）。**严禁使用 `len(result.files)`**：`files` 是
  `StudioWorkspace.copy_release_to_out()` 的全量交付文件清单（含
  `index.json`/`manifest.json`/`zip`/封面 webp），且 main 镜像跨批次累积，
  其长度与图片张数无对应关系（2026-09-10 修正，见变更日志）；
- 自审修正：导出前 checkpoint 发生在 validate 之前，此时张数未知，故消息不含
  `<n>`；`ExportResult` 无 batchId 字段（仅出现在 summary 文本中），消息规范不
  依赖它；回滚的 `<modules>` 取自 `undo_op` 返回的 `modules` 列表（逗号连接）；
- 所有节点 commit 前先做 dirty 检查，clean 则跳过（不产生空 commit）。

## 五、模块设计：`studio/core/git_guard.py`

公开 API（模块级函数，内部用 GitPython 实现，git CLI 仅作 fallback 探测）：

```python
class GitGuardError(RuntimeError): ...

def load_mode(studio_dir: Path) -> str          # 读 git_guard.json，非法值回退 "auto"
def is_managed(studio_dir: Path) -> bool        # .studio/.git 是否存在
def ensure_repo(studio_dir: Path) -> bool       # 幂等初始化：git init + 配置 + ignore + 首次提交
def checkpoint(studio_dir: Path, msg: str) -> bool   # dirty 时 add -A + commit，clean 返回 False
def guard_export(studio_dir: Path, exp_type: str, *, strict: bool) -> str | None
    # 导出前置：返回 None=放行，返回 str=拦截原因（strict 且 checkpoint 失败）
def commit_after_export(studio_dir: Path, exp_type: str, n: int, failed: bool = False) -> None
    # n = 本次导出图片张数，由调用方传 result.count（不可用 len(result.files)）
def commit_after_rollback(studio_dir: Path, modules: list[str], op_id: str, reason: str) -> None
```

实现要点：

1. **GitPython 优先**：`import git` 成功则用 `git.Repo`/`repo.index.add`/`commit`；
   import 失败或执行异常时降级为 `subprocess` 调 git CLI（同参数语义），两者都
   不可用时所有 API 静默降级为 no-op 并记 logger.warning；
2. **线程安全**：模块级 `threading.Lock` 串行化 commit 操作；导出/回滚在
   server 层已有任务互斥，此处锁仅防御异常路径下的并发；
3. **超时控制**：GitPython 调用包一层 `concurrent.futures` 超时（10s），git 挂起
   时降级为 warning，不拖垮导出线程；
4. **dirty 判定**：`repo.is_dirty(untracked_files=True)` + 对 ignore 生效性做一次
   自检（`cache/` 必须被忽略）；GitPython 不可用时用 `git status --porcelain` 判定；
5. **幂等初始化**：`ensure_repo` 在已存在合法 repo 时直接返回 True，不重复 init；
   `.gitignore`/`.gitattributes` 走 `_calibrate_managed_file`——只替换托管区标记
   之间的内容并在无变化时不落盘（避免无意义 mtime 变化），标记之外的用户内容
   一律保留；不提供任何"整文件覆盖"路径。

## 六、server 挂接点

### 6.1 导出流程（`_handle_export`）

- 正式导出（`data.get("trial")` 为假）时，在 `exporter.validate()` 之前：
  `mode = load_mode(...)`；`mode != "off"` 时 `ensure_repo` → `guard_export(...)`；
  `guard_export` 返回拦截原因时按业务校验失败处理（400 + 导出中止日志）；
- 导出成功且非 trial：`commit_after_export(src_p / ".studio", exp_type,
  result.count or len(result.files or []))`，用 try/except 包裹，失败仅
  logger.warning，不影响 200 响应；`result.count` 由导出器回填为
  `len(images)`，`files` 仅作 `count` 缺失时的兜底（正常路径不会走到）；
- 导出失败（ValueError / Exception 分支）：`commit_after_export` 的失败变体
  （`export(...): failed ...`），同样尽力而为。

### 6.2 回滚流程（`_handle_rollback`）

- `undo_op` 返回 ok 且非 dryRun 后调用 `commit_after_rollback(...)`；dryRun
  不做任何 git 操作。失败仅 warning，不影响回滚结果返回。

### 6.3 观测

- 每次实际 commit 后 log 一条 `[GIT_GUARD] committed <sha> <summary>`，便于
  在 temp/studio-YYYYMMDD.log 中回溯对应关系。

## 七、失败模式与降级矩阵

| 场景 | 行为 |
|---|---|
| git CLI / GitPython 均不可用 | 全部 API no-op + warning；strict 模式放行（无 git 即无守卫，日志明确提示） |
| `.studio/.git` 损坏 | `ensure_repo` 返回 False 并 warning；auto 放行，strict 拦截 |
| commit 时文件被占用（Windows 锁） | checkpoint 返回 False + warning；导出继续 |
| `.studio/git_guard.json` 损坏/非法 | 视为默认 `auto`，不报错 |
| 首次 init 时 `.studio` 内已有脏数据 | init 后立即整体 commit 为初始导入节点 |

## 八、测试计划（`studio/test_git_guard.py`）

unittest 风格，与现有套件一致；所有用例基于临时目录构造 `.studio` 结构：

1. `ensure_repo` 幂等：两次调用不报错，第二次不重建；`.gitignore` 内容正确且
   `cache/` 下文件不出现在 status；
2. dirty → checkpoint 产生 commit、clean → checkpoint 返回 False 不产生空 commit；
3. `guard_export`：auto 模式下 dirty 会先被 checkpoint 化解而放行；strict 模式在
   模拟 commit 失败（monkeypatch checkpoint 抛错）时返回拦截原因；
4. `load_mode`：文件缺失 / 非法 JSON / 非法 mode 值均回退 `auto`；`off` 正确读取；
5. `commit_after_export` / `commit_after_rollback`：产生对应首行消息的 commit；
6. 端到端：模拟 tags.json 修改 → 导出 checkpoint → 账本变更 → 导出后 commit 的
   git log 序列符合预期；
7. GitPython 不可用降级路径：monkeypatch 掉 `git` 模块导入，验证 CLI fallback 或
   no-op + warning 不抛异常。

## 九、实施清单

1. 新增 `studio/core/git_guard.py`；
2. `server.py`：`_handle_export` 前置 guard 与成功/失败收尾 commit；`_handle_rollback`
   成功收尾 commit；
3. 新增 `studio/test_git_guard.py`；
4. 更新 `studio/README.md`（可选，一行说明）与 `docs/CHANGES-20260910.md`；
5. （2026-09-10 修正）`exporters/base.py` 的 `ExportResult` 新增 `count` 字段，
   三个导出器回填 `len(images)`；`server.py` 改传 `result.count`。

## 十、自审记录（2026-09-10）

- [x] 仓库位置：`.studio` 内建 repo，不扫素材库主体；git 操作始终以 `.studio`
      为 work tree，嵌套仓库对主仓库（jigsawpuzzle）表现为未跟踪目录，无冲突；
- [x] SQLite WAL：`cache/` 整体 ignore，`studio.db-wal/-shm` 均在其内，clean
      语义不会因数据库抖动被破坏；
- [x] strict 拦截语义收敛为"checkpoint 失败才拦"，避免日常脏状态卡导出；
- [x] 降级矩阵覆盖 git 缺失、repo 损坏、文件占用、配置损坏；git_guard 任何
      异常都不允许向上冒泡到导出/回滚主流程（除 strict 显式拦截外）；
- [x] trial 导出零 git 操作，与 `_commit()` 语义一致；
- [x] 测试环境：venv `C:\Home\Develop\venv`（GitPython 3.1.62 + git 2.46），
      基线 93 项测试通过；测试需真实 git 可用，CI 无 git 时按用例 skip；
- [x] 编码：所有新文件 UTF-8 + LF；`.gitattributes` `* -text` 防行尾漂移；
- [x] 回滚操作（undo_op）本身不感知 git；git commit 由 server 层在 undo 成功后
      触发，职责单一，undo_op 的 dryRun 不会产生 commit；
- [x] 二次自审（读码核对）：`undo_op` 的 root 即素材库根，`root/.studio` 定位
      无误；checkpoint 消息不含未知张数；`ExportResult`/undo_op 返回结构与
      消息规范对齐；导出失败分支在 except ValueError/Exception 中可访问
      `exporter.is_trial`（trial 失败同样不做 git 操作）。
- [x] 三次自审（2026-09-10 修正）：原「n=len(result.files)」前提错误——`files`
      是 release 镜像的全量交付文件清单（含 index.json/manifest.json/zip/封面，
      且 main 镜像跨批次累积），不是图片张数，导致真实仓库 commit 消息张数长期
      偏大（如 main 80 张记成 184 images）。改为 `ExportResult.count=len(images)`，
      由三个导出器回填、server 透传；`test_studio.py` 补 `result.count` 断言，
      `temp/verify_gg_count.py` 端到端复验 `export(main): 5 images` 正确。
      历史错误 commit 不重写（只读历史参照，重写破坏哈希链）。
- [x] 四次自审（2026-09-10 缺陷复盘）：原 `_write_once` 是"内容≠模板就整体覆盖"，
      且每次 `ensure_repo` 都执行，导致用户手改的 `.gitignore` 每次导出被静默抹掉，
      并在同一 commit 里把因此"解禁"的 `ledger/backups/` 内容（含 2.1MB zip、
      52KB webp、23 份账本快照）扫入版本库。修复：改为托管区校准
      （`_calibrate_managed_file`，只维护标记之间的内容）+ 托管区补 `ledger/backups/`。
      `test_git_guard.py` 新增 4 例覆盖：备份目录被忽略、用户规则跨 ensure_repo
      保留、无标记老文件不丢内容、模板升级时用户规则保留。历史不重写。
