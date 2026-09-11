# jigsaw-data 素材轻量发布工作流方案 (v2 规划定稿版)

> 日期：2026-09-10 ｜ 状态：**计划文档（架构定稿待实施，尚未改动生产代码与仓库）**
> 适用背景：个人独立游戏，**无国内工信部 ICP 备案**（无法使用国内腾讯云 COS / 阿里云 OSS / 又拍云自定义 CDN），追求**简单、可靠、低维护心智**。
> 前提基准：**当前 Git 仓库历史数据为开发测试脏数据，首次正式发布时将彻底清理重置**；测试客户端与新用户均从干净的 0 数据冷启动，无历史版本回退包袱。
> 架构底座：**Cloudflare R2（主通道，免备案、免出站流量费、全球 CDN）+ Gitee / GitHub（备用通道）**。
> 关键实测：`rclone` 桶内复制已确认为 **R2 服务端复制（Server-Side Copy）**，数据不经本地，预演到生产秒级完成。
> 取代对象：彻底取代 `docs/assets-publish-workflow-design-20260910.md` 中复杂的 §12 版本目录、相对路径多层回退与双分支设计。

---

## 0. 核心设计哲学

1. **同构目录，零路径魔改**：
   Studio 导出的 `Output` 目录结构就是最终在 R2 和 Git 上托管的结构。**严禁改写图片和关卡 JSON 的相对路径，严禁使用 `../../../` 等层级回退**。RFC 3986 相对路径自然解析，从根源上彻底杜绝 404 漏洞。
2. **预演前缀隔离，解耦发布与生效**：
   在 R2 上使用 `_stage/`（测试预演）与 `release/`（正式生产）两个顶层前缀。内容先推送到 `_stage/`，验证无误后瞬间同步到 `release/`。
3. **相对 URL + Release 备用镜像（彻底终结 URL 切换死结）**：
   `zipUrl` **保持相对路径不变**，无论在 `_stage` 还是 `release` 均天然自洽解析；`zipUrls` 仅存放 Gitee / GitHub Release 的绝对地址作为容灾兜底。
4. **备源先上，主源再切（零容灾真空期）**：
   在预演区验证通过后，**先上传 Gitee / GitHub Release 附件，最后一步再将 R2 服务端同步到生产 `release/`**，确保生产主源生效的瞬间，备用通道 100% 处于就绪状态。
5. **单分支 + 固定 Release Tag**：
   Git 仓库只维护 `master` 单分支，Release 采用固定的移动标签 `assets`，新 zip 增量追加上传，避免频繁改动分支和 tag 带来的操作摩擦。
6. **最小凭证依赖**：
   依靠 Cloudflare Cache Rule 统一绕过 JSON 缓存，流水线无需引入 Cloudflare API Token 依赖，减少外部失败点。

---

## 1. 目录角色与环境规划

### 1.1 本地与远端对应关系

全套流程路径严格统一，彻底废弃旧脚本中失效的 `C:/Home/Projects/...` 路径：

| 路径 / 端点 | 角色 | 读写权限 | 说明 |
|---|---|---|---|
| `F:\Pictures\JigsawGame\Output` | 输入源（dist） | **只读** | Studio 原生导出产物（当前 213 文件 / 124MB），**严禁包含 `.git` 拷入发布源** |
| `F:\Pictures\JigsawGame\jigsaw-data` | 发布工作副本（stage/repo） | 可写 | Git 工作副本，所有发布产物统一下沉挂载于 `release/` 目录 |
| `r2:jigsaw-data/_stage/` | R2 预演区（测试） | 远端可写 | 测试验证通道，供本地测试版 App 和 CI 脚本巡检 |
| `r2:jigsaw-data/release/` | R2 生产区（正式） | 远端可写 | 正式生产通道，线上用户唯一读取的主源 |
| `origin` (GitHub) / `gitee` | 备份源（Git 仓库） | 远端可写 | 代码与 JSON 元数据备份（`.zip` 被 gitignore 排除） |
| GitHub / Gitee Releases | 备用下载源（Release 附件） | 远端可写 | 存放 14 个 zip 包的备份下载源（挂载于固定 tag `assets`） |

