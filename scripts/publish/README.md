# jigsaw-data 素材发布工具（v3）

> 方案原文：[`scripts/publish/PUBLISH_WORKFLOW_V3_DESIGN.md`](PUBLISH_WORKFLOW_V3_DESIGN.md) ｜ 前序：[`docs/assets-publish-workflow-v2-20260910.md`](../../docs/assets-publish-workflow-v2-20260910.md)  
> 本目录是**唯一的素材发布编排入口**，日常发布全部通过 `publish.py` 完成。

## 1. 设计原则

| # | 原则 | 说明 |
|---|---|---|
| 1 | **本地测试先行** | **“本地全绿方可触网，预演全绿方可晋产”**。向云端发送任何字节前，必须在本地离线 100% 通过全部数据与客户端模型体检。 |
| 2 | **发布状态机强约束** | 状态严格单调推进（`INIT -> PREPARED -> LOCAL_VERIFIED -> STAGED -> ... -> PROMOTED`），强制核验前置状态，彻底杜绝越级 promote。 |
| 3 | **同构目录，零路径改写** | Studio 导出的 `Output` 结构就是远端托管结构。`zipUrl` 恒为相对路径，严禁改写成绝对地址。 |
| 4 | **预演前缀隔离** | R2 上 `_stage/`（测试预演）与 `release/`（正式生产）两个顶层前缀，先预演验证，通过后再秒级 promote。 |
| 5 | **相对 URL + Release 兜底镜像** | `zipUrl` 相对、随环境自洽解析；`zipUrls` 只放 Gitee/GitHub Release 的**绝对**地址作容灾备用。 |
| 6 | **备源先上，主源再切** | 先上传两端 Release 附件，最后才把 R2 切到生产，杜绝容灾真空期。 |
| 7 | **全场景自愈与防死锁** | `prepare` 随时作为全新迭代入口重置状态，支持原地重试续传、`reset` 清理复位与 `--force` 紧急运维逃生通道。 |

---

## 2. 目录与远端角色

| 路径 / 端点 | 角色 | 权限 | 说明 |
|---|---|---|---|
| `F:\Pictures\JigsawGame\Output` | 输入源（Studio 导出） | **只读** | 含游离的 `.git`，必须在拷贝时排除 |
| `F:\Pictures\JigsawGame\jigsaw-data\release\` | 本地发布工作副本 | 可写 | `prepare` 生成，也是 rclone 的同步源 |
| `r2:jigsaw-data/_stage/` | R2 预演区 | 远端可写 | 测试版 App 与巡检脚本使用 |
| `r2:jigsaw-data/release/` | R2 生产区 | 远端可写 | 线上用户唯一读取主源 |
| `https://jigsawdata.umao.top/` | R2 自定义域名 | 只读 | 国内外统一入口，免备案 |
| GitHub / Gitee `master` 分支 | JSON + WebP 备份 | 远端可写 | `.zip` 被 `.gitignore` 排除 |
| GitHub / Gitee Release `assets` | zip 备用下载源 | 远端可写 | 扁平命名空间，14 个 zip |

---

## 3. 环境准备

### 3.1 必需工具

```bash
rclone version      # >= 1.74，需已配好名为 r2 的 remote
rclone listremotes  # 应输出 r2:
gh auth status      # 需登录且具备 repo 权限（用于 GitHub Release）
```

### 3.2 凭证

```bash
# Gitee 私人令牌（repo 权限），Gitee 附件上传必需
export GITEE_TOKEN=<your-gitee-token>          # Windows CMD: set GITEE_TOKEN=...
# Cloudflare 的 token 仅在极端情况跑 purge 时才需要，正常发布不用配

# 建议始终开启，避免 Windows 控制台 GBK 编码报错
export PYTHONIOENCODING=utf-8
```

> **安全提醒**：令牌只写入当前 shell 环境，不要落到任何文件里，更不要提交到 Git。

