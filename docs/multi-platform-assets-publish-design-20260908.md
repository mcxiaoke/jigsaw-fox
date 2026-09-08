# jigsaw-data 多平台 Assets 发布与分发方案（设计 + 验证）

> 日期：2026-09-08 ｜ 状态：方案已落地并实测（R2 全通道通过，GitHub 已发布，Gitee/ModelScope 待令牌补齐）
> 配套脚本：`temp/publish/`（发布编排、通道表、跨通道巡检、app 端 Dart 参考实现）
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
- `zipUrl` / `zipUrls`（保留）：旧端兜底。当前值为 gitee release 绝对地址（旧 app 可直接用）。
- 图片/索引等相对 URL（`coverUrl`、`batches/batch_001.json`、`../images/101.webp`）保持相对，由 app 以 manifest 的 `baseUri` 递归解析。

---

## 2. 平台路径规则（已逐项实测）

| 平台 | 元数据(json/webp) base | zip 路径规则 | 本机(国内)实测 | 通道 id |
|---|---|---|---|---|
| **Cloudflare R2**（自定义域） | `https://jigsawdata.umao.top/` | 同 base，`preserve` | ✅ 全绿 | `r2cdn` |
| **Cloudflare R2**（r2.dev） | `https://pub-41cf228a…r2.dev/` | 同 base | ✅（限流，仅兜底） | `r2pub` |
| **Gitee raw** | `https://gitee.com/macitee/jigsaw-data/raw/master/` | Release：`…/releases/download/{tag}/` + `flatten`(basename) | ✅ raw 通；release 待令牌 | `gitee` |
| **ModelScope resolve** | `https://modelscope.cn/datasets/scocahh/jigsaw-data/resolve/master/` | zip 走 R2（`preserve`，阶段一无 zip） | ✅ json 可达；zip 待后续 | `modelscope` |
| **jsDelivr(GitHub)** | `https://fastly.jsdelivr.net/gh/mcxiaoke/jigsaw-data@master/` | Release(github)：`flatten` | raw 通；release 国内不通 | `jsdelivr` |
| **GitHub raw** | `https://raw.githubusercontent.com/mcxiaoke/jigsaw-data/master/` | Release(github)：`flatten` | raw 通；**release 连接被重置** | `github` |

规则内涵：
- `preserve`：`base + key`（R2 两通道、ModelScope 的 zip 规则）。
- `flatten`：`base + basename(key)`（GitHub/Gitee Release 是扁平命名空间，无目录层级）。
- `{tag}` 占位符运行时替换为 `releaseTag`（见 §4）。

---

## 3. 通道表 `channels.json`（唯一真源）

位于 `temp/publish/channels.json`，发布脚本与 app 端**各持一份语义一致的定义**（app 端见
`temp/publish/app_reference/channel_config.dart`；远端 manifest 也可携带 `channels` 覆盖种子表，实现数据驱动新增平台而无需发版）。

结构要点：
- `dist.root` = studio 原生导出 `out/`；`dist.stage` = normalize 后发布源；`dist.publishRoot` = 发布读取源（=stage）。
- `prefixSets.zip` = `["daily/zips/", "events/packs/", "collections/packs/"]`，rules 用 `set:"zip"` 引用，避免重复。
- `releaseTag` = **`assets`**（固定移动标签，不随内容版本变化 → 通道表里 zip base 永久稳定，改内容不用改通道表）。
- 每通道含 `cn`/`global` 排名（rank>0 启用，0 禁用）。

### 国内外分流排序（已据实测调整）
- **cn**：`gitee(1)` → `r2cdn(2)` → `modelscope(3)` → `r2pub(4)`（jsdelivr/github 因 release 国内不可达，`cn=0` 禁用）。
- **global**：`r2cdn(1)` → `jsdelivr(2)` → `github(4)` → `gitee(3)` → `r2pub(5)`。

