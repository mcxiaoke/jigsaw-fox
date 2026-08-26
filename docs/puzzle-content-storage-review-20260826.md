# 内容存储与扩展包方案 · 评审与简化建议

> 评审对象：`docs/puzzle-content-storage-and-expansion-design.md`（2026-08-24）
> 评审日期：2026-08-26
> 结论：**方案整体方向合理（四层内容源分类），但实现细节严重过度设计，应按「图片即关卡」原则大幅简化。**

---

## 1. 一句话结论

对拼图游戏而言，**一张图片就是一个关卡**。文档把三类东西错误地混进了刚性文件结构：

| 类别 | 例子 | 应放在哪 |
| :--- | :--- | :--- |
| **可从图片推导** | `aspectRatio`、`imageWidth`、`imageHeight` | 加载时解码计算，**不要存** |
| **玩家个人运行时进度** | `completedPieceCounts`、`bestTimeMs`、`updatedAt` | 独立的进度存储，按 `(packId, levelId)` 索引，**绝不进分发包** |
| **可选展示糖** | `author`、`location`、`title`、`tags`、`thumb` | 包级可选 `pack.json`，缩略图现算 |

你的判断成立：**导入关卡包不需要复杂元数据，有图片就够了。** 下方给出逐条问题与「图片优先」的最小方案。

---

## 2. 现状代码对照（证明简化可行）

| 文档假设 | 代码真实情况 | 证据 |
| :--- | :--- | :--- |
| UGC 需 `items/ugc_xxx/ + meta.json + index.json` | 图片平铺为 `custom_puzzles/puzzle_<ts>.png`，元数据存 SharedPreferences | `crop_puzzle_page.dart:307-314`、`game_repository.dart:177-223` |
| 比例需显式声明 | 已有 `PuzzleAspectRatio.fromSize(width, height)` 从尺寸推导 | `puzzle_model.dart:32` |
| 导入时要解析元数据 | `DownloadManager` 导入即解码拿到 `width/height` | `download_manager.dart:94-98` |
| 「5 大标准比例正方形切片」 | 实际支持 1:1 / 2:3 / 3:2 / 3:4 / 4:3 共 **5 种宽高比**，不全是正方形 | `crop_puzzle_page.dart:17-21`、`puzzle_model.dart:16-168` |
| 每日挑战需重型云端管线 | 当前是硬编码 31 天 `kBingDaily30Days`，无 Manifest/SHA256/CDN | `bing_daily_data.dart:30-73` |

→ 关键推论：**推导元数据的能力代码里已经有了，文档却反过来要求把推导结果存进文件**，既冗余又会漂移。

---

## 3. 逐条问题清单

### P1 ·（正确性）关卡内容元数据与玩家进度混在一起 —— 严重
`meta.json`（文档 3.2）包含 `completedPieceCounts`、`bestTimeMs`、`updatedAt`。这些是**每个玩家各自的运行时进度**，不应出现在分发给所有用户的包里。否则每个下载者都带着空/他人进度，导入时还得剥离重置。
**修法**：进度单独存储，如 `progress/<packId>/<levelId>.json` 或单个 `progress.json` 按 id 索引，与包内容彻底分离。

### P2 ·（冗余）可推导字段被显式存储 —— 中
- `aspectRatio` / `imageWidth` / `imageHeight`：100% 可推导（见 §2 证据），存储会漂移。
- `defaultRows` / `defaultCols`：进入对局会弹 `ChooseDifficultySheet` 让用户选难度（文档 5.3），存进去的默认值只是「建议」。可改为全局默认（4×4）或包级可选 hint，**不必逐关存**。

### P3 ·（过度）UGC 的 index.json + 灾备重建 —— 中
文档 3.3 设计 `index.json` 并「后台扫描 meta.json 重建」。但若关卡就是一个图片文件夹，文件系统本身就是索引，没有易损的索引可损坏。**删掉 index.json**，列表由扫描图片文件得到（拿到尺寸本就要读图）。所谓「灾备」是在解决 index 自己制造的问题。