### 3.3 Python

统一使用项目虚拟环境：

```bash
PY=C:/Home/Develop/venv/Scripts/python.exe
```

---

## 4. 命令参考

统一入口（`cd C:/Home/Projects/jigsawpuzzle`）：

```bash
"$PY" scripts/publish/publish.py <子命令> [选项]
```

| 子命令 | 作用 | 常用选项 |
|---|---|---|
| `prepare` | 白名单拷贝 + 注入 `zipUrls` + 重算模块 hash + 硬门禁 + 变化检测（状态 -> PREPARED） | `--force`（忽略无变化拦截） |
| `test` (别名 `check-local`) | **本地全量深度门禁**（`studio.verify_data` 静态体检 + WebP 解码核验 + Flutter 客户端模型契约） | `--skip-flutter`、`-v`、`--force` |
| `stage` | 同步本地 `release/` 到 R2 `_stage/`（需通过 test 门禁） | `--dry-run`、`--force` |
| `verify` | 巡检（JSON sha256 + 图片/zip 可达性） | `--env stage\|prod`、`--dry-run`、`--include-mirrors`、`--force` |
| `release` | 上传新增 zip 到 GitHub / Gitee Release（需 stage 巡检合格） | `--dry-run`、`--force` |
| `promote` | R2 桶内服务端复制 `_stage` → `release`，随后自动跑 `verify --env prod`（严禁越级调用） | `--dry-run`、`--force` |
| `all` | **按安全时序跑全套**（`prepare → test → stage → verify(stage) → release → promote`） | `--dry-run`（只读模拟演练）、`--skip-flutter`、`--force`（忽略无变化/状态拦截） |
| `reset` | **重置发布会话**：清理进行中状态回 `INIT`，解除任何异常锁定 | — |
| `git` | 提交并推送 `jigsaw-data` 的 json/webp（需 promote 成功后执行） | `-m <message>`、`--dry-run`、`--force` |
| `purge` | 手动清 Cloudflare 边缘缓存（仅应急） | 需 `CF_API_TOKEN` / `CF_ZONE_ID` |

> `git` 故意**不并入** `all`：Git 提交需要人工确认后再执行。

---

## 5. 标准发布流程

### Step 0 · Studio 重新导出到 `Output`

### Step 1 · 本地准备

```bash
"$PY" scripts/publish/publish.py prepare
```

### Step 2 · 本地全量体检（核心前置门禁，0 网络）

```bash
"$PY" scripts/publish/publish.py test
```

依次执行三层深度验证：
1. **静态完整性体检**（`studio.verify_data`）：文件引用存在、字段完整、内容哈希、ZIP CRC32 坏块排查、条目数等于 `totalCount`、Manifest 自洽性、`taxonomy.json` 标签白名单；
2. **WebP 解码核验**：PIL 全量实测解码所有 WebP 图片，杜绝空图与坏图；
3. **Flutter 客户端契约测试**：`flutter test test/logic/jigsawdata_local_verify_test.dart`，用真实 App 数据模型反序列化本地产物，断言 0 异常。

> ❌ **只要本地测试有任何一项不通过，流水线严禁向远端推任何数据，远端 0 污染。**

### Step 3 · 同步到预演区与巡检

```bash
"$PY" scripts/publish/publish.py stage
"$PY" scripts/publish/publish.py verify --env stage
```

### Step 4 · 备源附件先行就位

```bash
"$PY" scripts/publish/publish.py release
```

### Step 5 · 生产生效

```bash
"$PY" scripts/publish/publish.py promote
```

R2 桶内 Server-Side Copy，数据不经过本地，秒级完成；随后自动执行 `verify --env prod`。

### Step 6 · Git 备份推送

```bash
"$PY" scripts/publish/publish.py git -m "publish assets 20260911"
```

### Step 7 · 三通道全量终检

