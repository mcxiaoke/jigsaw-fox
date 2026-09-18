# F-Droid 发布指南（Flutter 项目）

> 适用项目：拼图游戏 Flutter 项目
> 整理日期：2026-09-17
> 依据来源：F-Droid 官方收录政策（Inclusion Policy）、提交快速入门指南（Submitting to F-Droid Quick Start Guide）、收录操作指南（Inclusion How-To）、开发者 FAQ

---

## 一、收录政策（硬性要求）

F-Droid 是自由开源软件（FOSS）商店，所有应用必须满足以下条件：

### 1. 核心要求

1. **完全 FOSS**：整个应用（包括所有库和依赖）都必须是自由软件，且只能用 FLOSS 工具构建。最常见的拒收原因就是存在非自由依赖。
2. **不能用这些组件**：
   - Google Play Services / Firebase / GMS（可用 microG 或直接删除非自由依赖替代）
   - Crashlytics 等专有崩溃/统计 SDK（可用 ACRA 等替代）
   - 专有广告 SDK（允许广告，但必须以 FLOSS 方式实现，且会被打上 AntiFeature 标记）
   - Oracle JDK 等非自由构建工具
3. **源码托管**：代码必须放在公开可访问的 git/hg/svn/bzr 仓库中，并保持最新状态。
4. **不下载额外可执行二进制**：应用运行时不得下载插件、自动更新等可执行文件。
5. **唯一包 ID**：applicationId 必须唯一；fork 别人的应用必须更换包名。
6. **许可证**：仓库根目录要有 LICENSE 文件；美术等"非功能性资产"（对拼图游戏尤其相关——内置图片素材）可以采用比代码宽松的许可，但必须在某种许可下且不侵权，否则会被标记 `NonFreeAssets`。
7. **版本要有 tag**：每个 release commit 应打版本标签（如 `v1.0`），且 versionName/versionCode 保持一致。
8. **联网行为需用户授权**：崩溃报告、更新检查等行为必须用户 opt-in 且默认关闭，否则标记 `Tracking`。

### 2. AntiFeatures（负面特征）

即使应用本身合规，以下行为也会被打上负面特征标记（用户可过滤）：
广告、跟踪、非自由依赖、非自由资产、非自由网络服务、NSFW 等。发布前应自查，能避免的尽量避免。

---

## 二、提交方式（二选一）

| 方式 | 适合人群 | 特点 |
|---|---|---|
| **GitLab Submission Queue**（提交队列） | 新手 | 在 F-Droid 的 GitLab 上提交 issue，由维护者帮忙写元数据；最简单但最慢 |
| **Metadata Merge Request**（自己写元数据） | 熟悉 Git/构建流程 | fork `fdroiddata` 仓库，自己写 `metadata/<包名>.yml` 并提 MR；审核最快 |

推荐有一定构建经验时走 Metadata MR 路线。

---

## 三、Flutter 项目的具体做法

F-Droid 构建服务器对 Flutter 有官方模板支持，`fdroiddata` 仓库里有大量 Flutter 应用的现成元数据可以参考（官方指南明确建议：如果是 Flutter 应用，在 fdroiddata 里搜同类应用的 metadata 作模板）。

### 1. 元数据文件示例（`metadata/com.example.xxx.yml`）

Flutter 应用的典型 Build 块：

```yaml
Builds:
  - versionName: 1.0.0
    versionCode: 1
    commit: v1.0.0
    output: build/app/outputs/flutter-apk/app-release.apk
    srclibs:
      - flutter@<你的Flutter版本号>   # 例如 v3.24.3，构建服务器会用它安装 Flutter SDK
    build:
      - $$flutter$$/bin/flutter config --no-analytics
      - $$flutter$$/bin/flutter build apk
```

关键点：
- 用 `srclibs` 声明 Flutter 引擎版本，F-Droid 会从源码构建（Flutter 本身是 FOSS，可以构建）。
- 完整描述字段还需包含 `Categories`、`License`、`SourceCode`、`RepoType`、`Repo`、`AutoUpdateMode`、`UpdateCheckMode`、`CurrentVersion`、`CurrentVersionCode` 等。

### 2. 本地验证

克隆 fdroiddata + fdroidserver，在官方 Docker 容器中验证：

```bash
git clone --depth=1 https://gitlab.com/fdroid/fdroiddata ~/fdroiddata
git clone --depth=1 https://gitlab.com/fdroid/fdroidserver ~/fdroidserver
docker run --rm -it -u vagrant --entrypoint /bin/bash \
  -v ~/fdroiddata:/build:z \
  -v ~/fdroidserver:/home/vagrant/fdroidserver:Z \
  registry.gitlab.com/fdroid/fdroidserver:buildserver
# 容器内：
. /etc/profile
cd /build
fdroid readmeta
fdroid rewritemeta com.example.xxx
fdroid lint com.example.xxx
fdroid build com.example.xxx
```