### 1.2 首次迁移与仓库重置（一次性动作）
由于旧版 `jigsaw-data` 根目录下存在历史测试脏数据（包括旧 `main/images/`、`main/batches/batch_001.json` 及旧 `manifest.json`），在首次应用 v2 方案前彻底清理重置：
```bash
git -C F:\Pictures\JigsawGame\jigsaw-data rm -r main daily events collections manifest.json
git -C F:\Pictures\JigsawGame\jigsaw-data commit -m "reset: clean legacy dev root structure for v2"
```
让所有发布产物统一下沉至 `jigsaw-data/release/` 子目录，根目录仅保留 `.git/`、`.gitignore`、`README.md`。

### 1.3 固定 Tag `assets` 首次创建（一次性动作）
GitHub 和 Gitee 的 Release 附件统一挂载于固定 tag `assets`（永不移动）。首次发布前在两端初始化：
```bash
gh release create assets --title "assets" --notes "jigsaw-data zip packs"
gitee release create --tag assets --target master -n "assets" -b "jigsaw-data zip packs" -R macitee/jigsaw-data
```

### 1.4 `.gitignore` 规范（jigsaw-data 根目录）

```gitignore
*.zip
.dl_check/
.ms_upload_cache/
_*
```
> **原理**：`.zip` 被 Git 忽略，使 Git 仓库保持小巧轻量（仅存 JSON 与 WebP 图片）；而 `rclone` 默认不受 `.gitignore` 影响，完整同步所有文件（含 `.zip`）至 R2。

---

## 2. 存储结构同构设计（零路径改写）

R2 的 `_stage/`、`release/` 以及本地 `jigsaw-data/release/` 目录结构**保持 100% 完全一致**：

```text
release/ (或 _stage/)
├── manifest.json                  <-- 统一入口清单
├── main/
│   ├── index.json
│   └── batches/
│       └── batch_001/
│           ├── index.json
│           └── images/
│               └── *.webp         <-- 关卡图片
├── daily/
│   ├── index.json
│   └── zips/
│       └── *.zip                  <-- 每日挑战月度包
├── events/
│   ├── index.json
│   ├── covers/*.webp
│   └── packs/*.zip
└── collections/
    ├── index.json
    ├── covers/*.webp
    └── packs/*.zip
```

### 为什么这能从根本上保证可靠性？
- `batch_001/index.json` 中引用图片保持原生相对路径 `"url": "images/001.webp"`。
- 当 App 请求 `.../release/main/batches/batch_001/index.json` 时，Dart 的 `Uri.resolve("images/001.webp")` 天然解析为 `.../release/main/batches/batch_001/images/001.webp`。
- **无论在预演区、生产区、还是离线本地开发环境，相对路径全部自然生效**，不需要脚本去算层级，彻底消除 Off-by-one 路径 Bug。

---

## 3. URL 契约与终极 URL 切换解法

### 3.1 客户端 Bootstrap 种子表

线上生产 App 配置：
```dart
static const List<String> defaultBootstrapUrls = [
  'https://jigsawdata.umao.top/release/manifest.json',                             // R2 主通道
  'https://gitee.com/macitee/jigsaw-data/raw/master/release/manifest.json',        // Gitee 国内备用
  'https://raw.githubusercontent.com/mcxiaoke/jigsaw-data/master/release/manifest.json', // GitHub 海外备用
];
```

测试/开发版 App 仅需指定为预演地址：
`https://jigsawdata.umao.top/_stage/manifest.json`

---

### 3.2 zip 条目最小改写规范（核心：保持相对 + 注入绝对镜像）