```bash
"$PY" scripts/publish/verify_channels.py --env prod --include-mirrors
```

不带 `--include-mirrors` 时只校验 R2 全量 + 国内可用（`cn>0`）通道的 zip 附件；加上后做三通道全量（当前 639 条）。

> **必须在本步（git 推送）之后才跑 `--include-mirrors`**。JSON 是按 sha256 逐字节比对的，而 Git 通道的 raw 内容要等 `git` 步骤推送后才更新；在推送前做全量终检，Gitee/GitHub raw 仍是上一版内容，会因 hash 不一致而误报失败。

---

## 6. 关键陷阱（务必先读）

### 6.1 `main.version` 必须递增

客户端 `MainContentPipeline.syncWithRemote` 存在 `remoteVersion <= _localVersion` 的短路：**版本不涨，已装机 App 完全不会重新拉取**，即使内容已经更新。

- Studio 重导时若新增/变更了批次，`version` 会自动 +1；
- 只改图不增批次时，`version` 不变，此时必须手动把 `Output/manifest.json` 与 `Output/main/index.json` 的 `version` 各 +1，或让测试机清空 App 数据。

`prepare` 会做递增门禁；具体行为：

| 情况 | 行为 |
|---|---|
| `cur > prev` | 通过 |
| `cur == prev` | **告警放行**，并提示「客户端不会重新拉取，若为改图/纠错请手动递增」 |
| `cur < prev` | **中断**（版本回退；确需回滚请见 §8，回滚版本号必须更高） |
| 无历史基线 | 放行（首次发布） |

**基线从哪来**（按序尝试，无需额外维护任何文件）：

1. `.publish/latest.json` —— 上一次真正**成功完成发布**的归档快照，杜绝被前一次失败的半成品误导；
2. 远端 R2 生产区的 `release/manifest.json` —— 本地台账缺失时兜底（新机器克隆、工作副本被清）；
3. 本地工作副本 `jigsaw-data/release/manifest.json` —— 降级兼容；
4. 都拿不到 -> 视为首次发布。

> `jigsaw-data/release/manifest.json` 在 Step 5 会随 `git push` 提交入库，因此基线天然持久化且可跨机共享，**不需要任何独立的基线文件**。

### 6.2 zip 内容改了但文件名没变 → 用 `--force`

Studio 只在**上一次导出记录存在**时，才把同名 zip 自增为 `-r2`（见 `daily_exporter.py` / `pack_exporter_base.py`）。一旦出现「内容变了、名字没变」：

- R2 会更新（`rclone --checksum` 按内容覆盖）；
- 但 Release 附件因同名被跳过，**旧包留在 Gitee/GitHub**，造成主备内容分裂。

判断方法：对比新旧 `Output/<module>/index.json` 里的 `zipSha256`，变了但文件名没变就：

```bash
"$PY" scripts/publish/publish.py release --force
```

- **GitHub** 侧用 `gh release upload --clobber`，同名会直接覆盖，安全。
- **Gitee** 侧共用名 Attachment 的行为**尚未实测确认**：OpenAPI 的 `attach_files` 端点对已删除/无效的 release 一律返回 `404 Not Found`，容易与「重名被拒」混淆。若 `--force` 后仍命中旧包，请到 Gitee 网页端先删除同名附件再重跑 `release`。

### 6.3 `channels.json` 的 zip 规则必须写 `prefixes`

```json
{ "prefixes": ["zip"], "base": ".../releases/download/{tag}/", "layout": "flatten" }
```

写成 `"set": "zip"` 会导致规则永不命中，zip 地址被错算成仓库 raw 路径（v1 遗留问题，已修正）。

### 6.4 Gitee API 的「不存在」响应

两处坑都已踩过：

