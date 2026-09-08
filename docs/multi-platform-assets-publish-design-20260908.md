# jigsaw-data 多平台 Assets 发布与分发方案（设计 + 验证）

> 日期：2026-09-08 ｜ 状态：方案已落地并实测（R2 全通道通过，GitHub 已发布，Gitee Release 待上传，ModelScope 暂时禁用）
> 配套脚本：`scripts/publish/`（发布编排、通道表、跨通道巡检、app 端 Dart 参考实现）
> 关联：`studio/docs/unified-content-export-and-storage-architecture.md`、AGENTS.md

---

## 0. 痛点与目标

原流程 `studio.exporters` 原生导出的是**相对 URL**（如 `zips/202609.zip`），但 `scripts/deploy/export_data.py`
会在发布前把这些 zipUrl **改写成单一平台的绝对地址**（GitHub Release），导致：

1. 同一份内容要针对不同平台反复改写 JSON → 内容漂移、易错。
2. zip 的备用镜像（`zipUrls`）在导出时就写死，新增通道要重新导出+重推。
3. 国内外分流、主备切换只能靠 app 端硬编码的 `bootstrapUrls` 顺序轮询，慢且不可数据驱动。

**目标**：内容产物（dist）**平台无关**，平台差异 100% 收敛到一份 **通道表 `channels.json`**；
发布侧与 app 端读同一份定义，实现「一套内容、一次导出、多平台发布、国内外分流、主备自动切换」。

**活动通道收敛**（2026-09-08 修订）：只保留 **R2（r2cdn/r2pub）→ GitHub → Gitee** 三个活动平台；
ModelScope 因 token git push 鉴权异常**暂时禁用**；jsDelivr 降级为**仅 manifest.json 的路由 URL 备份**，不承载内容分发。

---

## 1. 核心约定：canonical key（相对 key）

dist 产物里所有引用一律写成 **相对 dist 根的 POSIX 路径（canonical key）**，永不写平台绝对地址：

```
manifest.json
main/index.json
main/images/101.webp
daily/zips/202609.zip
events/packs/evt_ocean_adventure.zip
collections/packs/col_wild_animals.zip
```

> 关键发现：studio 原生导出的 `out/` 其实**已经是相对 key**（如 `zips/202609.zip`），
> 是 `export_data.py` 把它改写成了绝对 Release URL。所以我们的发布链改为：
> **从 `out/` 出发 → normalize 阶段注入 `zipKey`（相对 key）+ 保留 `zipUrl`（旧端兼容）→ 发布 `stage/`。**

### JSON 字段约定（向后兼容）
- `zipKey`（新增）：相对 dist 根的 canonical key，如 `daily/zips/202609.zip`。**新端用它合成多平台镜像。**
- `zipUrl` / `zipUrls`（保留）：旧端兜底。**当前值固定指向 R2 r2cdn 绝对地址**（唯一实测全绿的 zip 源，国内外均通）；
  等 Gitee Release 资产真正就绪后再考虑切换——**不要提前指向未就绪的通道**（如 Gitee Release / ModelScope），否则旧 app 下载 zip 会 404。
- `zipSha256`（新增，normalize 注入）：zip 的 SHA256，写入对应 zip 条目，供 app 端跨通道镜像校验（`expectSha256`）使用；旧端忽略。
- 图片/索引等相对 URL（`coverUrl`、`batches/batch_001.json`、`../images/101.webp`）保持相对，由 app 以 manifest 的 `baseUri` 递归解析。

---

## 2. 平台路径规则（已逐项实测）

| 平台 | 元数据(json/webp) base | zip 路径规则 | 本机(国内)实测 | 通道 id | 状态 |
|---|---|---|---|---|---|
| **Cloudflare R2**（自定义域） | `https://jigsawdata.umao.top/` | 同 base，`preserve` | ✅ 全绿 | `r2cdn` | 启用 |
| **Cloudflare R2**（r2.dev） | `https://pub-41cf228a…r2.dev/` | 同 base | ✅（限流，仅兜底） | `r2pub` | 启用 |
| **Gitee raw** | `https://gitee.com/macitee/jigsaw-data/raw/master/` | Release：`…/releases/download/{tag}/` + `flatten`(basename) | ✅ raw 通；Release 待上传（见 §7） | `gitee` | 启用 |
| **GitHub raw** | `https://raw.githubusercontent.com/mcxiaoke/jigsaw-data/master/` | Release(github)：`flatten` | raw 通；**release 连接被重置（cn=0，仅海外）** | `github` | 启用 |
| **ModelScope resolve** | `https://modelscope.cn/datasets/scocahh/jigsaw-data/resolve/master/` | zip 走 R2（`preserve`） | ❌ **暂时禁用**：token git push 鉴权异常 | `modelscope` | 禁用 |
| **jsDelivr(GitHub)** | `https://fastly.jsdelivr.net/gh/mcxiaoke/jigsaw-data@master/` | 无（不承载 zip） | 仅作 **manifest.json 路由 URL 备份** | `jsdelivr` | 备份 |

