# App 自动更新方案设计（极简可靠版）

> 日期：2026-09-14 ｜ 状态：设计定稿，进入实施
> 目标：追求**极致简单**与**绝对可靠**，消除过度工程与系统风险。

---

## 1. 核心设计原则

1. **零后端与零运维**：纯静态 JSON 清单 + Cloudflare R2 对象存储 + CDN 缓存绕过，无需维护任何后端服务与数据库。
2. **单一版本模型（无多渠道）**：废弃 `dev/beta/release` 复杂通道与晋升机制。独立游戏只维护单一主清单，本地/内测直接侧载，线上只发稳定正式版，逻辑精简 70%。
3. **强安全时序**：发版严格遵循「本地验证 → 备源先上 → 主源后上 → 清单最后切」顺序，确保客户端拉到更新时包必然 100% 可用。
4. **强完整性校验（SHA256 + Size）**：下载完强校验指纹，哈希不符直接丢弃并报错，绝不执行损坏文件。
5. **拒绝差量更新**：50~80MB 全量包更新最稳妥干净，不引入增量补丁的高故障率。
6. **全流程日志追踪**：更新检查、版本比对、下载进度、哈希校验、启动安装等全生命周期写入本地 `logs/` 目录，便于排障追溯。
7. **自动化巡检验证**：提供专用的验证工具，不仅本地校验，还可端到端远程验证 `updates.json` 及所引用的所有平台安装包和镜像是否 100% 存在且内容无损。

---

## 2. 服务端设计

### 2.1 存储结构

复用现有 R2 存储桶与加速域名 `https://jigsawdata.umao.top/`，在 `app/` 目录下扁平组织：

```text
r2:jigsaw-data/app/
├─ updates.json                              ← 唯一更新清单入口（CDN Bypass Cache）
└─ <version>+<versionCode>/<platform>/       ← 安装包（版本化不可变路径）
   ├─ android/app-release.apk
    └─ windows/JigsawFox-<version>-windows-x64.zip  ← 绿色便携更新包（含 updater.exe）
```

- 安装包文件名带版本号，文件内容不可变，CDN 可长缓存；
- `updates.json` 享受已有 Cloudflare `.json` Bypass Cache 规则，秒级生效。

### 2.2 清单结构（极简扁平）

```json
{
  "schema": 1,
  "version": "1.0.1",
  "versionCode": 2,
  "minVersionCode": 1,
  "notes": {
    "zh-CN": "修复若干已知问题，提升游戏流畅度",
    "en-US": "Bug fixes and performance improvements"
  },
  "publishedAt": "2026-09-14T15:00:00+08:00",
  "platforms": {
    "android": {
      "arm64-v8a": {
        "url": "app/1.0.1+2/android/JigsawFox-1.0.1-arm64-v8a.apk",
        "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "size": 20428800
      },
      "all": {
        "url": "app/1.0.1+2/android/JigsawFox-1.0.1-all.apk",
        "sha256": "f3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "size": 52428800
      }
    },
    "windows": {
      "url": "app/1.0.1+2/windows/JigsawFox-1.0.1-windows-x64.zip",
      "sha256": "c8932906e5797371946059b02a2811a2f6deca7f9754f7626992d4750e303bc3",
      "size": 78643200,
      "mirrors": [
        "https://github.com/mcxiaoke/jigsaw-fox/releases/download/v1.0.1/JigsawFox-1.0.1-windows-x64.zip"
      ]
    }
  }
}
```

字段说明：
- `version` / `versionCode`：从 `pubspec.yaml` 自动提取，以整数 `versionCode` 作为单调递增比较基准。
- `minVersionCode`：强制更新水位线。当前客户端 `versionCode < minVersionCode` 时，必须更新才可继续游玩。
- `platforms.*.url`：R2 主源相对路径，客户端自动与 Base URL 拼接。
- `platforms.*.mirrors`：备用镜像绝对地址数组，主源不可用或下载失败时自动按序重试。
- `sha256` / `size`：强校验哈希值与字节数。

---