> R2 是唯一「json+图片+zip 同一 base、国内外均通」的通道，作为**全球统一兜底主力**。

---

## 4. 发布流程（依赖顺序 + 原子性）

关键原则：**先发 blob（zip）→ 再发 index.json → 最后发 manifest.json**，避免「半更新窗口」：
manifest 一旦发布，所有相对 URL 都在同一通道内自洽；跨通道只在 blob 兜底链里发生，而 blob 带 SHA256 且不可变（按 `-r{rev}` 命名），旧镜像失败由哈希校验拦截。

### 发布编排器 `temp/publish/publish.py`
```
python publish.py normalize     # out/ -> stage/：注入 zipKey、下沉 .gitattributes
python publish.py r2            # rclone 同步 stage/ -> r2:jigsaw-data（zip 用 --immutable 防覆盖）
python publish.py github        # 推 github + gh release 上传 zip（已实测成功）
python publish.py gitee         # 推 gitee + Release（需 GITEE_TOKEN，见 §7）
python publish.py modelscope    # 推 modelscope 镜像（需 MODELSCOPE_TOKEN，见 §7）
python publish.py all           # 依次执行以上（r2→github→gitee→modelscope）
python publish.py verify        # 跨通道巡检（见 §5）
```

### git 平台处理
- 不提交 zip 到 git（仓库膨胀）：`_prepare_git_repo` 把 stage 投影进临时 worktree，**排除 zip**，
  只推 json/webp；zip 走 Release（GitHub 用 `gh`，Gitee 用 API+令牌）。
- push 策略：先普通 push，失败则 `fetch` 建立 lease 基线后 `force-with-lease`，再失败回退 `--force`
  （发布仓库、内容由 dist 决定、可重发，安全）。已验证 GitHub / Gitee 推送成功。

### R2 处理
```
rclone copy stage r2:jigsaw-data --immutable --include '*.zip'
rclone copy stage r2:jigsaw-data --exclude '.gitattributes' --exclude '*.zip'
```
zip 用 `--immutable` 锁死（文件名含 `-r{rev}`，内容不可变）；json/webp 随版本更新允许覆盖。
**实测全部 56/56 key 可达、zip sha256 抽检一致。**

### ModelScope 特例（LFS 覆盖）
ModelScope 默认 `.gitattributes` 会把 `*.json/*.webp/*.zip` 全部塞进 LFS，app 会拉到指针文本。
解决：dist 根放一份 `.gitattributes` 关闭 LFS（`*.json -filter …`），并由 `inheritAttributes` 下沉到每个
模块目录（ModelScope 按目录生效规则）。阶段一只镜像 json+webp，zip 经 rules 指向 R2。

---

## 5. 跨通道巡检 `verify_channels.py`

对每个启用通道，把 dist 全部 key 展开成真实 URL 并发抽检：
- 可达性（HEAD/GET）；zip 做 **sha256 抽检**与本地一致；
- `flatten` 通道 basename 冲突检测；
- 每个 zip 至少在一个已发布通道可达；
- `.gitattributes` 有意不进 R2，已从校验 key 空间排除。

实测（2026-09-08，国内本机）：
```
[r2cdn] OK  ok=56/56  zip_fail=0
[r2pub]  OK  ok=56/56  zip_fail=0
[gitee]   FAIL zip_fail=11   ← raw 已通，Release 资产未上传（待令牌）
[github/jsdelivr/modelscope] FAIL zip_fail=11 ← 相应 Release/zip 未发布或国内不可达
```
结论：**已发布的 R2 两通道完全通过**；其余通道的 zip 失败正是「尚未发布/国内不可达」的预期结果，
脚本能正确区分并报告，可作为每次发布的 CI 门禁。

---

## 6. app 端方案（参考实现在 `temp/publish/app_reference/`）

不修改现有 Flutter 代码的前提下，新增「通道解算 + 竞速选路 + 主备切换」：