1. `GET /repos/{o}/{r}/releases/tags/{tag}` 在 release 不存在时返回 **HTTP 200 + 空体**（不是 404），必须同时判断状态码和返回体是否可解析为 dict，否则会拿到 `None` 后崩溃。
2. `POST /releases/{id}/attach_files` 在 **release 不存在**（或 id 失效）时返回 `404 Not Found`，这个状态码**不等于重名被拒**，排查时不要误判。

排查命令：

```bash
# 看 release 是否存在（返回 null / [] 即不存在）
curl -sS -H "Authorization: token $GITEE_TOKEN" \
  https://gitee.com/api/v5/repos/macitee/jigsaw-data/releases
```

### 6.5 Cloudflare 缓存规则

`.json` 的 Bypass Cache 规则是**控制台手动配置**的一次性动作，脚本无法探测。若发布后客户端拿到的仍是旧 manifest，用 `purge` 应急或检查该规则是否失效。

---

## 7. 发布台账与无变化检测

### 7.1 台账落在哪、有什么

台账位于 **jigsaw-data 仓库的 `.publish/`**（刻意放在 `release/` 之外，否则会被 `prepare` 的整目录重建清掉）。它会随 Step 5 的 `git push` 入库，因此天然持久化、可跨机器共享，同时充当下次运行的变化检测基线。

| 文件 | 用途 |
|---|---|
| `run.json` | 本次进行中的运行记录，每个子命令结束后增量更新 |
| `latest.json` | 最近一次**已完成**发布的完整快照（下次 diff 的基线） |
| `history.ndjson` | 每次完成追加一行摘要，审计留痕（约 170B/行） |
| `runs/<runId>.json` | 详情归档，滚动保留最近 50 次 |

`latest.json` 内含：文件清单（逐文件 `size` + `sha256`）、`main.version`、各模块 hash、源指纹、变化清单、各步骤返回码（stage/release/promote）。

### 7.2 双层指纹：注入后产物与源不一致，怎么比？

发布流水线会改动两类文件：`daily/events/collections/index.json` 注入 `zipKey`/`zipUrls`，`manifest.json` 重写各模块 hash。所以**源与产物并非逐字节相同**。这里记录两层：

| 指纹 | 对象 | 作用 |
|---|---|---|
| `sourceFingerprint` | 输入源 `Output` 那份**未被改动**的原始文件（聚合摘要） | 归因：变了说明 Studio 重新导出过 |
| `publishedFiles` | 真正上传的 `release/` 树（逐文件 `size`+`sha256`） | 判定"远端会不会真的变化"，也是下次 diff 的基线 |

判定：

- `publishedFiles` 有变化 → 远端需要更新，正常发布
- 两者都变 → 数据源确实变了
- 仅 `publishedFiles` 变、`sourceFingerprint` 没变 → **异常**：注入逻辑或基线被改，日志里 `sourceChanged: false` 会标出来，需人工确认

### 7.3 无变化拦截

产物无变化时不会直接放行，而是先跑一次 `rclone check <dir> r2:jigsaw-data/release --size-only` 核对远端：

| 情况 | 行为 |
|---|---|
| 无变化 + 远端已同步 | **中止**（退出码 3），提示"没有需要发布的变更"，需 `--force` 才继续 |
| 无变化 + 远端不一致/被清空 | 允许继续（用于把远端补全量内容） |
| 无变化 + `--force` | 放行（`all --force` 会透传该选项至 `prepare` 强制推进） |
| 无历史台账 | 按首次发布处理，不拦截 |

`all` 遇到退出码 3 会打印「判定无需发布」并正常结束（返回 0），不算失败；若确需全链路强制重新发布（如重发 Release 附件），请使用 `python publish.py all --force`。

### 7.4 关于 main.version

publish 侧**不会**自动自增 `main.version`。版本号由 Studio 导出侧负责（见 §6.1），publish 只做校验与提示。

## 8. 增量发布

日常增量（新增月份 / 批次 / 活动）与首次发布**命令完全相同**，脚本天然做增量：