之前发布流程之所以产生巨大复杂度，核心就在于**ZIP 文件在各平台的组织规则异构**：
- 在 R2 上，ZIP 保留目录层级（`release/daily/zips/202609.zip`，同构目录）；
- 在 Git 上，仓库排除了 ZIP，ZIP 被放到了 Release 附件中（`releases/download/assets/202609.zip`，扁平单层）。

**终极最优解：Studio 导出的 `zipUrl` 保持相对不变，仅向 `zipUrls` 注入 Release 绝对地址**。

以 `daily/index.json` 为例，Studio 原生导出数据：
```json
{
  "month": "202609",
  "zipUrl": "zips/202609.zip",
  "zipSha256": "59d8edf4...",
  "fileSizeBytes": 5242880,
  "revision": 1
}
```

发布脚本就地增补为：
```json
{
  "month": "202609",
  "zipUrl": "zips/202609.zip",
  "zipUrls": [
    "https://gitee.com/macitee/jigsaw-data/releases/download/assets/202609.zip",
    "https://github.com/mcxiaoke/jigsaw-data/releases/download/assets/202609.zip"
  ],
  "zipSha256": "59d8edf4...",
  "fileSizeBytes": 5242880,
  "revision": 1
}
```

#### 全场景 URL 切换机制分析：
客户端下载逻辑（`ContentHttpClient.downloadFileWithMirrors`）会按序尝试候选列表：

1. **场景 1：生产环境正常运行（App 连 R2 `release/`）**：
   - `dailyIndexUrl` 为 `https://jigsawdata.umao.top/release/daily/index.json`。
   - `zipUrl`（`zips/202609.zip`）通过 RFC 3986 相对解析，天然得到：
     `https://jigsawdata.umao.top/release/daily/zips/202609.zip`。
   - 首选候选项就是 R2 生产包，**直接命中，秒级下载**。
2. **场景 2：预演环境全链路验证（测试 App 连 R2 `_stage/`）**：
   - `dailyIndexUrl` 为 `https://jigsawdata.umao.top/_stage/daily/index.json`。
   - `zipUrl` 相对解析天然得到：
     `https://jigsawdata.umao.top/_stage/daily/zips/202609.zip`。
   - **真机/测试 App 自动从 `_stage` 下载预演包！** 完全不依赖生产环境，更不会发生跨环境污染或 404 报错。
3. **场景 3：主源宕机容灾回退（R2 故障，App 降级连 Gitee Raw）**：
   - `dailyIndexUrl` 为 `https://gitee.com/macitee/jigsaw-data/raw/master/release/daily/index.json`。
   - 候选 1（相对解析）：指向 Gitee Raw 路径，由于未入库立即返回 404（几十毫秒完成）。
   - 候选 2（`zipUrls[0]` 绝对地址）：`downloadFileWithMirrors` 立即切入 Gitee Release 附件地址，**下载成功**！
   - **容灾回退全自动完成，用户端体验平滑**。

- **Hash 回写**：由于 `index.json` 补充了 `zipUrls` 字段，更新 `manifest.json` 中对应的 `modules.daily.hash`、`modules.events.hash`、`modules.collections.hash`。
- **其余所有相对 URL 绝不修改**。

---

## 4. 极简发布流程（安全时序版）

整体流程严格遵循：**本地准备 -> 预演验证 -> 备源就位 -> 生产生效 -> 最终巡检**。
（关键调整：在预演验证通过后，**先上传 Release 附件，再执行 R2 服务端 promote**，杜绝生产切换时的容灾空白期）。

```text
[Output (只读)] 
      │ 
      ▼ (Step 1: sync & prepare - 白名单拷贝，排除 .git)
[本地 jigsaw-data/release/] 
      │ 
      ├── (Step 2: stage) ──────> [R2: _stage/] ──> [运行预演自动化验证]
      │                                 │
      ├── (Step 3: release) ────────────┼─────────> [提前就位: Gitee/GitHub Release 附件]
      │                                 │
      ├── (Step 4: promote) <───────────┘ (秒级生效: R2 桶内 Server-Side Copy)
      │         │
      │         ▼
      │    [R2: release/] ──> [生产全量巡检确认]
      │
      └── (Step 5: git) ──> [推送 GitHub / Gitee master 分支代码]
```