1. **`channel_config.dart`** — 通道表 + `keyToUrl(key, tag)` 解算（与 `assetmap.py` 语义一致）；
   种子表可被远端 `manifest.channels` 覆盖（数据驱动新增平台）。
2. **`content_selector.dart`** — `SourceSelector`：
   - **竞速选路**：首启并行请求各通道 manifest，先到先用（取代原 4s 顺序轮询，显著缩短首启）。
   - **粘性缓存**：选中通道按区域写入磁盘，后续启动直连，不竞速。
   - **熔断/重竞速**：粘性通道连续失败则重新竞速（自适应网络变化）。
3. **`buildZipMirrors(item, resolver, region)`** — 若 item 带 `zipKey`，用通道表合成多平台镜像列表；
   否则退回 JSON 自带 `zipUrl/zipUrls`（旧端兼容）。
4. **SHA256 兜底校验** — `ContentHttpClient.downloadFile` 增加可选 `expectSha256`，失败即触发
   `downloadFileWithMirrors` 的下一个镜像（现有镜像回退逻辑复用）。
5. **`integrations.dart`** — 最小改动清单（ManifestRouter 注入 resolver、ContentManager 透传、
   pipelines 改用 `buildZipMirrors` + 校验），旧版 app（无 zipKey 支持）仍走 `zipUrl` 兼容。

> 图片/索引等相对 URL 仍由现有 `ManifestRouter` 以 `baseUri` 递归解析，**天然随选中通道切换**；
> 唯一新增的是 zip 按通道规则解析（因为不同平台 zip 路径规则不同）。这正是引入 `zipKey` 的意义。

---

## 7. 待补齐项（需用户提供令牌，非阻塞）

1. **Gitee Release 上传**（cn zip 主力之一）：
   ```
   set GITEE_TOKEN=xxxx
   python temp/publish/gitee_publish.py          # 推 git + 建 tag=assets + 上传 11 个 zip
   # 或仅在网页手动上传 stage/ 下 11 个 zip 到 tag assets
   ```
   Git push 已用 Windows 凭据成功；仅 Release 上传需 API 令牌（实测 API 401）。
2. **ModelScope 推送**（需 `MODELSCOPE_TOKEN`）：
   ```
   set MODELSCOPE_TOKEN=xxxx
   python temp/publish/publish.py modelscope
   ```
   当前 modelscope git push 因缺令牌鉴权失败（实测 HTTP Basic Access denied）。
3. **可选**：阶段二让 ModelScope 也承载 zip（单独 LFS worktree）。

当前**无需令牌即可工作的分发能力**：R2（国内外全栈，已全量发布并通过巡检）、
GitHub（已发布，海外可用）、Gitee raw（已推送，国内元数据可用，仅 release zip 待令牌）。

---

## 8. 风险与权衡

- **固定 `assets` 标签**：通道表 zip base 永久稳定；内容更新靠 `-r{rev}` 文件名不可变 + CDN 长缓存。
  代价：Release 资产只追加不删（可接受，自然归档）。
- **R2 作为全球兜底**：单点依赖 Cloudflare，但国内外均通、成本低；多域（`umao.top` + `r2.dev`）降低风险。
- **GitHub Release 国内不可达**：已 `cn=0` 禁用，仅海外启用；zip 国内改走 gitee/R2。
- **jsDelivr 不加速 Release**：zip 在国内实际走 gitee/R2，jsDelivr 仅服务 json/webp 海外加速。
- **安全性**：发布脚本通过 `GIT_ASKPASS` 注入令牌，不落在进程参数；force 仅作用于发布仓库的同名分支。

---

## 9. 一句话总结

> 内容只产一次（相对 canonical key），平台差异全部进 `channels.json`；
> 发布侧用 `publish.py` 一键多平台分发并 `verify` 巡检；
> app 端用同一通道表竞速选路 + `zipKey` 合成多镜像 + SHA256 校验，实现国内外分流与主备自动切换。