规则内涵：
- `preserve`：`base + key`（R2 两通道、ModelScope 的 zip 规则）。
- `flatten`：`base + basename(key)`（GitHub/Gitee Release 是扁平命名空间，无目录层级）。
- `{tag}` 占位符运行时替换为 `releaseTag`（见 §4）。
- `{branch}` 占位符：raw/gh 类 URL 模板统一用 `{branch}`（当前 `master`）显式记录分支名，
  避免仓库默认分支切换（如 GitHub main）时所有 raw/jsDelivr URL 全线 404。

---

## 3. 通道表 `channels.json`（唯一真源）

位于 `scripts/publish/channels.json`。

- `dist.root` = studio 原生导出 `out/`；`dist.stage` = normalize 后发布源；`dist.publishRoot` = 发布读取源（=stage）。
- `prefixSets.zip` = `["daily/zips/", "events/packs/", "collections/packs/"]`，rules 用 `set:"zip"` 引用，避免重复。
- `releaseTag` = **`assets`**（固定移动标签，不随内容版本变化 → 通道表里 zip base 永久稳定，改内容不用改通道表）。
- 每通道含 `cn`/`global` 排名（rank>0 启用，0 禁用；禁用通道不参与竞速与 zip 镜像合成）。
- **单源原则（修订）**：app 端种子表（`channel_config.dart` 内置一份）**仅作首启兜底**，
  以远端 `manifest.channels` 覆盖为准 → 新增/调整通道无需发版；
  远端 channels 需做**域名白名单校验**（仅允许已知域模式，防止内容仓被攻破后引导 app 到任意地址）。
- **jsDelivr 备份字段**：jsDelivr 不在内容通道参与排名，以独立字段（如 `manifestBackupUrls`）仅服务
  manifest 获取（`base + manifest.json`），作为内容通道竞速失败后的兜底路由。

### 国内外分流排序（已据实测调整）
- **cn**：`gitee(1)` → `r2cdn(2)` → `r2pub(3)`（ModelScope 禁用移除；jsDelivr 仅备份、GitHub Release 国内不可达，均 `cn=0`）。
- **global**：`r2cdn(1)` → `github(2)` → `gitee(3)` → `r2pub(4)`。

> R2 是唯一「json+图片+zip 同一 base、国内外均通」的通道，作为**全球统一兜底主力**。

---

## 4. 发布流程（依赖顺序 + 原子性）

关键原则：**先发 blob（zip）→ 再发 index.json → 最后发 manifest.json**，避免「半更新窗口」：
manifest 一旦发布，所有相对 URL 都在同一通道内自洽；跨通道只在 blob 兜底链里发生，而 blob 带 SHA256 且不可变（按 `-r{rev}` 命名），旧镜像失败由哈希校验拦截。

### normalize 阶段（含硬门禁）
`python publish.py normalize`：`out/` → `stage/`，注入 `zipKey`/`zipSha256`、下沉 `.gitattributes`，同时 **fail-fast 硬门禁**：
- **flatten 通道 zip basename 全局唯一性校验**：`daily/zips/` 与 `events/packs/` 等目录下可能出现同名 zip（如均为日期命名），
  flatten 后 basename 冲突会静默互相覆盖 → 在发布前拦截（verify 的冲突检测降级为复查兜底）；
- **zip 大小门禁**：Gitee Release 单文件上限约 100MB、仓库配额有限，超限即告警/中断。

### 发布编排器 `scripts/publish/publish.py`
```
python publish.py normalize     # out/ -> stage/：注入 zipKey/zipSha256、下沉 .gitattributes、硬门禁
python publish.py r2            # rclone 同步 stage/ -> r2:jigsaw-data（zip 用 --immutable 防覆盖）
python publish.py github        # 推 github + gh release 上传 zip（已实测成功）
python publish.py gitee         # 推 gitee + release 上传（gitee.exe 优先，见 §7）
python publish.py modelscope    # 【禁用中】token 鉴权异常，disabled 守卫自动跳过（代码保留）
python publish.py all           # 依次执行 r2→github→gitee（modelscope 因 disabled 自动跳过）
python publish.py verify        # 跨通道巡检（见 §5）
```
- **断点/幂等**：每个子命令均可重入；`all` 中途失败后补跑对应单步即可（建议 `all` 支持 `--skip/--only <channel>` 精确断点）。
- **幂等细节**：GitHub `gh release upload` 加 `--clobber`（已实现）；Gitee 同类上传前先确认覆盖策略。