## 3. 发布与远程校验体系（`scripts/publish/release_app.py`）

单脚本管理发版与巡检，支持三个核心子命令：

```text
prepare  → 构建 APK 与 Windows 安装包，从 pubspec.yaml 提取元数据并生成本地 updates.json 与哈希
verify   → 完整性硬校验门禁（支持 --local 与 --remote）
publish  → 安全时序发布上云（附件先行，清单收尾）
```

### 3.1 完整性验证机制（Verify）

为了确保线上清单准确无误且引用的安装包完好无损，提供两级巡检：

1. **本地校验 (`verify --local`)**：
   - 检查本地构建产物是否存在；
   - 本地重新计算文件 SHA256 和 Size，与 `updates.json` 比对一致；
   - 读取线上当前 `updates.json`，校验本地 `versionCode` 必须严格递增；
   - 本地 APK 深度校验：校验 APK 签名有效性（`apksigner verify`）与清单元数据（`aapt dump badging` 提取 `versionCode`、`versionName`、`package`）。
2. **远程全链路深度巡检与验签 (`verify --remote`)**：
   - 从 `https://jigsawdata.umao.top/app/updates.json` 拉取最新清单；
   - 验证 JSON Schema 合法性与字段完整性；
   - 遍历各平台的 `url`（主源）及所有 `mirrors`（备源）：
     - 发起 HTTP 请求探测连通性（必须返回 200 OK）；
     - 流式下载并实时计算远程文件的 SHA256 与 Size；
     - 校验实际计算值与清单中声明的 `sha256` / `size` 100% 吻合；
     - **下载后二进制真实验签与版本比对**：将远端下载的安装包在临时目录进行校验，针对 APK 调用 `apksigner verify` 验证签名未被篡改破坏，调用 `aapt` 提取并确认其真实的 `versionCode` 与目标版本完全一致；
   - 任何一个文件 404、超时、哈希不符、签名损坏或版本不一致，立即报错中断并记录详细告警。

### 3.2 发版执行时序 (`publish`)

发版必须严格遵循以下安全时序闭环：

```text
Step 1: 本地 pre-flight 深度门禁（verify --local，校验构建产物、哈希、签名有效性、版本递增）
Step 2: rclone copy 上传安装包到 R2 桶对应版本目录
Step 3: 上传安装包到 GitHub / Gitee Releases 作为备用镜像
Step 4: 从远端真实下载各平台安装包，再次校验远端文件的 SHA256、大小，并对远端 APK 校验签名与 versionCode
Step 5: 远端二进制深度校验全部通过后，最后才上传 updates.json 切生效
Step 6: 执行 verify --remote 进行线上终检，输出完整巡检报告
```

---

## 4. 客户端实现规范

在 `lib/update/` 目录下实现轻量自更新模块：

```text
lib/update/
├─ update_service.dart          ← 检查、下载（主备源回退）、哈希校验、状态流
├─ update_models.dart           ← updates.json 数据模型
├─ update_installer.dart        ← 平台安装器分发（Windows / Android）
└─ widgets/update_dialog.dart   ← 响应式更新对话框（说明、进度、强制更新逻辑）
```

### 4.1 检查策略与防打扰体验

- **启动自动检查**：
  - App 启动延迟 3~5 秒触发静默检查，不阻塞主流程；
  - 若遇网络超时、解析异常等，**一律静默吞掉**，仅在本地日志记录 WARNING，严禁弹错误窗打扰用户；
  - 若有新版本但属于非强制更新，且用户此前点击过“忽略此版本”（存储在本地 SharedPreferences），本次启动不弹窗。
- **手动检查更新（设置页）**：
  - 用户主动点击“检查更新”，展示加载状态；
  - 若已是最新，Toast 提示“已是最新版本”；
  - 若检查失败，友好提示“检查更新失败，请检查网络”。
- **强制更新（`currentVersionCode < minVersionCode`）**：
  - 对话框隐藏“取消 / 稍后提醒 / 忽略”按钮，用户必须下载更新后方可继续。

### 4.2 平台安装落地方案（重点规避隐患）

