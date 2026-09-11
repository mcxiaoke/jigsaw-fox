# jigsaw-data 三平台发布流程方案（R2 主 / GitHub·Gitee 备）

> 日期：2026-09-10 ｜ 状态：**方案待确认，尚未实施**（本轮不改动任何代码与仓库）
> 输入：`F:\Pictures\JigsawGame\Output`（studio 导出，**只读，任何阶段不得写入**）
> 发布源：`F:\Pictures\JigsawGame\jigsaw-data`（git 工作副本 = stage，同时充当 rclone 源）
> 输出：R2 / GitHub / Gitee 三平台可直接给 Flutter app 消费的 CDN 地址
> 关联：`docs/multi-platform-assets-publish-design-20260908.md`（旧方案，本文取代其中通道与流程部分）

---

## 0. 结论摘要

1. **zip 的主备切换在发布侧解决，app 端零改动**。
   app 三个 pipeline（daily / events / collections）已实现 `downloadFileWithMirrors([zipUrl, ...zipUrls])`
   镜像回退（`lib/logic/content/pipelines/*.dart` + `content_http_client.dart:177`）。
   因此发布侧把 `zipUrl` 写成 **R2 绝对地址**、`zipUrls` 写成 `[R2, GitHub Release, Gitee Release]`，
   即可实现「R2 为主、其它为备」，**无需把 `channel_config.dart` 接入 `lib/`**。
2. **repo 工作副本即发布源**。`Output` → 拷贝到 repo → 在 repo 内改写 URL → repo 同时作为
   rclone 源（含 zip）与 git 提交源（zip 被 `.gitignore` 排除）。一份目录、两条发布路径。
3. **zip 不进 git，靠 `zipSha256` 间接留底**。zip 本身不入库，但每个 zip 的 SHA256 写在
   `index.json` 里随 git 提交，历史可追溯、可校验。
4. **每通道 URL 规则不同，但只在 zip 上有差异**：json/图片/cover 三通道都是 `base + 相对 key`
   （preserve），zip 在 R2 是 `base + key`，在 GitHub/Gitee 是 Release 扁平 `base + basename`。

---

## 1. 目录角色定义

| 路径 | 角色 | 是否可写 | 说明 |
|---|---|---|---|
| `F:\Pictures\JigsawGame\Output` | 输入源（dist） | **只读** | studio 导出产物，213 文件 / 124MB，全部相对 URL |
| `F:\Pictures\JigsawGame\jigsaw-data` | 发布源（stage / repo） | 可写 | git 工作副本；含 `.git`、`README.md`、`.gitignore` |
| `r2:jigsaw-data` | R2 桶 | 远端 | 通过自定义域 `https://jigsawdata.umao.top/` 对外 |
| `origin`(GitHub) / `gitee` | git 远端 | 远端 | 各持有 `master` 与 `release` 分支 |

`.gitignore`（repo 根，需新建）：

```gitignore
*.zip
.dl_check/
.ms_upload_cache/
_*/
```

> 说明：`*.zip` 让 git 忽略全部 zip；rclone 不受 `.gitignore` 影响，
> 因此同一份目录「git 只提交 json+webp，rclone 同步 json+webp+zip」。

---

## 2. URL 规则矩阵

| 内容 | R2（主） | GitHub（备） | Gitee（备） |
|---|---|---|---|
| 客户端入口 | `https://jigsawdata.umao.top/release/manifest-release.json` | `https://raw.githubusercontent.com/mcxiaoke/jigsaw-data/<branch>/release/manifest-release.json` | `https://gitee.com/macitee/jigsaw-data/raw/<branch>/release/manifest-release.json` |

> 三通道统一带 `release/` 前缀（见 §12）：R2 只同步 `release/` 子目录，根目录保持干净。
> 入口文件名是 `manifest-release.json`（不是 `manifest.json`）——后者是 Output 原样副本，
> 未经处理，不供客户端使用。
| 模块 json / 图片 / cover | `base + key`（preserve） | `base + key`（preserve） | `base + key`（preserve） |
| **zip** | `base + key`（preserve，桶内真实存在） | `https://github.com/mcxiaoke/jigsaw-data/releases/download/<tag>/<basename>`（flatten） | `https://gitee.com/macitee/jigsaw-data/releases/download/<tag>/<basename>`（flatten） |