全部通过后再提 MR。

### 3. 自动更新配置

```yaml
AutoUpdateMode: Version
UpdateCheckMode: Tags
```

配置后每次发布只需 bump 版本 + 打 tag 推送，F-Droid 会自动检测并构建新版本。

### 4. 注意事项

- F-Droid 只收 **APK**，不收 AAB。
- 如需 ABI split 减小体积，要为每个 ABI 写独立 build 块并编排 versionCode（顺序：armeabi-v7a < arm64-v8a < x86 < x86_64）。
- F-Droid 的更新检查只做正则提取，不会运行 Gradle/Dart 代码，versionName/versionCode 不能动态计算。

---

## 四、仓库内要准备的元数据（Fastlane/Triple-T 结构）

放在自己的源码仓库里，描述/截图由 F-Droid 自动拉取：

```
fastlane/metadata/android/
├── en-US/
│   ├── short_description.txt    # 30–50 字符，无结尾句号
│   ├── full_description.txt
│   ├── images/icon.png
│   ├── images/phoneScreenshots/1.png ...
│   └── changelogs/
│       └── 123.txt              # 以 versionCode 命名，≤500 字符
└── zh-CN/                       # 建议同时提供中文
```

---

## 五、关于签名（重要，提前规划）

- **默认流程**：上架官方仓库的 APK 由 **F-Droid 用它自己生成的密钥签名**，与开发者自己发布的签名不同。用户从 Google Play 切到 F-Droid 需要卸载重装（丢数据）。
- **可复现构建（Reproducible Builds，推荐新应用一开始就做）**：
  - 如果开发者构建与 F-Droid 构建结果比特级一致，F-Droid 会直接发布开发者签名的 APK。
  - 一旦先用了"自定义签名渠道"，之后想切换很麻烦（Android 不允许不同签名密钥互相升级），所以要尽早决定。
  - 需要在元数据里配置 `Binaries`（指向官方发布的 APK）和 `AllowedAPKSigningKeys`（证书指纹）。
  - Flutter 项目做可复现构建最难的部分是对构建做标准化（固定 Flutter/Gradle/JDK 版本等）。

---

## 六、流程时间线

1. 自查合规（依赖、许可证、素材）→ 在仓库中加 fastlane 元数据、打版本 tag
2. 准备元数据 yml（或提交到 Submission Queue）
3. 本地容器中验证构建通过
4. 向 `fdroiddata` 提 MR，打 "New App" 标签，回复审核问题
5. 审核通过合并后，构建服务器每天批量构建，通常 **24–48 小时**内上架；再过一天才会出现在"最新应用"列表

---

## 七、本项目发布前检查清单

- [ ] `pubspec.yaml` 所有依赖无专有组件（尤其广告、推送、分析类插件）
- [ ] `android/app/build.gradle` 的 applicationId 唯一、无 Play Services 依赖
- [ ] 选择 FOSS 许可证（如 GPL-3.0 / Apache-2.0），LICENSE 放仓库根目录
- [ ] 游戏内图片素材的版权与许可声明写清楚
- [ ] Android 版本 tag 规范（`v1.0.0` 等）、versionName/versionCode 一致
- [ ] `fastlane/metadata/android/` 准备 zh-CN + en-US 的描述和截图
- [ ] 先决定是否走可复现构建路线（建议一开始就走，避免日后换签名）
- [ ] 只产出 APK，不依赖 AAB / Play App Signing

---

## 八、参考链接

- 收录政策：https://f-droid.org/en/docs/Inclusion_Policy/
- 提交快速入门指南：https://f-droid.org/en/docs/Submitting_to_F-Droid_Quick_Start_Guide/
- 收录操作指南：https://f-droid.org/en/docs/Inclusion_How-To/
- 构建元数据参考：https://f-droid.org/docs/Build_Metadata_Reference/
- 描述、图片与截图规范：https://f-droid.org/en/docs/All_About_Descriptions_Graphics_and_Screenshots/
- 开发者 FAQ：https://f-droid.org/en/docs/FAQ_-_App_Developers/
- fdroiddata 仓库：https://gitlab.com/fdroid/fdroiddata

> 时效提示：Google 正在推进 Android 开发者身份验证新政，F-Droid 已公开声明反对，第三方商店与侧载生态未来可能有变数，发行计划周期较长时建议持续关注。