#### A. Windows 平台：通用极简 updater-rs 原地自更新方案（纯绿色便携免安装）
- 采用通用独立更新器 `updater.exe`（单文件原生 Rust 编译，仅 ~366KB，无外部依赖，位于 `tools/windows/updater.exe`）；
- 核心优势：保持应用纯绿色免安装便携特性，免去 Inno Setup 频繁弹窗安装向导，主程序静默拉起更新器后退出，更新器原子替换后自动拉起新版；
- 运行机制与黄金法则：
  1. **自更新支持**：主程序启动时将 `updater.exe` 复制到临时目录 `%TEMP%\jigsawfox_updater\updater.exe` 执行，使得安装根目录下的 `updater.exe` 自身也能随更新包自更新；
  2. **分离进程启动**：以 `ProcessStartMode.detached` 模式拉起更新器，主程序立即调用 `exit(0)`，释放文件句柄；
  3. **内核级句柄绑定等待**：更新器传入 `--pid $pid`，使用 Win32 原生 `OpenProcess(SYNCHRONIZE)` 彻底等待旧进程内核对象释放，免疫 PID 复用；
  4. **Win32 原子替换与内存回滚栈**：使用 `ReplaceFileW` 逐个文件原子备份替换；遇到杀软占用自动重试（20次 × 500ms）；异常时自动逆序回滚旧文件并重新拉起旧版；
  5. **原生 GUI 与双语自适应**：传入 `--gui` 参数，自动识别系统 UI 语言（`zh-CN` 显示中文，其余显示英文），独立 UI 线程保证跑马灯与百分比绝不假死；
  6. **保护清单 (.updatekeep)**：根目录下配置 `.updatekeep`，保护 `logs/` 与临时数据不被更新包抹除。

#### B. Android 平台：规范化 APK 安装流程（支持分 ABI 智能匹配）
- 架构智能匹配：客户端使用 `device_info_plus` 读取 `Build.SUPPORTED_ABIS` 列表，优先请求 `arm64-v8a` / `armeabi-v7a` 等专属包（体积缩减 60%+），自动回退 `all` 通用包；
- 权限声明：`AndroidManifest.xml` 中声明 `REQUEST_INSTALL_PACKAGES`；
- 安全路径映射：配置 `androidx.core.content.FileProvider`，杜绝 `FileUriExposedException`；
- 下载完成后校验 SHA256，调用 `open_filex` 拉起系统原生安装界面；若系统未授权“允许来自此来源的应用”，引导用户开启。

---

## 5. 日志与追溯机制

所有更新相关事件必须记录到本地日志系统，集成至现有的 `AppLogger`：

1. **统一 Logger 节点**：
   - 在 `AppLogger` 中增加 `static final Logger update = Logger('App.Update');`；
   - 自动随主应用日志落盘到 `appSupportDir/logs/app_YYYYMMDD.log`，并在应用内置的“日志查看器”中可见。
2. **记录规范（必须包含结构化信息）**：
   - **检查阶段**：触发源（auto/manual）、当前版本（`v1.0.0+1`）、请求地址、返回状态；
   - **比对阶段**：远端版本（`v1.0.1+2`）、minVersionCode、是否需要更新、是否强制更新；
   - **下载阶段**：目标保存路径、主源/备源尝试记录、下载字节数、百分比；
   - **校验阶段**：实际计算 SHA256 vs 预期 SHA256、文件大小对比、校验耗时、是否通过；
   - **安装阶段**：拉起安装命令/Intent、退出主程序状态；
   - **异常阶段**：网络异常、404、哈希不匹配、权限拒绝等完整堆栈。

---

## 6. 回滚方案

若线上发版后发现严重故障，回滚步骤极简：
1. 取出上一个稳定版本的安装包元数据；
2. 保持上一个稳定版本的安装包不变，仅将其 `versionCode` 增加为大于当前故障版本的数字；
3. 将修改后的 `updates.json` 上传至 R2，已装故障版本的客户端将在几分钟内自动拉取并降级覆盖回稳定版本。