### git 平台处理
- 不提交 zip 到 git（仓库膨胀）：`_prepare_git_repo` 把 stage 投影进临时 worktree，**排除 zip**，
  只推 json/webp；zip 走 Release（GitHub 用 `gh`，Gitee 用 gitee.exe 或 API，见 §7）。
- push 策略：先普通 push，失败则 `fetch` 建立 lease 基线后 `force-with-lease`，再失败回退 `--force`
  （发布仓库、内容由 dist 决定、可重发，安全）。已验证 GitHub / Gitee 推送成功。
- **凭据**：优先复用本机登录态/凭据管理器——GitHub 走 `gh auth login`，Gitee 走 gitee.exe 登录态；
  令牌**不嵌入 remote URL、不落盘**（避免进 `.git/config`）；多远程多凭据时用 per-URL 凭据配置区分。

### R2 处理
```
rclone copy stage r2:jigsaw-data --immutable --include '*.zip'
rclone copy stage r2:jigsaw-data --exclude '.gitattributes' --exclude '*.zip'
```
zip 用 `--immutable` 锁死（文件名含 `-r{rev}`，内容不可变）；json/webp 随版本更新允许覆盖。
**实测全部 56/56 key 可达、zip sha256 抽检一致。**

### ModelScope 特例（实现保留，通道挂起）
ModelScope 默认 `.gitattributes` 会把 `*.json/*.webp/*.zip` 全部塞进 LFS，app 会拉到指针文本。
解决：dist 根放一份 `.gitattributes` 关闭 LFS（`*.json -filter …`），并由 `inheritAttributes` 下沉到每个
模块目录（ModelScope 按目录生效规则）。
**当前通道禁用**（token git push 返回 HTTP Basic Access denied，属令牌/服务端问题）；
上述实现与通道表条目均保留，令牌问题修复后按 §7 恢复即可。

---

## 5. 跨通道巡检 `verify_channels.py`

对每个启用通道，把 dist 全部 key 展开成真实 URL 并发抽检：
- 可达性（HEAD/GET）；zip 做 **sha256 抽检**与本地一致；
- `flatten` 通道 basename 冲突检测（normalize 已硬门禁，此处为复查兜底）；
- 每个 zip 至少在一个已发布通道可达；
- `.gitattributes` 有意不进 R2，已从校验 key 空间排除。
- **门禁语义（建议）**：引入 `publish_state.json` 记录每通道最近成功发布时间，区分
  「预期失败」（未发布/禁用，仅提示）与「回归失败」（已发布通道 zip 不可达，红灯中断），
  使 verify 能真正作为每次发布的 CI 门禁而不误报。

实测（2026-09-08，国内本机）：
```
[r2cdn] OK  ok=56/56  zip_fail=0
[r2pub] OK  ok=56/56  zip_fail=0
[gitee]  raw OK；Release 资产未上传 zip_fail=<N>   ← 待 §7 补齐
[github] raw OK；Release 国内不可达（cn=0，预期）
[modelscope] 禁用中（不巡检）
[jsdelivr] 仅 manifest 备份（不参与内容巡检）
```
结论：**已发布的 R2 两通道完全通过**；gitee 的 zip 失败是「Release 未上传」的预期结果，
待 §7 补齐后归零；verify 按「预期失败/回归失败」分级报告，可作 CI 门禁。

---

## 6. app 端方案（参考实现在 `scripts/publish/app_reference/`）

不修改现有 Flutter 代码的前提下，新增「通道解算 + 竞速选路 + 主备切换」：

1. **`channel_config.dart`** — 通道表 + `keyToUrl(key, tag)` 解算（与 `assetmap.py` 语义一致）；
   内置种子表**仅作首启兜底**，以远端 `manifest.channels` 覆盖为准（数据驱动新增/调整平台），
   覆盖内容做**域名白名单校验**。
2. **`content_selector.dart`** — `SourceSelector`：
   - **竞速选路**：首启并行请求各**启用内容通道**的 manifest，先到先用（取代原 4s 顺序轮询，显著缩短首启）；
     jsDelivr 等备份路由不参与竞速，仅在全部内容通道失败时按序兜底尝试。
   - **粘性缓存**：选中通道按区域写入磁盘，后续启动直连，不竞速。
   - **熔断/重竞速**：粘性通道连续失败则重新竞速（自适应网络变化）。
3. **`buildZipMirrors(item, resolver)`** — 若 item 带 `zipKey`，用通道表合成多平台镜像列表；
   否则退回 JSON 自带 `zipUrl/zipUrls`（旧端兼容）。
   **镜像顺序 = 通道 rank 升序 + 失败依次回退，不依赖 region 参数**（manifest 层竞速已隐式完成区域判别）。