- `<branch>`：`master`（测试）或 `release`（正式）。
- `<tag>`：`v1.0.0`（本轮起用语义化版本，与 app 版本解耦）。
- **flatten 风险**：Release 是扁平命名空间，`daily/zips/` 与 `events/packs/` 若出现同名 zip
  会静默互相覆盖。发布前必须做 basename 全局唯一性门禁（当前 14 个 zip 无冲突）。

---

## 3. zip 字段改写规范（本方案核心）

`Output` 里 zip 条目现状（以 daily 为例）：

```json
{ "month": "202609", "zipUrl": "zips/202609.zip", "zipSha256": "59d8edf4…", "revision": 1 }
```

改写后（在 repo 工作副本内完成）：

```json
{
  "month": "202609",
  "zipKey": "daily/zips/202609.zip",
  "zipUrl": "https://jigsawdata.umao.top/daily/zips/202609.zip",
  "zipUrls": [
    "https://jigsawdata.umao.top/daily/zips/202609.zip",
    "https://gitee.com/macitee/jigsaw-data/releases/download/v1.0.0/202609.zip",
    "https://github.com/mcxiaoke/jigsaw-data/releases/download/v1.0.0/202609.zip"
  ],
  "zipSha256": "59d8edf4…",
  "revision": 1
}
```

规范：

- `zipKey`（新增）：相对 repo 根的 canonical key，供后续脚本/校验使用，app 端暂不消费（**确认保留**）。
- `zipUrl`（改写为绝对）：**主地址固定指向 R2**，这是「R2 为主」的落点。
- `zipUrls`（新增）：主备顺序 **`[R2, Gitee, GitHub]`**（已确认）—— 国内 GitHub Release 实测连接被重置，
  故 Gitee 排在前；海外由 R2 直连，第三顺位几乎用不到。app 端按序回退。
- **其余相对 URL 一律不动**（`coverUrl`、`url`、main 的 `batches/…/index.json` 与 `images/*.webp`），
  由 app 端 `ContentHttpClient.resolveUrl(baseUri, 相对)` 递归解析，天然跟随 manifest 所在通道。
- 同时在 manifest 顶层注入 `mirrors` 与 `bootstrapUrls`（见 §11），
  为 json / 图片 / cover 提供主备镜像（可选字段，旧 App 忽略即可）。
- 改写后**必须重算各 `index.json` 的 sha256 并回写 `manifest.json.modules.<m>.hash`**，
  否则 app 端 hash 校验会失败。

> 为什么 `zipUrls` 用绝对地址：app 端 pipeline 会对 `zipUrls` 再跑一次 `resolveUrl`，
> 绝对地址 resolve 后原样返回，安全；相对地址则会跟随通道解析到不存在的路径（zip 不在仓库里）。

---

## 4. 分支与 tag 策略

```
master                     ← 测试发布：全通道发布，用于验证
  │  (验证通过后 fast-forward)
  ▼
release                    ← 正式发布：仅 merge + 打 tag，内容不变
  │
  └─ tag v1.0.0            ← 移动标签，Release 资产挂在此 tag
```

- **测试发布**：在 `master` 上走完整流程（含 R2 同步），用测试版 app 验证。
- **正式发布**：`git merge --ff-only master` 到 `release`，push，然后 `git tag -f v1.0.0` + push tag。
  因为 fast-forward 保证内容一致，**R2 侧无需二次同步**。
- **app 端 bootstrap 指向**（数据准备就绪后再改，属最小改动范围）：

```dart
static const List<String> defaultBootstrapUrls = [
  'https://jigsawdata.umao.top/release/manifest-release.json',                             // R2 主
  'https://gitee.com/macitee/jigsaw-data/raw/master/release/manifest-release.json',        // 备 1（国内）
  'https://raw.githubusercontent.com/mcxiaoke/jigsaw-data/master/release/manifest-release.json', // 备 2（海外）
];
```