- `prepare`：源文件数守卫 + 版本门禁，产物每次全量重建（最简单也最可靠）；
- `stage`：`rclone sync --checksum` 只传变化文件；
- `release`：按附件名跳过已有，只传新增 zip；
- `promote`：`rclone copy --checksum` 只合入差异。

注意 `promote` 用的是 `copy` 而非 `sync`：**不会删除生产区的历史对象**，这正是回滚安全的前提。

---

## 9. 回滚 SOP

1. 取回上一版 JSON：

   ```bash
   git -C F:\Pictures\JigsawGame\jigsaw-data checkout HEAD~1 -- release/
   ```

2. **必须把 `manifest.json` 的 `modules.main.version` 与 `main/index.json` 的 `version` 各 +1**（如线上是 4，回滚文件要设成 5），否则已更新的客户端因版本短路不会拉回滚内容。

3. 推回生产：

   ```bash
   rclone copy F:\Pictures\JigsawGame\jigsaw-data\release r2:jigsaw-data/release --checksum
   ```

历史图片与 zip 在 R2 上从未删除，旧 JSON 指向的文件天然可达，回滚秒级完成。

---

## 10. 客户端契约测试

```bash
flutter test test/logic/jigsawdata_three_channel_verify_test.dart \
  --dart-define=CHANNELS_VERIFY=true
```

用 App 真实的网络客户端与数据模型消费三通道，校验 `zipUrl` 相对解析、`zipUrls` 绝对回退、下载字节数与 `fileSizeBytes` 一致。

可选参数：

| dart-define | 默认 | 说明 |
|---|---|---|
| `CHANNELS_VERIFY` | `false` | 总开关，不设则跳过 |
| `CHANNELS_BRANCH` | `release` | 仓库内发布前缀目录 |
| `CHANNELS_FULL_ZIP` | `false` | 下载全部 zip（默认每模块仅一个） |
| `CHANNELS_FULL_MIRRORS` | `false` | 严格要求全部兜底镜像可达（GitHub Release 在国内可能被重置，默认仅要求首个） |
| `R2_BASE` / `GITEE_BASE` / `GITHUB_BASE` | — | 覆盖通道基址 |

> 预演区只存在于 R2（Git 上没有 `_stage`），验证预演数据时建议只覆盖 `R2_BASE=https://jigsawdata.umao.top/_stage/`。

---

## 11. 文件清单与 v1 遗留

| 文件 | 状态 | 说明 |
|---|---|---|
| `publish.py` | 在用 | v3 唯一编排入口（内置发布状态机与各子命令门禁） |
| `check_local.py` | 在用 | 本地离线全量体检门禁（`studio.verify_data` + WebP解码 + Flutter反序列化） |
| `gitee_release.py` | 在用 | Gitee OpenAPI v5 附件增量上传（跳过已有 + 800MB 软告警） |
| `verify_channels.py` | 在用 | 远端网络可达性与一致性巡检 |
| `channels.json` | 在用 | 唯一真源：路径、releaseTag、三通道定义 |
| `ledger.py` | 在用 | 流水线状态机、文件级指纹、变化清单、`.publish/` 台账读写与归档 |
| `assetmap.py` | 在用 | key ↔ URL 映射、zipKey/is_zip_key/冲突检测等工具 |
| `normalize.py` | **遗留** | v1 的 `zipKey` 注入逻辑，v2 已并入 `prepare`，保留仅供对照 |
| `gitee_publish.py` | **遗留** | 存在 `sys.environ` 拼写 bug 且无跳过逻辑，已由 `gitee_release.py` 取代 |
| `app_reference/` | **遗留** | v1 时期给 App 端参考的 Dart 片段 |

> 说明：`zipKey` 字段客户端从未读取（`lib/` 中 0 次引用），客户端真实消费的是 `zipUrl` + `zipUrls`。之所以仍保留注入，仅为便于脚本侧核对与向后兼容，删除不影响功能。