4. **SHA256 兜底校验** — `ContentHttpClient.downloadFile` 增加可选 `expectSha256`（来源：normalize 注入的 `zipSha256`），
   失败即触发 `downloadFileWithMirrors` 的下一个镜像（现有镜像回退逻辑复用）。
5. **`integrations.dart`** — 最小改动清单（ManifestRouter 注入 resolver、ContentManager 透传、
   pipelines 改用 `buildZipMirrors` + 校验），旧版 app（无 zipKey 支持）仍走 `zipUrl` 兼容。

> 图片/索引等相对 URL 仍由现有 `ManifestRouter` 以 `baseUri` 递归解析，**天然随选中通道切换**；
> 唯一新增的是 zip 按通道规则解析（因为不同平台 zip 路径规则不同）。这正是引入 `zipKey` 的意义。

---

## 7. 待补齐项

1. **Gitee Release 上传**（cn zip 主力）：
   - **方案 A（优先）**：`gitee.exe` 登录态完成 release 资产上传（本机已验证可用），无需 API 令牌；
   - **方案 B（兜底）**：`GITEE_TOKEN` + `python scripts/publish/gitee_publish.py`，或网页手动上传 `stage/` 下 zip 到 tag assets。
   - Git push 已用 Windows 凭据成功；仅 Release 资产上传按上述方案补齐。
2. **ModelScope**：**暂时禁用**。其 token git push 鉴权异常（实测 HTTP Basic Access denied），
   属令牌/服务端问题而非脚本问题；修复后**移除 `channels.json` 中 modelscope 通道的 `disabled: true` 标记**，
   再执行 `python publish.py modelscope` 恢复三平台→四平台。
3. **可选**：阶段二让 ModelScope 承载 zip（单独 LFS worktree）；以及 json/webp 带 `-r{rev}` 目录隔离、
   manifest 纯指针切换的原子回滚演进（见 §8 回滚 SOP）。

当前**无需令牌即可工作的分发能力**：R2（国内外全栈，已全量发布并通过巡检）、
GitHub（已发布，海外可用）、Gitee raw（已推送，国内元数据可用，仅 release zip 待 §7-1 补齐）。

---

## 8. 风险与权衡

- **固定 `assets` 标签**：通道表 zip base 永久稳定；内容更新靠 `-r{rev}` 文件名不可变 + CDN 长缓存。
  代价：Release 资产只追加不删 → **配额累积**（Gitee 单文件约 100MB/仓库 1GB、GitHub 单文件上限大但仓库同样膨胀）。
  用 normalize 大小门禁 + 定期归档清理策略控制；清理会破坏不可变 URL 承诺，仅在明确归档时执行。
- **R2 作为全球兜底**：单点依赖 Cloudflare，但国内外均通、成本低；多域（`umao.top` + `r2.dev`）降低风险。
  R2 免费读流量有额度，`-r{rev}` 不可变命名 + CDN 长缓存已显著缓解。
- **GitHub Release 国内不可达**：已 `cn=0` 禁用，仅海外启用；zip 国内改走 gitee/R2。
- **jsDelivr 仅作 manifest 备份**：不承载 zip/json/webp 内容分发——规避其 `@branch` 缓存延迟
  （push 后新文件数小时内不可见）与「不能加速 Release 资产」的局限；只把 manifest 获取作为兜底路由。
- **分支名占位符 `{branch}`**：所有 raw/jsDelivr URL 模板显式用 `{branch}`，仓库默认分支切换（如 GitHub master→main）时不至于全线 404。
- **安全性**：发布脚本自有令牌通过 `GIT_ASKPASS` 注入，不落在进程参数；**优先 gh auth / gitee.exe 登录态**，令牌不嵌 URL、不落盘；
  force 仅作用于发布仓库的同名分支。
- **回滚 SOP**：json/webp 为覆盖式发布——回滚 = 发布仓库 git 历史 checkout 旧 rev → 重新 normalize →
  重发对应通道（r2/github/gitee）→ verify；Release zip 因不可变命名天然可回滚。
  **可选演进**：json/webp 也按 `-r{rev}` 目录隔离、manifest 只做指针切换，实现发布即原子切换、零覆盖回滚（改造量中等，收益大，阶段二评估）。

---

## 9. 一句话总结

> 内容只产一次（相对 canonical key），平台差异全部进 `channels.json`（R2、GitHub、Gitee 三活动通道 + jsDelivr 仅 manifest 备份）；
> 发布侧用 `publish.py` 一键多平台分发并 `verify` 巡检；
> app 端用同一通道表竞速选路 + `zipKey` 合成多镜像 + SHA256 校验，实现国内外分流与主备自动切换。