> 注意：jsDelivr 与 r2.dev 已从通道中移除（前者缓存延迟、后者限流且非生产用途）。

---

## 5. 发布流程（7 步）

### Step 1 — sync：`Output` → repo 工作副本

清空 repo 内 `main/`、`daily/`、`events/`、`collections/`、`manifest.json`（保留 `.git`、`README.md`、
`.gitignore`），再把 `Output` 全部内容（**含 zip**）拷贝进去。

```bash
python publish.py sync
```

### Step 2 — prepare：改写 URL + 本地门禁

- 注入 `zipKey`、改写 `zipUrl` 为 R2 绝对地址、注入 `zipUrls` 主备列表；
- 重算各模块 `index.json` 的 sha256 → 回写 `manifest.json.modules.<m>.hash`；
- 硬门禁（任一失败即中断）：
  1. zip basename 全局唯一（flatten 冲突）；
  2. 每个 `zipKey` 在磁盘上真实存在；
  3. 每个 zip 条目都有 `zipSha256`；
  4. Gitee Release 单文件 < 100MB。

```bash
python publish.py prepare --tag v1.0.0
```

### Step 3 — r2：同步到 R2（主通道）

```bash
rclone copy F:\Pictures\JigsawGame\jigsaw-data r2:jigsaw-data ^
  --exclude ".git/**" --exclude ".gitignore" --exclude "README.md" ^
  --exclude ".dl_check/**" --exclude ".ms_upload_cache/**" --progress
```

- **方案 A（已定）**：不使用 `--immutable`，允许同名覆盖；R2 缓存已在 Cloudflare 配 1 个月，
  有问题手动 purge。**不使用 `rclone --delete`**，防止误删线上数据。
- 孤儿文件（如已下架的旧 zip）由独立 GC 命令带 dry-run 确认后清理。

```bash
python publish.py r2
```

### Step 4 — git：提交 + 推送分支

```bash
git -C F:\Pictures\JigsawGame\jigsaw-data add -A
git -C F:\Pictures\JigsawGame\jigsaw-data commit -m "publish assets v1.0.0"
git -C F:\Pictures\JigsawGame\jigsaw-data push origin master
git -C F:\Pictures\JigsawGame\jigsaw-data push gitee  master
```

（正式发布时先切 `release` 分支 merge，再 push 两个远端。）

> **历史留底**：每次发布一个 commit，zip 的 SHA256 随 `index.json` 入库。
> 回滚 = `git checkout <旧 commit>` 到临时目录 → 重新走 Step 2~7。

### Step 5 — release：上传 zip 到 Release（扁平命名空间）

```bash
gh release create v1.0.0 --title "assets v1.0.0" --notes "jigsaw-data assets (zip packs)" --latest
gh release upload v1.0.0 ^
  F:\Pictures\JigsawGame\jigsaw-data\daily\zips\*.zip ^
  F:\Pictures\JigsawGame\jigsaw-data\events\packs\*.zip ^
  F:\Pictures\JigsawGame\jigsaw-data\collections\packs\*.zip --clobber
```

- GitHub：`gh` 已登录（`mcxiaoke`），`--clobber` 保证幂等。
- Gitee：`gitee.exe`（Gitee CLI v0.3.0，已登录 `macitee`）**有 `release create/view/list/delete`，
  但没有 `release upload` 子命令**，附件必须走 OpenAPI：

```bash
# 1) 建 release（幂等：已存在则跳过）
gitee release create --tag v1.0.0 -n "assets v1.0.0" -b "jigsaw-data assets (zip packs)" -R macitee/jigsaw-data

# 2) 取 release_id
gitee api /repos/macitee/jigsaw-data/releases/tags/v1.0.0 -q        # -> {"id": <release_id>, ...}

# 3) 逐个上传附件（form 字段 file）
POST /repos/macitee/jigsaw-data/releases/<release_id>/attach_files
```

  第 3 步用 Python（urllib multipart）实现，token 由 `gitee auth token` **运行时获取、不落盘**
  （已实测可取到 token）。即 `gitee_publish.py` 改造点：
  - token 优先 `gitee auth token`，回退 `GITEE_TOKEN` 环境变量；
  - 上传路径改用 `/releases/{release_id}/attach_files`（release_id 由 tags 接口解析，
    现有代码直接用 `{tag}` 可能 404）；
  - 上传前先列已有附件，同名则先 DELETE 再 POST（覆盖语义，配合方案 A）。