### P4 ·（过度）`.jpk` 包内每层 meta.json + thumb.webp —— 中高（最大简化点）
文档 5.1 每层放 `image.webp` + `thumb.webp` + `meta.json`：
- `meta.json` 逐关：无用（见 P1/P2）。
- `thumb.webp`：不需要。缩略图在展示/安装时由原图现算一次即可，预存会翻倍资源且易过期。
→ 见 §5 的最小包结构，20 关包从 60 个文件降到 20 个。

### P5 ·（重型/过早）每日挑战云端管线 —— 中
文档 4.2 的月度 Manifest 带 `imageSha256`、`fileSize`、`author`、`location`、`mirrorUrls`、`baseUrl`，4.3 再加 ETag / If-Modified-Since 三级缓存。对休闲每日挑战：
- 你真正只需要：`date → imageUrl`（+ 可选 `title`）。
- SHA256 逐图：仅当担心自有 CDN 被篡改才有意义，个人项目可选；若保留也不必逐图写在 Manifest。
- `mirrorUrls` / ETag / IMS：原生 HTTP 已缓存。取 JSON 后用「lastFetched + 过期窗口」即可，无需自建 CDN 缓存层。

### P6 ·（范围蔓延）完整 DLC 商店 + 下载管理器 + 磁盘管理 + 镜像 —— 中
文档设计了下载进度条、断点续传、一键清理、镜像 CDN。对个人/爱好项目属过早。更轻的路径：包要么是用户从「文件/分享」导入的 zip，要么是一份极小的「包下载 URL 列表」JSON。复用现有 `DownloadManager` 模式，不做应用内商店。

### P7 ·（事实错误）「正方形切片」前提不成立 —— 低中
文档多处称「5 大标准比例正方形切片」（37、315 行），但代码支持 5 种**宽高比**，含竖屏/横屏非正方形。把「正方形」写死到设计里是错的；按 P2 从图片真实比例驱动后此问题自然消失。

### P8 ·（偏重）内置关卡 Manifest 也可瘦身 —— 低
`levels_manifest.json` 逐关写 `aspectRatio`/`defaultRows`/`defaultCols` 属多余。保留轻量清单即可：`id` + `assetPath` + `title`（标题可选）。甚至可「分类文件夹 + 文件名即 id」，标题缺失时回退文件名。

---

## 4. 核心原则：图片即关卡

> **一个图片文件 = 一个关卡。**
> 关卡 id = 文件名（去扩展名）。
> 标题 = 文件名，或包内可选映射。
> 难度 = 进入对局时用户自选；包可选给默认建议。
> 进度 = 与包分离的独立存储。
> 缩略图 = 展示时现算并缓存。

---

## 5. 简化方案（最小可行）

### 5.1 关卡扩展包（.jpk 或普通文件夹）—— 图片优先
```
mypack.jpk (zip)
├── pack.json          # 可选：{ "name", "description", "author", "tags" }
└── images/
    ├── 01.webp
    ├── 02.webp
    └── ...
```
- 一张图 = 一关，id = 文件名。
- 导入时：解压 → 读 `images/*` → 逐张解码取宽高 → `fromSize` 推导比例 → 校验最小分辨率（复用 `DownloadManager` 逻辑）→ 缩略图随用随算并缓存。
- **无逐关 json、无逐关 thumb。**

### 5.2 UGC —— 与现状一致即可
```
custom_puzzles/
├── puzzle_1693123456789.png     # 原图
└── puzzle_1693123999999.png
```
进度存别处（SharedPreferences 或 `progress.json`），不进图片旁文件。当前「平铺 PNG + SharedPreferences」其实比文档提案更简单，无需改成沙盒包。