### Step 1: `sync & prepare`（本地同步与改写）
```bash
python scripts/publish/publish.py prepare
```
- **白名单拷贝**：清空本地 `jigsaw-data/release/`，仅从 `Output` 拷贝 `main/`、`daily/`、`events/`、`collections/` 与 `manifest.json`。**显式排除 `Output/.git` 及一切隐藏文件**，杜绝嵌套子仓库污染。
- **源文件数量守卫**：检查 `Output` 文件总数（排除 `.git` 后），若少于 200 个文件（当前基线 213）则中断拒绝执行，防范误拷贝空目录。
- **改写与哈希**：遍历 `daily`、`events`、`collections` 的 `index.json`，注入 `zipUrls`，重算模块哈希回写 `manifest.json`。
- **本地硬门禁**：
  1. 所有 zip 文件在本地磁盘真实存在。
  2. zip basename 全局无重名冲突（保证 Release 扁平命名安全）。
  3. **`modules.main.version` 严格递增**：对比 `manifest.json` 中的 `modules.main.version` 与上一版本。必须严格大于上一版，确保客户端 `syncWithRemote` 正常感知更新。

### Step 2: `stage`（上传预演区并验证）
```bash
# 1. 同步到 R2 预演目录（带源非空守卫）
rclone sync F:\Pictures\JigsawGame\jigsaw-data/release r2:jigsaw-data/_stage --checksum --progress

# 2. 运行预演区自动化巡检
python scripts/publish/publish.py verify --env stage
```
- 巡检 `https://jigsawdata.umao.top/_stage/` 下的 JSON、图片与 Zip 包。
- 此时 `zipUrl` 相对解析天然指向 `_stage/` 下的 zip，真机与脚本均能精准验证预演包的真实可达性。

### Step 3: `release`（备用通道附件先行就位）
```bash
# 增量上传 zip 到 GitHub 与 Gitee Release 附件
python scripts/publish/publish.py release
```
- 依赖环境变量 `GITEE_TOKEN`（或本地 Git 凭证管理器）。
- GitHub 使用 `gh release upload assets <zip_files> --clobber`。
- Gitee 使用轻量脚本上传至 Release `assets`，已有同名且大小一致的文件自动跳过，仅上传新增增量包。
- 若 Gitee Release 附件总体积超过 **800MB**（上限 1GB）输出提示告警。

### Step 4: `promote`（正式生产生效与全量巡检）
```bash
# 1. R2 存储桶内 Server-Side Copy，瞬间完成，不消耗本地带宽
rclone copy r2:jigsaw-data/_stage r2:jigsaw-data/release --checksum --progress

# 2. 生产环境全量巡检确认
python scripts/publish/publish.py verify --env prod
```
- 直接在 R2 内部将 `_stage/` 同步覆盖至 `release/`。
- 随后立即运行 `verify --env prod`，对生产域名的 `manifest.json`、4 模块 index、**全部 WebP 图片（全量 200 校验，几秒完成）** 以及所有 zip 主地址进行最终真实验证。

### Step 5: `git`（Git 提交与推送留底）
```bash
git -C F:\Pictures\JigsawGame\jigsaw-data add -A
git -C F:\Pictures\JigsawGame\jigsaw-data commit -m "publish assets $(date +%Y%m%d)"
git -C F:\Pictures\JigsawGame\jigsaw-data push origin master
git -C F:\Pictures\JigsawGame\jigsaw-data push gitee  master
```

---

## 5. 缓存控制与秒级生效关键策略

实测 Cloudflare 自定义域名对未配置规则的资源有长达 4 小时的边缘缓存。为确保秒级生效且不增加流水线复杂度，采用**单点规则化配置**：