```bash
python publish.py release --tag v1.0.0
```

### Step 6 — tag（正式发布时）

```bash
git tag -f v1.0.0
git push -f origin refs/tags/v1.0.0
git push -f gitee  refs/tags/v1.0.0
```

### Step 7 — verify：三通道全量巡检（严谨模式，已确认）

**校验口径（不做抽样，全部实测）**：

| 内容 | 校验项 | 失败判定 |
|---|---|---|
| 全部 json（manifest + 4 模块 index + 全部 batch index） | 三通道逐个 GET 200 + 下载后 sha256 与本地文件逐一比对 | 任一通道 404 或 hash 不一致 → FAIL |
| 全部 zip | 三通道逐个 GET 200 + 下载后 sha256 与 `zipSha256` 字段比对 | 主通道（R2）失败 → FAIL；备通道失败 → WARN |
| 全部 webp（cover + main 图片） | 三通道逐个 GET 200 + Content-Type 为 image/* | 主通道失败 → FAIL |
| zip 字段契约 | `zipUrl` 为绝对地址；`zipUrls` 非空且首项 == `zipUrl`；全部项绝对地址 | 不满足 → FAIL |
| flatten 冲突 | 全部 zip basename 全局唯一 | 冲突 → FAIL |
| manifest hash | 各模块 `index.json` 的 sha256 == `manifest.modules.<m>.hash` | 不一致 → FAIL |

- 输出：终端表格 + `--json report.json` 结构化报告；FAIL 时退出码非 0，可作发布门禁。
- 规模估算（当前数据）：json 7×3 + webp 192×3 + zip 14×3 ≈ 639 请求，zip 全量约 60MB×3。
  并发 16 线程；如需加速可 `--zip-sample N` 降级为 zip 抽检（默认全量）。
- **门禁语义**：主通道（R2）任何一项失败即中断发布流程；备通道（Gitee / GitHub）
  失败降级为 WARN 并打印清单，不阻断（Gitee Release 未上传属预期）。

```bash
python publish.py verify
python publish.py verify --json report.json --strict   # 备通道失败也 FAIL
```

一键串联：

```bash
python publish.py all --branch master --tag v1.0.0
```

### Step 8 — 客户端契约验证（Flutter，发布后执行）

`verify` 只保证「URL 可达 + 内容一致」，不保证「app 端模型能消费」。因此增加一层 Dart 测试，
用 App 真实的网络客户端（`ContentHttpClient`）与数据模型消费三平台 URL：

- 文件：`test/logic/jigsawdata_three_channel_verify_test.dart`
- 覆盖：三通道 × （manifest → 4 模块 index → main 批次/关卡 → daily/events/collections 条目）
  全链路解析不抛错；图片抽查可达；zip 主地址下载为合法 zip 且字节数与 `fileSizeBytes` 一致；
  `zipUrls` 每个镜像逐个可达。
- 默认跳过（不依赖外网），显式开启：

```bash
flutter test test/logic/jigsawdata_three_channel_verify_test.dart --dart-define=CHANNELS_VERIFY=true
flutter test test/logic/jigsawdata_three_channel_verify_test.dart \
  --dart-define=CHANNELS_VERIFY=true --dart-define=CHANNELS_BRANCH=master   # 测 master 分支
flutter test test/logic/jigsawdata_three_channel_verify_test.dart \
  --dart-define=CHANNELS_VERIFY=true --dart-define=CHANNELS_FULL_ZIP=true   # zip 全量下载校验
```

> 旧的 `test/logic/jigsawdata_remote_verify_test.dart` 绑定的是旧数据契约
> （GitHub Release 绝对 zipUrl / main 30 关 / 关卡 url 为 `../images/`），与新结构已不符，
> 建议废弃并由本测试取代（见 §10-7）。

---

## 6. 测试发布 vs 正式发布

| 环节 | 测试（master） | 正式（release） |
|---|---|---|
| sync / prepare | 同 | 同（内容不变时不重跑） |
| R2 同步 | ✅ 执行 | ❌ 跳过（ff merge 保证内容一致） |
| git push | `master` | `release`（ff merge 自 master） |
| Release zip 上传 | 可选（可只传 GitHub） | ✅ 两平台都传 |
| tag | 不打 | `v1.0.0` |
| app 指向 | `master` raw + R2 | `release` raw + R2 |

---

## 7. 回滚 SOP

zip 为覆盖式发布（方案 A），回滚依赖 git 历史：

1. `git log --oneline release` 找到目标 commit；
2. `git worktree add` 或 `git checkout <commit>` 到临时目录（得到当时的 json+webp）；
3. 从 R2 或本地归档取回对应 zip（若无归档则需 studio 重导）；
4. 以该临时目录为发布源重跑 Step 2~7；
5. R2 若命中缓存，手动 purge 受影响 key。

> 风险提示：zip 覆盖式发布下，**旧 tag 的 json 可能指向已被新内容覆盖的 zip 名**。
> 规避：正式发布后不要在同一 zip 名上重导不同内容；确需变更时 studio 会自动加 `-r{rev}` 后缀。

---

## 8. 现有脚本改造清单

| 文件 | 动作 | 说明 |
|---|---|---|
| `scripts/publish/channels.json` | **重写** | 只保留 `r2cdn` / `github` / `gitee`；删除 `modelscope`、`jsdelivr`、`r2pub`；`releaseTag=v1.0.0`；新增 `repo` 路径与 `branch` 配置 |
| `scripts/publish/normalize.py` | **重写为 `prepare` 语义** | 从「注入 zipKey」改为「注入 zipKey + 改写 zipUrl 绝对 + 注入 zipUrls + 重算 manifest hash + 硬门禁」 |
| `scripts/publish/publish.py` | **改造** | 子命令改为 `sync / prepare / r2 / git / release / verify / all`；新增 `--branch`、`--tag` 参数；删除 modelscope 分支 |
| `scripts/publish/verify_channels.py` | 保留改造 | 通道减为 3；zip 校验改用绝对 `zipUrls` 而非规则展开 |
| `scripts/publish/assetmap.py` | 保留 | key↔URL 解算逻辑不变（发布侧仍可复用） |
| `scripts/publish/app_reference/*` | **暂不接入** | `channel_config.dart` 等保持在 `app_reference/`，本方案不需要 |
| `scripts/publish/gitee_publish.py` | **改造** | token 改用 `gitee auth token`；上传路径改用 `releases/{id}/attach_files`；同名附件先删后传 |
| `test/logic/jigsawdata_three_channel_verify_test.dart` | **新增（已建）** | 客户端契约验证：三通道 × 真实模型解析 + zip 主备可达性 |
| `test/logic/jigsawdata_remote_verify_test.dart` | **待废弃** | 绑定旧数据契约，由新测试取代（§10-7 待确认） |
| `lib/logic/content/app_content.dart` | **最后一步最小改动** | 仅把 `defaultBootstrapUrls` 换成 R2 + release 分支三条（数据就绪后再改） |
| `lib/logic/content/models/root_manifest.dart` | **数据就绪后** | 增加可选 `mirrors` / `bootstrapUrls` 字段（§11） |
| `lib/logic/content/network/content_http_client.dart` | **数据就绪后** | 新增 `mirrorCandidates(baseUri, key, mirrors)`（§11） |

---

## 9. 风险与注意事项

1. **GitHub Release 国内实测连接被重置**：作为海外备通道可用，国内 zip 实际只有 R2 与 Gitee。
2. **Gitee Release 上传是唯一手工环节**：上传前 `verify` 会因 zip 不可达报红，属预期。
3. **R2 单点依赖**：Cloudflare 故障则 zip 全挂（GitHub/Gitee Release 可作兜底，但国内 GitHub 不通）。
4. **覆盖式发布 + CDN 长缓存**：同名 zip 重导必须手动 purge，否则客户端拿到旧包。
5. **测试数据清理**：`v0.1.0` Release 与旧仓库内容由用户手动删除，脚本不涉及删除远端。
6. **repo 当前是旧结构**（`main/images`、`main/batches/batch_001.json`），
   与新 `Output`（`main/batches/batch_001/index.json`）不一致 —— 首次 sync 会表现为大量删除 + 新增，属正常。

---

## 10. 待确认决策项

| # | 决策点 | 建议 |
|---|---|---|
| 1 | 首次发布是否直接以 `master` 起、随后新建 `release`？ | ✅ 是，先 master 测通再建 release |
| 2 | `zipUrls` 顺序是否 `[R2, GitHub, Gitee]`（国内 GitHub 不通）？ | 建议改为 `[R2, Gitee, GitHub]` 更贴合国内；海外由 R2 直连 |
| 3 | 是否保留 `zipKey` 字段（当前 app 不消费）？ | 保留，为后续接入通道表留口子，成本为零 |
| 4 | Gitee Release 走手动上传还是先验证 API token？ | 先手动，token 作为后续优化 |
| 5 | `verify` 是否作为发布门禁（失败即中断后续步骤）？ | 建议作为**报告**而非硬门禁（Gitee Release 未传会误报） |
| 6 | 旧测试数据（45 文件 / `v0.1.0`）何时清？ | 首次正式发布前由用户手动清 |
| 7 | 旧 `jigsawdata_remote_verify_test.dart`（旧契约）是否废弃？ | 是，由新三通道测试取代 |
| 8 | manifest 是否引入 `mirrors` / `bootstrapUrls`（见 §11）？ | 是，随首次发布一并下发 |
| 9 | 版本化发布（§12）：Output 复制到 `release/`，版本目录只放 json，入口 `manifest-release.json` | **已确认采纳** |
| 9a | `release/manifest.json`（Output 原样、未处理）是否保留 | 建议保留留档；若要避免误用可在 sync 时跳过 |
| 10 | blob 改为纯追加 / 不覆盖 / 不 purge（§12.5，推翻原方案 A） | 是 |
| 11 | 保留几个历史版本 | 3 个，超出由 GC dry-run 清理 |
| 12 | 结构转换（json 拆到版本目录 + 路径改写）由谁做 | 发布脚本，studio 不动 |
| 13 | 灰度是否现在做 | 暂缓，需要时上 Workers 边缘分流 |

---

## 11. manifest 备用 URL 方案（Q7：json 是否也该有备用）

**结论：需要。但推荐用顶层 `mirrors` 数组，而不是每个模块各写一份 `urls`。**

### 11.1 为什么不逐模块写 `urls`

zip 用 `zipUrls` 是因为它在 git 平台走 Release **扁平命名空间**（不能用 `base + key` 推导），
必须逐个写死绝对地址。而 json / 图片 / cover 在三通道都是同一规则 `base + 相对 key`，
逐个写会重复 4 份（模块数）× 3 份（通道数），且 main 的 batch json 层还要再写一遍。

### 11.2 顶层 `mirrors` 设计

```json
{
  "schemaVersion": 4,
  "updatedAt": "2026-09-10T10:34:08Z",
  "appConfig": { "notice": "", "minAppVersion": 1 },
  "mirrors": [
    "https://jigsawdata.umao.top/release/",
    "https://gitee.com/macitee/jigsaw-data/raw/master/release/",
    "https://raw.githubusercontent.com/mcxiaoke/jigsaw-data/master/release/"
  ],
  "bootstrapUrls": [
    "https://jigsawdata.umao.top/release/manifest-release.json",
    "https://gitee.com/macitee/jigsaw-data/raw/master/release/manifest-release.json",
    "https://raw.githubusercontent.com/mcxiaoke/jigsaw-data/master/release/manifest-release.json"
  ],
  "modules": { "…": "保持不变，仍用相对 url" }
}
```

- `mirrors`：内容镜像 base 列表（有序，主在前）。App 用 `mirrors[i] + 相对key`
  即可为**任意相对引用**（模块 index、batch json、图片、cover）生成备用 URL。
- `bootstrapUrls`：manifest 自身的候选地址，用于覆盖 App 内置种子表，
  实现「新增平台不用发版」。
- 两者均为**可选字段**，旧版 App 忽略它们时行为完全不变（schemaVersion 保持 4）。

### 11.3 App 端消费方式（数据就绪后，改动很小）

```dart
// ContentHttpClient 新增
static List<String> mirrorCandidates(
  String baseUri, String key, List<String> mirrors,
) => <String>{
  resolveUrl(baseUri, key),
  for (final m in mirrors) resolveUrl(m, key),
}.toList();
```

`ContentManager` 在拉取模块 json / 图片时改用 `mirrorCandidates` 逐个尝试即可；
zip 仍走 `zipUrl` + `zipUrls`（规则特殊，不参与 mirrors 推导）。

### 11.4 收益

| 场景 | 无 mirrors | 有 mirrors |
|---|---|---|
| R2 挂掉 | manifest 降级到 git 通道，但其下所有相对 URL 全在 R2 → 全挂 | 任意通道都可为任意 key 生成镜像，逐层回退 |
| 新增平台 | 需发版改 `defaultBootstrapUrls` | 下发 manifest 即可生效 |
| 数据冗余 | 每个模块各写 3 个 URL | 顶层 3 个 base 覆盖全部 |

---

## 12. 版本化发布：让「发布」与「生效」解耦

### 12.1 问题

原流程里 **push / rclone 完成 = 客户端下次 sync 即全量生效**，没有测试窗口；
且 `master` / `release` 双分支的隔离只对 git 通道有效，**R2 没有分支概念，主通道一更新就被绕过**。
单纯给 manifest 加 `version` 字段无效——客户端逻辑是「远端 version > 本地 version 就更新」，
version 只是记录，不是闸门。

解法：**内容先就位但无人引用，最后一步才切换指针。**

### 12.2 目录结构：source 与 release 分离

> 前提（已确认）：**没有已发布的存量客户端**（仅作者本机测试 app），因此不做向后兼容，
> 仓库根的 json 一律保持 Output 原样，只作 source 留底。

**`release/` = Output 的原样副本 + 版本目录 + 客户端入口**，
R2 同步目标 `r2:jigsaw-data/release`，仓库根目录零污染，换子目录名只需改发布参数。

```
release/
├── manifest.json            ← Output 原样副本（不被客户端使用，仅留档）
├── main/index.json          ← Output 原样（同上）
├── main/batches/batch_001/index.json + images/*.webp
├── daily/index.json + daily/zips/*.zip
├── events/…  collections/…
├── manifest-release.json    ← 【客户端唯一入口】当前生效版本清单
├── v1.0.0/                  ← 历史版本清单（仅 json）
│   ├── manifest.json
│   ├── main/index.json
│   ├── main/batches/batch_001/index.json
│   └── daily/index.json  events/index.json  collections/index.json
└── v1.0.1/                  ← 本次发布，上传后无人引用
```

要点：

- **Output 原样复制进 `release/`，不做任何拆分**，blob（图片 / zip / cover）只有一份，
  磁盘与传输成本最低。
- **客户端不用 `manifest.json`**（那是 Output 原样、未处理的），入口是
  `manifest-release.json`——它是一份完整 manifest，只是 `modules.<m>.url`
  指向版本目录（`v1.0.1/main/index.json`），因此**客户端解析逻辑零改动**，
  只需把 bootstrap URL 换成 `…/release/manifest-release.json`。
- **`promote` = 重新生成 `manifest-release.json`**（把 modules 指向 `v1.0.1/`）；
  **`rollback` = 重新生成并指向 `v1.0.0/`**。单文件替换，原子、秒级。
- 版本目录只放 json，每版本新增约几 KB。
- 三通道统一前缀：

```
https://jigsawdata.umao.top/release/…
https://gitee.com/macitee/jigsaw-data/raw/master/release/…
https://raw.githubusercontent.com/mcxiaoke/jigsaw-data/master/release/…
```

### 12.3 引用规则（版本 json 内的路径改写）

| 字段 | studio 原始值 | 版本 json 内改写为 |
|---|---|---|
| `modules.<m>.url` | `main/index.json` | 不变（同版本目录内相对） |
| 模块 json → batch | `batches/batch_001/index.json` | 不变 |
| 关卡 `url` | `images/001.webp` | `../../../main/batches/batch_001/images/001.webp` |
| `coverUrl` | `covers/xxx.webp` | `../../events/covers/xxx.webp` |
| `zipUrl` | `zips/202609.zip` | `https://jigsawdata.umao.top/release/daily/zips/202609.zip`（R2 绝对） |
| `zipUrls` | — | `[R2, Gitee Release, GitHub Release]` |

- 图片 / cover 用**相对路径回退到 `release/` 根**，不写死 `release` 前缀 ——
  将来换子目录名只需移动目录，无需重新生成 json。
- zip 用绝对地址必须带 `/release/` 前缀（发布脚本按 `--prefix` 参数生成）。
- `Uri.resolve` 逐级解析相对路径，三通道自动跟随，客户端零改动。

### 12.4 五步流程（取代 §5 的线性发布）

| 步骤 | 动作 | 客户端感知 |
|---|---|---|
| 1 `sync` | Output 原样复制到 `release/`；json 再复制一份到 `release/v1.0.1/` | 无 |
| 2 `prepare` | 改写 `release/v1.0.1/` 内 json 的引用；注入 `zipKey`、`zipUrls`；重算模块 hash | 无 |
| 3 `verify` | 直接访问 `release/v1.0.1/manifest.json` 做三通道全量校验（§Step 7 口径） | 无 |
| 4 `promote` | 生成 `release/manifest-release.json`，`modules.<m>.url` 指向 `v1.0.1/` | **此刻生效** |
| 5 `rollback` | 重新生成 `manifest-release.json` 指向 `v1.0.0/` | 秒级回滚 |

R2 同步：`rclone copy <repo>/release r2:jigsaw-data/release --checksum --immutable`（只发布 `release/`）。

- 步骤 1~3 期间线上完全不受影响，可任意时长验证；
- 步骤 4 是唯一「生效」动作，且所有内容早已就位，切换是原子的；
- 根 `manifest.json` 同时保留完整 `modules` 副本，老版本 app 直接读它也能正常工作（过渡期兼容）。

### 12.5 连带变更：blob 改为纯追加（取代原「方案 A 覆盖」）

版本化后，`v1.0.0` 的清单仍引用着旧 blob，**同名覆盖会让历史版本指向错误内容**。
因此推翻原方案 A：

| 项 | 原方案 A | 版本化后 |
|---|---|---|
| R2 写入 | 允许覆盖 + 手动 purge | `--immutable` 纯追加，永不覆盖 |
| zip 命名 | 同名覆盖 | 内容变更自动 `-r{rev}`（studio 已实现），新名即新文件 |
| Release 上传 | `--clobber` | 不 clobber，新 rev 是新文件名，旧资产保留 |
| CDN 缓存 | 1 个月缓存有失效风险 | 文件永不变，长缓存天然安全，无需 purge |

代价：R2 会积累历史 rev 文件，由 GC 命令（dry-run 确认）清理 N 个版本之前的孤儿。

### 12.6 成本

| 项 | 量级 |
|---|---|
| `assets` / blob 总量 | 一份，124MB（zip 77MB + webp 47MB） |
| 每版本新增 | 4~6 个 json ≈ 几 KB + 本期真正新增的图片 |
| 保留 3 个版本 | ≈ 124MB + 几十 KB（R2 免费 10GB 无压力） |
| git 增长 | 每版本几 KB；新批次 / 新图包时按实际增量 |

> 注意：`rclone copy` 默认按 size + modtime 判断，studio 重导可能重写同内容文件导致误传，
> 发布脚本统一加 `--checksum` 按内容比对。

### 12.7 灰度（可选，客户端零改动）

需要灰度时在 Cloudflare Workers 做边缘分流：`/manifest.json` 按地区（`CF-IPCountry`）
或请求哈希百分比返回不同 `current` 值。R2 自定义域本就走 Cloudflare，无需改 app。
按 deviceId 分桶才需要客户端参与，当前规模不需要。