### 5.3 每日挑战 —— 极简清单
```json
// daily/2026-08.json
[{ "date": "2026-08-24", "imageUrl": "https://.../2026-08-24.webp", "title": "可选" }]
```
客户端：拉 JSON → 按 `lastFetched + 过期窗口` 缓存 → 图片按 date 缓存字节。无 SHA256 / fileSize / author / mirrorUrls / ETag。

### 5.4 进度存储（与内容分离）
```
progress/
└── per_user_progress.json
   { "mypack:01": { "completedPieces": [...], "bestTimeMs": 83000 },
     "ugc:puzzle_1693...": { ... } }
```

---

## 6. 量化对比

| 维度 | 原文档 | 简化后 | 收益 |
| :--- | :--- | :--- | :--- |
| 每关文件数 | 3（image+thumb+meta） | 1（image） | 20 关包 60→20 文件（−67%） |
| 每关必填元数据 | ≈14 字段 | 0（标题可选） | 无漂移、无冗余 |
| 进度与内容耦合 | 混在 meta.json | 完全分离 | 正确性修复 |
| UGC 索引机制 | index.json + 灾备扫描 | 直接扫文件夹 | 删一类易损文件 |
| 每日挑战 Manifest | 含 sha256/fileSize/author/location/mirrorUrls | date+url(+title) | 负载降一个数量级 |
| 扩展包交付 | 应用内 DLC 商店 + 镜像 CDN | 导入 zip 或 URL 列表 | 范围砍掉大半 |

---

## 7. 实施建议（重排阶段）

| 阶段 | 建议内容 | 与原文档差异 |
| :--- | :--- | :--- |
| 一 | 内置资源按分类分目录 + 轻量清单（id/path/title） | 砍掉 aspectRatio/难度字段 |
| 二 | UGC 维持「平铺图 + 进度分离」，不引入沙盒包/index.json | 比文档更简 |
| 三 | 每日挑战：极简 JSON + 简单 HTTP 缓存 | 砍 SHA256/镜像/三级缓存 |
| 四（按需/可砍） | 扩展包：导入 zip（图片+可选 pack.json），无商店 | 商店与镜像降为 stretch goal |

---

## 8. 对原文档的修改建议

1. **把「玩家进度」从所有 `meta.json` 定义中删除**，单开一节讲进度存储。
2. **删除每关 `aspectRatio/imageWidth/imageHeight/defaultRows/defaultCols`**，改为「加载时从图片推导」。
3. **`.jpk` 结构改为 `pack.json(可选) + images/*`**，去掉 `levels/NN/meta.json` 与 `thumb.webp`。
4. **UGC 删除 index.json**，用文件夹扫描。
5. **每日挑战 Manifest 瘦身**到 `date/url/title`。
6. **DLC 商店与镜像 CDN 降为「可选后续」**，非阶段一/二必做。
7. 修正「正方形切片」表述为「按图片真实比例驱动」。

> 若认可，可整篇重写为「内容模型 v2（图片优先）」，按你偏好整体重写的习惯替换本方案。



总体判断
方案方向是对的（内容驱动、可扩展、UGC + 扩展包），但复杂度与收益严重不成正比，偏离了 PRD 定的「轻量单机沙盒优先」定位。核心问题正如你所怀疑的：它把"内容 == 一张图 + 一个难度"的拼图游戏，设计成了"内容分发平台"。

根本原则应该是：图片即关卡，元数据只记录"图片本身推导不出来"的信息。方案把大量可由图片推导、或单机根本用不上的东西，都写死成了 schema。