### 5.1 Cloudflare 缓存规则（一劳永逸）
在 Cloudflare 控制台添加一条 **Cache Rule**：
- **匹配规则**：`ends_with(http.request.uri.path, ".json")`
- **处理动作**：**Bypass Cache**（绕过缓存）
> **效果**：所有 JSON 文件（无论是 `_stage` 还是 `release`）均保证 0 缓存穿透，客户端每次拉取必得最新。图片与 Zip 包则维持 Cloudflare 默认的长缓存加速。

### 5.2 Purge 降级为手动应急
由于 JSON 已全局绕过缓存，正常发布流程**无需调用 Cloudflare Purge API**，流水线**无需配置 `CF_API_TOKEN` 和 `CF_ZONE_ID`**。仅保留 `python publish.py purge` 作为极端情况下的手动应急脚本。

---

## 6. 首次上线冷启动检查清单 (First-Time Checklist)

由于当前 R2 存储桶为 0 对象空桶，首次全量上线前按此清单逐项核对：

- [ ] **1. Cloudflare Cache Rule 建立**：确认控制台已创建 `.json` Bypass Cache 规则。
- [ ] **2. R2 存储桶与域名就绪**：确认 `https://jigsawdata.umao.top/` 能正常响应 TLS。
- [ ] **3. Git 仓库旧数据重置**：已执行 `git rm -r` 清理历史根目录脏数据并提交。
- [ ] **4. GitHub / Gitee Tag 初始化**：两端均已成功创建一次性固定 Release Tag `assets`。
- [ ] **5. 全量首发 Stage 跑通**：`python publish.py prepare` 与 `stage` 执行无误。
- [ ] **6. 备源 Release 附件首传**：14 个 zip 包已全部上传到两端 `assets` Release。
- [ ] **7. Promote 生产生效**：`rclone copy .../_stage .../release` 执行成功。
- [ ] **8. 生产全量 Verify**：`verify --env prod` 返回 0 error，三通道 URL 全部可达。
- [ ] **9. 客户端种子表更新**：`app_content.dart` 中更新 `defaultBootstrapUrls` 指向 `release/manifest.json`。

---

## 7. 回滚与已知限制应对 SOP

### 7.1 回滚操作
当新发布的素材出现问题需要紧急回滚时：
1. 本地通过 Git 取回上一版本的 JSON：
   ```bash
   git -C F:\Pictures\JigsawGame\jigsaw-data checkout HEAD~1 -- release/
   ```
2. **关键注意（针对 main 模块）**：
   由于客户端 `MainContentPipeline` 有 `remoteVersion <= _localVersion` 则跳过的逻辑，回滚时**必须手动将 `manifest.json` 中的 `modules.main.version` 与 `main/index.json` 的 `version` 递增 +1**（例如原是 3，出问题的是 4，回滚文件必须设为 5），否则已更新的客户端不会拉取回退内容。
3. 重新执行 Step 4（将回滚后的本地文件同步至 R2 `release/`）：
   ```bash
   rclone copy F:\Pictures\JigsawGame\jigsaw-data/release r2:jigsaw-data/release --checksum
   ```
4. 因为历史图片和 zip 在 R2 上**从未删除**，旧 JSON 指向的历史文件天然可达，秒级完成回滚。

### 7.2 客户端月份缓存限制与运营底仓备份准则
- 客户端 `DailyContentPipeline` 的策略是：本地已有该月份解压目录且非空，则直接返回完成，不再请求网络。
- **影响**：如果某个月份的每日关卡已发布且用户已下载到手机，后续即使修改了该月图片并重新生成同月 Zip，**已装机老用户不会重新下载该月**。
- **运营准则**：重要资产数据安全依赖底仓与 Studio 输出归档备份，当月关卡一旦正式发布上线，避免在线上同名覆盖。若确需修图，可通过活动（Events）或主线（Main）进行补丁推送。

---

## 8. 脚本改造精简指南

原有复杂的脚本体系收敛为单一入口 `scripts/publish/publish.py`：