一、可直接去掉的（图片/系统能推导）
aspectRatio / defaultRows / defaultCols（§2.2、§3.2、§4.2 反复出现） 代码里已有 PuzzleAspectRatio.fromSize(w,h) 和 adaptiveForSize()——比例由图片像素动态算出，档位按推荐块数查表即可。存这些字段是重复劳动，还容易和图片实际尺寸漂移不一致。
thumb.webp 缩略图字节（§3.1、§5.1） 本地/UGC 图片直接用原图 BoxFit.cover 渲染，首次打开按需生成内存缓存即可。为每张图物理存第二份 jpg/webp，纯属浪费空间与同步负担。
index.json 双保险 + 灾备重建（§3.3） custom_puzzles/index.json + items/ugc_xxx/ + thumb + 目录扫描重建——对一个"遍历目录读图片"就能解决的问题，套了三层保险。Flutter 端 Directory.list() 即可。
云端每日的三级缓存 + sha256 + ETag/If-Modified-Since + mirrorUrls 镜像链（§4.2/§4.3） 诉求只是"每天多一张图"。三份副本、校验和、镜像源，是十倍工作量换边缘体验。已实现的「内置 30 天本地集 + 坏档 Fallback」已提供离线可用。
作者/location/sourceFileName/userTags/levelsCount 等展示字段（多个 manifest） 低频、纯展示，割裂进多个 schema；用"一个可选 JSON 里加一两个字段"即可，不该成为结构必需。
二、需要但应"收窄成一条记录"
内置关卡：目录 = 分类（已是现实），每条只记 id / title / 作者? / 默认块数? ——甚至用规范文件名承载标题，连 JSON 都可省。
UGC：任意目录里任一图片 = 一个关卡；只需一条记录（id, 来源 sourceUrl, 已通难度, 最佳用时）存 SharedPreferences。已实现就是扁平 custom_*.png，够用。
每日挑战：内置 30 天本地集即可；将来真要云端，一个 日期 → URL 的简单列表就够，不需要 manifest 分层。
关卡包（DLC）：一个 zip/目录里放规范命名的图片，比例自动算；pack 只需 名称 + 封面(=首图) + 图片列表 一条。per-level meta.json、cover.webp、icon.webp 全可省（用首图当封面）。你说得对，拼图关卡有图片就够了。
三、明确保留/延后的合理性项
保留（已在实现、确有必要）：关卡来源追踪 sourceType/sourceUrl、多难度独立通关记录、按类别分目录。

延后为 P4 规划、不写进当前架构（避免误导读者以为已实现，正与你上次在文档加的"方案状态说明"呼应）：云端每日、DLC 商店 UI、首页折叠手风琴（现在的"分类筛选胶囊 + 瀑布流"更好，无需改）。

四、建议的极简形态

Plain Text

assets/images/levels/{category}/*.webp     # 内置：目录=分类
custom_puzzles/<id>.png                    # UGC：一图一关（附来源+进度一条）
daily/                                     # 每日：内置本地集（可选 URL 列表）
packs/<packId>/01.webp …                   # 关卡包：一个含规范命名图片的目录/zip
派生态全部运行期计算：比例=fromSize、缩略图=原图缩放、档位=默认块数查表。新增内容 = 丢一张图进去，零 schema 升级。


一、核心问题：大量字段可以推导，不需要存储
拼图游戏的特殊性在于：一张图片就是一个完整关卡。对照现有代码，方案里的很多字段根本不用存：
方案中存储的字段	实际来源
aspectRatio	图片宽高即可判定，PuzzleAspectRatio.fromSize() 已存在 (lib/logic/puzzle_model.dart:32)
defaultRows / defaultCols	用户反正要在 ChooseDifficultySheet 选难度；还有 adaptiveForSize 可自动推荐
thumb.webp 缩略图	解码时用 cacheWidth/ResizeImage 即可，零额外文件、零生成管线
关卡顺序	目录内文件名排序天然有序
包封面/图标	取第一张图即可
真正需要存的只有三类：身份（id/路径）、展示（标题，可选）、进度（通关状态——这属于游戏存档，不属于内容元数据）。而进度你们已经有成熟的 SharedPreferences 存储模式了。
二、分节具体问题
§2 内置关卡 Manifest —— 半冗余
- categories.levelsCount 要和 levels[] 手工同步，必然腐烂。应派生或用脚本生成。
- 每关的 aspectRatio/defaultRows/defaultCols 同上，纯冗余。
- 更激进的做法：Flutter 的 AssetManifest 可以运行时枚举 assets 目录内容，配合“每分类一目录”的约定，连 JSON 都可以不要。
- 但要注意现实：当前 100 关只是 10 张图循环复用（game_repository.dart:90）。在真实美术资源落地前，这套 manifest 的收益接近零。
§3 UGC 沙盒包 —— 自己制造问题再解决它
这是全文最明显的过度设计：
- index.json + “自动灾备重建”是自找的复杂度：没有索引文件就不存在索引损坏，直接扫目录就行（UGC 数量级撑死几百个，全扫毫秒级）。“毫秒级瞬时启动”是伪需求——现在 SharedPreferences 加载本来就快。
- 把可变的游戏进度（bestTimeMs、completedPieceCounts）塞进静态 meta.json 是职责混淆：频繁重写元数据文件反而增加损坏风险。
- 建议形态：保持扁平目录，文件名即 id（现在的 puzzle_<millis>.png 就挺好），标题等可选信息留在现有的 jigsaw_custom_list 里。导出分享 = 发图片文件，导入 = 拷贝进来——比沙盒包方案的“打包导出底层准备”简单一个数量级，功能还更直白。
§4 每日挑战云端分发 —— 方向对，细节过度
静态托管 + 无后端是对的，这部分保留。但：
- 逐图 sha256 校验可砍：HTTPS 已保证传输完整性，ETag 已保证版本一致性。为几百 KB 的 webp 做哈希校验是给自建 CDN 时代留的设计。
- mirrorUrls 不该放数据里：镜像降级是客户端策略，写死在代码里即可。
- fallbackAsset 耦合奇怪：每日挑战失败回退到“精选第4关”？离线时显示“今日不可用 + 使用缓存”就够了。
- 月度分文件（2026/08.json）引入了跨月边界逻辑，一年一个 append-only 的总 manifest 也才百来 KB，更简单。
- ⚠️ 未提版权：Bing 壁纸/Unsplash 图重新分发到自己的 CDN 有许可风险，这比技术问题更容易致命。
§5 .jpk 扩展包 —— 正是你说的那个问题
levels/01/{image.webp, thumb.webp, meta.json}
每个关卡三件套完全没有必要。简化成：
cyberpunk_city.jpk (zip)
├── pack.json        # 仅 {name, description}，甚至可以不要
└── 01.webp ... 20.webp
导入流程：解压 → 枚举图片 → 完事。比例检测、难度选择全部复用现有运行时逻辑。Zip 本身就是容器格式，自定义扩展名 .jpk 只影响文件关联，无所谓但也不加分。另外 download_manager.dart 已经有完整的下载+缓存+元数据管理基建，方案完全没提复用。
§6 路线图缺失项
- 没有数据迁移方案：文档开头自己承认与现状有差异，但四个阶段都没提 SharedPreferences → 新结构的迁移与向后兼容。
- 首页手风琴改版混进了“存储架构”文档，属于 UI 范畴，应拆出去。
三、总结
模块	判定	建议
统一内容源抽象	✅ 合理	与现有 GameRepository 演进方向一致
每日挑战静态托管	✅ 合理	砍掉逐图哈希/镜像字段/月度分片，补版权说明
内置关卡 manifest	🟡 收益存疑	等真实素材到位再做，且要瘦身+脚本化生成
UGC 沙盒包+双索引	❌ 过度设计	维持扁平目录+SP 元数据，图片即关卡
.jpk 三件套	❌ 过度设计	纯图片 zip，元数据只留包名简介
首页手风琴	➖ 无关	从本文档移除
一句话原则：元数据的唯一合法来源是“无法从图片本身推导的信息”。按这个标准过滤，这份文档能砍掉一半的实现工作量。