```text
scripts/publish/
├── publish.py          <-- 唯一编排入口（子命令：prepare / stage / release / promote / verify / all）
├── gitee_release.py    <-- 专门负责 Gitee Release OpenAPI 上传（带跳过已存在与 800MB 软告警）
└── channels.json       <-- 仅保留 R2 / Gitee / GitHub 三个通道定义
```

子命令规范：
- `python publish.py prepare`：白名单拷贝（排除 `.git`）、检查源文件数（≥200）、注入 `zipUrls`、核验 `main.version` 严格递增。
- `python publish.py stage`：`rclone sync` 到 `r2:jigsaw-data/_stage`（源非空保护）。
- `python publish.py verify --env stage`：巡检预演区（JSON 200、图片全量、zip 可达）。
- `python publish.py release`：上传新增 zip 到 GitHub/Gitee Release（依赖 `GITEE_TOKEN`）。
- `python publish.py promote`：R2 桶内快速 Server-Side 拷贝 `_stage` 到 `release`，并自动触发 `verify --env prod`。
- `python publish.py all`：一键自动按正确安全顺序执行全套发布流水线。

---

## 9. 日常增量更新流程与 App 升级检测测试规范

实际日常运营中，90% 以上的发布是**小规模增量更新**（如月度增加当月每日挑战、主线增加一个批次 30 关、或者新增一个限时活动）。本节详细规范**增量发布流程**与**客户端在已有老数据时的更新检测与消费测试**。

### 9.1 日常增量发布的分类与触发条件

| 业务场景 | Studio 变动内容 | 关键字段变动 | 客户端感知与行为 |
|---|---|---|---|
| **A. 每日挑战按月增量** | 新增 `daily/zips/202610.zip`，`daily/index.json` 追加 1 项 | `modules.daily.hash` 变动，`currentMonth` 更新为新月份 | App 启动拉取 index，仅拉取新月份元数据；用户点进该月时才下载新 zip（懒加载） |
| **B. 首页主线增加新批次** | 新增 `main/batches/batch_002/index.json` 与对应图片；`main/index.json` 追加 batch 项 | **`manifest.modules.main.version` 递增 +1** | App 比对版本发现更新，计算 `missingBatches`，**只拉取 batch_002 关卡**，旧关卡原样保留 |
| **C. 新增活动 / 扩展图集** | 新增 `events/packs/evt_x.zip` 或 `collections/packs/col_y.zip` | 对应模块 hash 变动 | App 在 `syncAll` 时拉取 index，发现新条目；点击活动时才触发 zip 镜像下载 |
| **D. 历史关卡修图换图** | 原有 `batch_001` 内某个图片更新（hash 改变） | `PuzzleLevelItem.hash` 变动，`main.version` 递增 +1 | App 检测到已下载关卡的 hash 不一致，自动重刷图片缓存 |

### 9.2 日常增量发布操作 SOP
增量发布的命令与首次完全一致，底层机制保证增量最小化传输：
1. **`prepare` 增量改写**：Studio 导出新增内容到 `Output` 后，运行 `python publish.py prepare`。脚本自动扫描出新增的 zip 包，并在对应 `index.json` 中追加注入 `zipUrls`；门禁自动核对 `main.version` 是否较线上版本递增。
2. **`stage` 差异同步**：`rclone sync ... r2:jigsaw-data/_stage --checksum` 凭借 `--checksum` 只上传新增或内容变动的文件（耗时几秒，几十 KB~几 MB）。
3. **`release` 增量追加**：`publish.py release` 检查 GitHub/Gitee Release 上的已有附件列表，**仅上传本次新增的 zip 文件**，已存在的跳过不传。
4. **`promote` 增量合入**：`rclone copy r2:jigsaw-data/_stage r2:jigsaw-data/release --checksum` 在 R2 服务端快速合入差异文件。

---

### 9.3 核心测试项：App 存量数据下的更新检测与升级测试

为确保新内容上线后，**已有上一版本数据的已装机 App 能正确检测到更新、不重复下载旧数据、不发生数据漂移**，建立标准的增量集成测试流程。

#### 9.3.1 客户端更新检测核心代码契约审查

```text
[App 启动 / backgroundSyncOnce]
              │
              ▼
    1. resolveManifest()
       拉取最新 manifest.json，对比版本与哈希
              │
    ┌─────────┴────────────────────────────────────────┐
    ▼                                                  ▼
[mainPipeline.syncWithRemote]              [daily / events / collections]
- remoteVersion <= _localVersion?          - 无版本短路，每次拉取 index.json 比对
  ├─ 是 (无新批次) ──> 快速短路跳过 (0 开销)       - 内存条目 upsert 增量合并
  └─ 否 (有新批次) ──> 计算 missingBatches         - 新月份/新活动展示角标提示
        │                                      - 旧解压目录完好，无需重复拉取
        ▼
   仅下载缺少的 batch_002/index.json
   旧批次关卡保持内存与磁盘不变
```

#### 9.3.2 增量更新全链路测试用例（SOP）

| 测试用例 ID | 前置存量状态（Version N） | 发布变动（Version N+1） | 预期验证结果（验收标准） |
|---|---|---|---|
| **TEST-INC-01** (主线批次差集) | 客户端已完整同步 `batch_001`（30关卡已落盘，`_localVersion=1`） | 远端发布 `batch_002`，`main.version=2` | 1. `mainPipeline.syncWithRemote` 返回 `hasNewItems == true`；<br>2. 仅发起 `batch_002/index.json` 请求，**无任何 batch_001 请求**；<br>3. `levels` 总数正确增为 60 关，旧关卡状态与完成度无损。 |
| **TEST-INC-02** (版本短路防重) | 客户端已同步至 `main.version=2` | 远端再次发布，但 `main.version` 保持 2 未变 | 1. 触发 `syncAll()`，`syncWithRemote` 命中短路判断直接返回 `false`；<br>2. 网络抓包显示 0 批次请求，耗时 < 50ms。 |
| **TEST-INC-03** (跨月挑战增量) | 客户端已下载并解压 `202609` 月份关卡（磁盘目录存在） | 远端新增 `202610` 月份元数据与 zip | 1. `daily/index.json` 正确解析出 2 个月份；<br>2. 访问 9 月关卡，命中本地磁盘秒开，**0 字节网络流量**；<br>3. 访问 10 月关卡，触发 `ensureMonthReady('202610')`，成功按序轮询下载并解压到 `202610/`。 |
| **TEST-INC-04** (镜像容灾降级) | 模拟 R2 主通道域名拦截/404 | 客户端触发下载 `202610.zip` | 1. `downloadFileWithMirrors` 捕获 R2 失败日志；<br>2. 自动无缝降级到 Gitee Release 镜像并下载成功；<br>3. 解压校验通过，UI 无报错崩溃。 |
| **TEST-INC-05** (活动下架 Auto-GC) | 客户端本地已有活动 `evt_alpha` 解压数据 | 远端 `events/index.json` 下架该活动（移除 id） | 1. `syncWithRemote` 差集计算识别到 `evt_alpha` 已下架；<br>2. 触发 Auto-GC，本地沙盒目录被自动安全递归删除，释放磁盘。 |

---

## 10. 落地实施路线图与任务拆解

本方案已通过全部事实与架构评审，按照以下 5 个任务按序落地：

### Task 1: 路径统一与环境配置
- 明确本地 `jigsaw-data` 的工作路径统一下沉至 `jigsaw-data/release/`，废除所有旧路径。
- 确认 Studio 导出目录 `F:\Pictures\JigsawGame\Output` 仅作只读输入源。

### Task 2: 脚本重构与收敛 (`scripts/publish/publish.py`)
- 重写 `scripts/publish/publish.py`：
  - 整合白名单过滤（排除 `.git`）、源文件数检查（≥200）、`zipUrls` 注入与 SHA256 刷新逻辑。
  - 维持 `zipUrl` 为原生相对路径。
  - 增加 `main.version` 严格递增硬门禁。
  - 实现精简命令集：`prepare` / `stage` / `release` / `promote` / `verify`。
- 编写 `gitee_release.py`：实现带已有附件跳过逻辑与 800MB 软告警的轻量上传工具（依赖 `GITEE_TOKEN`）。

### Task 3: 仓库首迁清理与 Release Tag 初始化
- 在本地 `jigsaw-data` 执行一次性清理：
  ```bash
  git -C F:\Pictures\JigsawGame\jigsaw-data rm -r main daily events collections manifest.json
  git commit -m "reset: clean legacy root structure for v2"
  ```
- 在 GitHub 与 Gitee 分别执行一次性 Tag 创建：
  ```bash
  gh release create assets --title "assets" --notes "jigsaw-data zip packs"
  gitee release create --tag assets --target master -n "assets" -b "jigsaw-data zip packs" -R macitee/jigsaw-data
  ```

### Task 4: 客户端种子表更新
- 在 `lib/logic/content/app_content.dart` 中，将 `defaultBootstrapUrls` 统一更新为带有 `release/manifest.json` 的三通道配置：
  - `https://jigsawdata.umao.top/release/manifest.json`（R2 主）
  - `https://gitee.com/macitee/jigsaw-data/raw/master/release/manifest.json`（Gitee 备）
  - `https://raw.githubusercontent.com/mcxiaoke/jigsaw-data/master/release/manifest.json`（GitHub 备）

### Task 5: 线上端到端首跑验证与增量演练
- **全量首跑**：按 §6 Checklist 执行首次全量上线，验证 R2 预演、备源附件就位、生产秒级合入与 Git 上传。
- **客户端契约回归**：运行 `flutter test test/logic/jigsawdata_three_channel_verify_test.dart --dart-define=CHANNELS_VERIFY=true` 确保全通道解析通过。
- **增量演练**：按照 §9.3 的用例 TEST-INC-01 和 TEST-INC-03，模拟一次新增批次或月份的发布，确保老版本数据平滑过渡。

---

## 11. 与原方案对比总结

| 评估指标 | 原方案 (`...design-20260910.md`) | v2 规划定稿版（本方案） |
|---|---|---|
| **路径安全性** | ❌ 包含多层 `../../../` 改写，存在计算错误（关卡图片 404） | ✅ **100% 同构目录**，保持原生相对路径，无任何改写风险 |
| **测试与生效** | ⚠️ 版本目录 + 指针切换，与 `--immutable` 冲突 | ✅ **`_stage/` 预演前缀隔离**，R2 桶内秒级覆盖生产 |
| **URL 切换解法** | ❌ 写入绝对生产 URL，导致预演环境真机无法测 ZIP | ✅ **`zipUrl` 保持相对 + `zipUrls` 注入 Release 绝对镜像**（完美自洽） |
| **容灾真空期** | ⚠️ 生产先生效、附件后上传，存在切换真空期 | ✅ **备源先行就位、主源再秒级切换**（零容灾真空期） |
| **Git 目录安全性** | ❌ 整目录拷贝会将 `Output/.git` 嵌套拷入 | ✅ **严格白名单拷贝** + 排除一切隐藏文件 + 200 文件数守卫 |
| **入口命名** | ⚠️ `manifest-release.json` 与 `manifest.json` 双名混乱 | ✅ 统一使用 **`manifest.json`**，干净直观 |
| **凭证复杂度** | ⚠️ 必须依赖 Cloudflare API Token 做实时 Purge | ✅ **Cloudflare Cache Rule 绕缓存**，无需配置 CF Token |
| **Git 分支与 Tag** | ⚠️ `master` 与 `release` 双分支同步，每次频繁打 Tag | ✅ **单 `master` 分支** + **固定 Release Tag (`assets`)** |
| **开发维护心智**| ❌ 极高（如同维护大型复杂分发系统） | ✅ **极低**（专为独立个人游戏打造，简单可靠好操作） |
