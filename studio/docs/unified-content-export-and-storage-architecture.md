# Studio 全局内容资产自包含与确定性构建架构规范 (Universal Deterministic Content Architecture)

> **文档版本**：v2.3.0 (Deterministic Pipeline & Explicit ID Contract)  
> **更新日期**：2026-09-05  
> **适用模块**：Main (主线)、Daily (日历)、Events (活动)、Collections (图集)  
> **决策基准**：采纳 Review 3「源侧权威账本 + 确定性纯净构建」、用户决策「方案 B：纯净文件名 + 显式逻辑 ID + Hash 属性化」以及「`srcDir/.studio/` 独立隐藏工作区 + 最终拷贝交付 + 客户端显式 ID 硬约束」  
> ⚠️ **状态：规划 / 未实施**——文中部分端点（如 `/api/export/inspect`、Phase 4 路线图）尚未在 `server.py` 落地。请以 `studio-server-architecture-and-api-20260908.md` + 当前源码为准，避免按图索骥。  

---

## 1. 架构四大核心准则 (The Four Cardinal Principles)

### 准则一：源侧统一私有工作区 (`srcDir/.studio/`)
* **统一工作区收敛**：所有由 Studio 系统生成的元数据、打标、账本、缓存与构建快照，**统一定位并收拢在源素材库根目录下的唯一隐藏子目录 `srcDir/.studio/` 中**；
* **源根目录零杂质**：素材源目录根部纯净至极，外部肉眼可见的**只有摄影师/美工分类整理的高清图片文件夹**；业务打标文件 `tags.json` 亦收归 `.studio/tags.json`（运营在 Web UI 中操作，无需手动编辑原始 JSON）；
* **唯一绝对权威账本**：权威导出账本位于 `srcDir/.studio/ledger/exports.json`（Append-Only，记录原图 SHA-256、原始路径、尺寸、智能裁切参数与分配的关卡/月份/活动）；
* **超级自包含时光机**：整个素材源目录打包拷贝给任何同事、移动硬盘或换电脑，只要带上 `.studio/`，新电脑打开 Studio **瞬间 100% 恢复所有历史状态、打标与防重库**，彻底根除环境迁移导致防重失效的隐患；
* **Scanner（扫描器）严格隔离**：扫描器扫描素材时，严格忽略以 `.` 开头的所有隐藏目录（包括 `.studio/`、`.git/` 等）以及 `temp/`、`tmp/`、`__pycache__/`，物理上绝对不会把内部元数据或生成图片当成素材重复扫描。

### 准则二：两阶段构建与输出端 100% 纯净公开 (Build-to-Release & Copy-to-Out)
* **两阶段发布流水线**：
  $$\text{原始素材} \xrightarrow[\text{暂存与完整性校验}]{\text{.studio/staging/}} \text{.studio/release/ (本地权威不可变镜像)} \xrightarrow[\text{最终交付拷贝}]{\text{shutil.copy2}} \text{用户指定的 outDir}$$
* **输出端（`outDir`）物理零泄露**：
  * 用户指定的导出目录 `outDir` 仅作为**面向公网 CDN 与客户端分发的最终交付目标**；
  * `outDir` 内部 100% 纯净公开，绝对不包含任何私有映射账本、临时文件（`.tmp`）或备份（`.bak`）；
  * 部署发布至生产环境直接退化为零参数极简命令，彻底废弃脆弱且易出错的 `--exclude` 过滤参数：
    ```bash
    rclone sync ./out remote:puzzles-cdn
    ```
    *(注：部署命令严禁使用 `--delete`；孤儿文件清理由独立的 GC 审计命令带人工确认执行。)*
* **灾难级秒级自愈**：若外部 `outDir` 被误删或清空，只要源素材库存在，在 Studio 中点击“重新同步”，系统直接从 `.studio/release/` 毫秒级重新拷贝一份过去，无需重新计算或转码图片；
* **存储策略说明**：现代硬盘容量充沛，多留一份 release 镜像仅占数百 MB，普通标准文件拷贝跨磁盘、跨操作系统绝对兼容可靠。（*备注：同一 NTFS 磁盘分区下，未来可选 hardlink 作为纯性能优化项，首版直接采用标准稳健拷贝*）。

### 准则三：物理纯净命名与稳定逻辑 ID (Clean Filenames & Stable IDs)
* **文件名保持人类可读**：采纳用户拍板的**方案 B**，物理文件名严禁添加 `-hash` 后缀，保持清爽直观（如 `images/0201.webp`、`zips/202609.zip`、`packs/halloween2026.zip`）；
* **Hash 属性化**：原图 SHA-256 与目标文件 SHA-256 仅作为元数据属性存放于 JSON 清单中；
* **显式 ID 契约与防漂移保证**：
  * **清单显式下发 ID**：关卡唯一 Canonical ID（如 `main:201`、`daily:20260901`）由远端 Manifest 清单中显式下发，客户端**无条件以清单显式 `id` 为准**；
  * **彻底杜绝动态反推漂移**：坚决废止由本地图片路径或 URL 反推 ID 的旧有习惯（避免修图补丁 `0201-r2.webp` 错误推导出 `main:0201-r2` 形成孪生关卡，避免本地路径缓存回灌时漂移成 `main:main_201`）；`CanonicalId.fromSource` 仅作为极端缺省或纯离线 UGC 的降级兜底；
  * **游戏进度永久稳定**：逻辑 ID 永久绑定关卡业务序号，玩家的通关存档、碎片进度、星级评定终生不发生漂移；
  * 每日日历内部文件名保持 `20260901.webp`，完美契合客户端正则。

### 准则四：不可变批次与确定性分卷 (Immutable Batches & Deterministic)
* **发布即冻结**：所有生成的分卷清单（`batches/batch_xxx.json`）与图片、ZIP 归档，一旦发布，**终生只读、永不修改**；
* **极速增量与 CDN 强缓存**：
  * 主线按不可变批次（Batches）持续递增；
  * 老客户端检测更新时，仅按差集拉取当次新增的批次 JSON（如 2KB），历史批次永久命中本地与 CDN 强缓存；
  * 避免单体 JSON 随关卡数线性膨胀。

### 准则五：顶层容器键大一统与纯净演进 (Unified Items Key & Zero Legacy Burden)
* **顶层容器键大一统**：全模块清单（Main index、Main batches、Daily index、Events index、Collections index）的列表容器一律强制统一为单一键名 `"items": [...]`，彻底废除双轨键名（`levels`、`batches`、`months`、`events`、`collections`）；
* **开发演进期零兼容负担**：项目处于快速开发演进期，全面清除 `main.json`、`daily.json`、根部平铺散图和旧版 ZIP 等遗留兼容代码，`outDir` 达到 100% 纯净现代拓扑，不背负历史兼容包袱；
* **图片格式与完整性硬拦截**：导出前逐张校验图片格式与完整性（0 字节或 Pillow 解码失败立即硬拦截终止导出）；
* **客户端模型 `url` 与 `localPath` 彻底解耦**：不可变远端网络/相对 `url` 与本地磁盘缓存绝对路径 `localPath` 物理分离，有 `localPath` 读本地，无则读 `url`，`url` 终生不被本地路径篡改覆盖；比对换图严格凭 `hash` 为准。

---

## 2. 统一工作区与输出拓扑布局 (Workspaces & Output Layout)

### 2.1 源素材库私有工作区拓扑 (`srcDir/.studio/`)

```
[用户素材源目录 srcDir]/
├── animals/                            <-- 原始高清素材大图 (只读)
├── landscape/
│
└── .studio/                            <-- 【Studio 私有工作区】(隐藏目录，Scanner 自动忽略)
    ├── tags.json                       <-- 业务打标主文件 (由 Studio 界面写入)
    ├── ledger/
    │   └── exports.json                <-- 唯一权威导出总账本 (Append-Only)
    ├── logs/                           <-- 【操作审计日志】(记录打标变更与导出审计流水)
    │   ├── operations.jsonl            <-- 打标变更流水 (手动打标、批量改标)
    │   └── exports.jsonl               <-- 导出任务审计流水 (批次、模块、版本、目标目录)
    ├── cache/
    │   ├── thumbs/                     <-- 缩略图磁盘缓存 (避免重复 LANCZOS 缩放)
    │   └── hash_cache.json             <-- 文件 SHA-256 快速索引缓存 (秒级比对)
    ├── staging/                        <-- 导出中途的隔离暂存区 (成功后清理)
    └── release/                        <-- 本地构建发布的权威不可变镜像 (Mirror 快照)
        ├── manifest.json
        ├── main/
        ├── daily/
        ├── events/
        └── collections/
```

### 2.2 用户指定导出目录拓扑 (`outDir/`)

由 `.studio/release/` 最终拷贝投影生成，100% 纯净公开，直接交付部署：

```
[用户指定导出目录 outDir]/              <-- 100% 纯净公开，直接发布至 CDN
├── manifest.json                       <-- [公开] 全局总路由网关 (几百字节)
│
├── main/                               <-- 【主线关卡模块】
│   ├── index.json                      <-- [公开] 主线分卷索引指针
│   ├── batches/                        <-- [公开] 不可变批次清单目录 (发布后永不修改)
│   │   ├── batch_001.json              <-- 关卡 101~200 (相对路径引用 ../images/...)
│   │   └── batch_002.json              <-- 关卡 201~230
│   └── images/                         <-- [公开] 关卡 WebP 图片池 (纯数字命名，只追加不覆盖)
│       ├── 0101.webp ~ 0200.webp
│       └── 0201.webp ~ 0230.webp
│
├── daily/                              <-- 【每日挑战模块】
│   ├── index.json                      <-- [公开] 日历月度总索引清单
│   └── zips/                           <-- [公开] 月度归档 ZIP 包 (发布后不可变)
│       ├── 202608.zip                  <-- 31 张图 (ZIP 内为纯日期 20260801.webp 等)
│       └── 202609.zip                  <-- 30 张图
│
├── events/                             <-- 【限时活动模块】(与 collections 高度同构)
│   ├── index.json                      <-- [公开] 活动中心总索引清单 (状态/时间/包指针)
│   ├── covers/                         <-- [公开] 活动封面缩略图
│   │   └── halloween2026.webp
│   └── packs/                          <-- [公开] 活动独立 ZIP 归档包 (不可变)
│       └── halloween2026.zip
│
└── collections/                        <-- 【主题图集模块】(与 events 高度同构)
    ├── index.json                      <-- [公开] 图集中心总索引清单 (价格/分类/包指针)
    ├── covers/                         <-- [公开] 图集封面缩略图
    │   └── masterpieces_v1.webp
    └── packs/                          <-- [公开] 图集独立 ZIP 归档包 (不可变)
        └── masterpieces_v1.zip
```

---

## 3. 各模块详细数据结构与 RFC 3986 契约

### 3.1 根入口：`out/manifest.json` (全局总路由网关)

客户端启动时请求该文件，各模块 URL 默认使用标准**相对路径**（亦支持迁移至第三方 CDN 的绝对 URL）：

```json
{
  "schemaVersion": 4,
  "updatedAt": "2026-09-05T21:45:00Z",
  "appConfig": {
    "notice": "",
    "minAppVersion": "1.0.0"
  },
  "modules": {
    "main": {
      "url": "main/index.json",
      "version": 102,
      "totalCount": 130,
      "hash": "c7f3a1b2..."
    },
    "daily": {
      "url": "daily/index.json",
      "version": 12,
      "currentMonth": "202609",
      "hash": "e8d9c0a1..."
    },
    "events": {
      "url": "events/index.json",
      "version": 5,
      "count": 5,
      "hash": "f1a2b3c4..."
    },
    "collections": {
      "url": "collections/index.json",
      "version": 8,
      "count": 8,
      "hash": "b5c6d7e8..."
    }
  }
}
```

---

### 3.2 Main (主线关卡模块)

#### A. 公开索引：`out/main/index.json`
```json
{
  "module": "main",
  "version": 102,
  "totalCount": 130,
  "maxOrder": 230,
  "updatedAt": "2026-09-05T21:45:00Z",
  "items": [
    {
      "batchId": "batch_001",
      "version": 101,
      "count": 100,
      "startOrder": 101,
      "endOrder": 200,
      "url": "batches/batch_001.json"
    },
    {
      "batchId": "batch_002",
      "version": 102,
      "count": 30,
      "startOrder": 201,
      "endOrder": 230,
      "url": "batches/batch_002.json"
    }
  ]
}
```

#### B. 不可变分卷：`out/main/batches/batch_002.json`
> **RFC 3986 路径纠正**：由于当前批次文件位于 `main/batches/` 下，引用平级上一层的图片资源时，**必须严格写为 `../images/0201.webp`**；容器键统一为 `items`：

```json
{
  "batchId": "batch_002",
  "version": 102,
  "count": 30,
  "startOrder": 201,
  "endOrder": 230,
  "items": [
    {
      "id": "main:201",
      "order": 201,
      "url": "../images/0201.webp",
      "tags": ["landscape", "forest"],
      "hash": "8f481e19582e...",
      "addedAt": "2026-09-05T21:45:00Z"
    },
    ...
    {
      "id": "main:230",
      "order": 230,
      "url": "../images/0230.webp",
      "tags": ["animal"],
      "hash": "3a7b9c12def0...",
      "addedAt": "2026-09-05T21:45:00Z"
    }
  ]
}
```

#### C. 独立补丁批次与单关修图规范 (Patch Batches)
正常导出永远是**纯追加新关卡**，绝不进行覆盖判断。对于极低频的**单关修图/调色替换**（如美工重修第 201 关），系统通过独立的“追加式补丁批次”实现，依然严格遵循**不可变哲学（WORM）**：

1. **原文件永不覆盖**：
   * 原图 `images/0201.webp` 物理保持不变，继续享受 CDN 永久强缓存；
   * 新图输出为修订版本 `images/0201-r2.webp`（通过账本历史动态递增修订位 `-r{rev}`，99%+ 关卡仍是纯序号）；
2. **索引中追加补丁批次条目**：
   * 在 `main/index.json` 的 `items` 中追加一条标记为 `"patch": true` 的补丁分卷：
   ```json
   {
     "batchId": "batch_003",
     "version": 103,
     "url": "batches/batch_003.json",
     "patch": true,
     "levelsAffected": [201]
   }
   ```
3. **补丁分卷内容自闭环**：
   * `main/batches/batch_003.json` 只包含被修改的关卡条目，逻辑 ID 保持稳定：
   ```json
   {
     "batchId": "batch_003",
     "patch": true,
     "items": [
       {
         "id": "main:201",
         "order": 201,
         "url": "../images/0201-r2.webp",
         "hash": "e5f6a7b8c9d0...",
         "addedAt": "2026-09-05T22:00:00Z"
       }
     ]
   }
   ```
4. **秒级零风险回滚**：由于 `0201.webp` 物理从未被删除，若线上发现新图有问题，只需再发一个补丁批次重新指回 `../images/0201.webp`，1 秒完成平滑回滚！

---

### 3.3 Daily (每日挑战模块)

#### 公开索引：`out/daily/index.json`
```json
{
  "module": "daily",
  "version": 12,
  "currentMonth": "202609",
  "updatedAt": "2026-09-05T21:45:00Z",
  "items": [
    {
      "month": "202609",
      "totalCount": 30,
      "zipUrl": "zips/202609.zip",
      "fileSizeBytes": 18451024,
      "zipSha256": "4a5b6c7d...",
      "updatedAt": "2026-09-01T00:00:00Z"
    },
    {
      "month": "202608",
      "totalCount": 31,
      "zipUrl": "zips/202608.zip",
      "fileSizeBytes": 19120400,
      "zipSha256": "7d8e9f0a...",
      "updatedAt": "2026-08-01T00:00:00Z"
    }
  ]
}
```
* **ZIP 规范**：`zips/202609.zip` 内包含 `20260901.webp` ~ `20260930.webp`，保持纯日期格式。

---

### 3.4 Events & Collections 共享架构与双语 Schema

由共享引擎 `PackExporterBase` 驱动生成，结构高度对称。支持**中英文双语**元数据：
* **`title`**：默认标题，**英文必填**（如 `"Halloween Mystery"`）；
* **`desc`**：默认描述，**英文选填**（如 `"Explore pumpkins and spooky puzzles."`）；
* **`titleZh`**：中文标题，**选填**（如 `"万圣节奇妙夜"`）；
* **`descZh`**：中文描述，**选填**（如 `"探索南瓜灯与糖果的神秘拼图世界"`）；
* **客户端本地化降级规则**：
  - 中文语言环境（`zh-CN` / `zh-*`）：优先使用 `titleZh` / `descZh`，若未提供或为空则平滑回退至英文 `title` / `desc`；
  - 其它语言环境：统一使用默认英文 `title` / `desc`；
  - 仅限 `events` 与 `collections` 模块，主线与每日挑战不包含此字段。

#### A. `out/events/index.json`
```json
{
  "module": "events",
  "version": 5,
  "updatedAt": "2026-09-05T21:45:00Z",
  "items": [
    {
      "id": "halloween2026",
      "eventId": "halloween2026",
      "title": "Halloween Mystery",
      "desc": "Explore pumpkins and spooky puzzles",
      "titleZh": "万圣节奇妙夜",
      "descZh": "探索南瓜灯与糖果的神秘拼图世界",
      "status": "active",
      "displayOrder": 1,
      "startTime": "2026-10-25T00:00:00Z",
      "endTime": "2026-11-05T23:59:59Z",
      "coverUrl": "covers/halloween2026.webp",
      "zipUrl": "packs/halloween2026.zip",
      "fileSizeBytes": 12582912,
      "zipSha256": "5e6f7a8b...",
      "totalCount": 15,
      "updatedAt": "2026-09-05T21:45:00Z"
    }
  ]
}
```

#### B. `out/collections/index.json`
```json
{
  "module": "collections",
  "version": 8,
  "updatedAt": "2026-09-05T21:45:00Z",
  "items": [
    {
      "id": "masterpieces_v1",
      "collectionId": "masterpieces_v1",
      "title": "World Masterpieces",
      "desc": "Classic paintings from Van Gogh, Monet and more",
      "titleZh": "世界名画经典",
      "descZh": "收录梵高、莫奈等大师传世经典",
      "status": "active",
      "displayOrder": 1,
      "category": "art",
      "unlockCoins": 300,
      "coverUrl": "covers/masterpieces_v1.webp",
      "zipUrl": "packs/masterpieces_v1.zip",
      "fileSizeBytes": 15728640,
      "zipSha256": "6a7b8c9d...",
      "totalCount": 20,
      "updatedAt": "2026-09-05T21:45:00Z"
    }
  ]
}
```

---

## 4. 源侧唯一权威账本规范 (`srcDir/.studio/ledger/exports.json`)

权威账本置于隐藏工作区 `srcDir/.studio/ledger/exports.json`，随素材库一起备份、同步、跨电脑流转：

```json
{
  "schemaVersion": 2,
  "updatedAt": "2026-09-05T22:30:00Z",
  "totalExports": 185,
  "records": [
    {
      "recordId": "rec_0001",
      "sourceHash": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "sourcePath": "animals/wild_fox_01.jpg",
      "sourceSize": 2481902,
      "module": "main",
      "logicalId": "main:201",
      "order": 201,
      "batchId": "batch_002",
      "targetFile": "main/images/0201.webp",
      "targetHash": "8f481e19582e...",
      "revision": 1,
      "supersedes": null,
      "cropInfo": {
        "applied": true,
        "mode": "smart",
        "aspect": "2:3",
        "cropBox": [120, 80, 1800, 2600]
      },
      "exportedAt": "2026-09-05T21:45:00Z"
    }
  ]
}
```

### 权威账本设计优势 (Append-Only List)：
1. **彻底根除 Hash Key 字典覆盖冲突**：
   * 原图若被允许跨模块复用（如先导出至 `daily`，后运营二次确认复用至 `main`），在列表中各记一条独立记录，绝不发生相互覆盖；
2. **修图与回滚全流程审计**：
   * 补丁修图时追加一条新记录（如 `revision: 2, supersedes: "rec_0001", targetFile: "main/images/0201-r2.webp"`）；
   * 若发生回滚，再追加一条记录（如 `revision: 3, supersedes: "rec_0002", targetFile: "main/images/0201.webp"`），所有变动在账本中完整留痕；
3. **内存哈希加速**：
   * Studio 启动加载账本时，在内存中动态构建 `sourceHash -> List[Record]` 与 `logicalId -> Record` 倒排索引，查重检测仍然是毫秒级 `O(1)`。

### 防重规则（跨模块与同模块拦截）：
1. **同批同选重复**：立即硬报错并拦截；
2. **同模块历史重复**：根据内存 `sourceHash` 索引检索，若发现原图已在该模块导出过最新有效条目，直接指出“原图已作为第 N 关（或某月日历）导出，禁止重复”；
3. **跨模块复用**：若原图仅在其它模块（如 `daily`）使用过，导出至 `main` 时系统给出醒目黄色预警，要求运营二次确认。

---

### 4.2 操作审计日志流水规范 (`srcDir/.studio/logs/`)

为了确保素材资产的全生命周期可审计、可追踪，系统在 `.studio/logs/` 下采用标准 **Append-Only JSON Lines (`.jsonl`)** 格式记录关键业务操作：

#### A. 打标变更流水：`operations.jsonl`
每次运营在界面上手动添加/移除标签、或批量修改标签时，实时追加一条记录：
```json
{"timestamp":"2026-09-05T21:46:00Z","action":"tag_add","path":"animals/wild_fox_01.jpg","hash":"e3b0c44...","tagsAdded":["nature","animal"],"operator":"admin"}
{"timestamp":"2026-09-05T21:47:15Z","action":"batch_tag_remove","count":12,"tagsRemoved":["others"],"operator":"admin"}
```

#### B. 导出事件审计：`exports.jsonl`
每次触发导出任务时，记录导出元数据、批次范围、目标路径与执行耗时：
```json
{"timestamp":"2026-09-05T21:48:30Z","action":"export_main","batchId":"batch_002","module":"main","startOrder":201,"count":30,"newVersion":102,"outDir":"D:/game_deploy/puzzles","durationMs":1420,"status":"success"}
{"timestamp":"2026-09-05T21:50:10Z","action":"export_daily","month":"202609","count":30,"targetZip":"daily/zips/202609.zip","outDir":"D:/game_deploy/puzzles","durationMs":2150,"status":"success"}
```

#### 核心收益：
* **零性能开销**：单行文本直接追加写（`O(1)`），无任何数据库或全局重写开销，异常崩溃不损坏历史记录；
* **企业级可溯源**：发生关卡配置疑问或标签变动争议时，秒级反查谁在什么时间对哪张图做了修改；
* **为 UI 时间线铺路**：Studio Web 前端可直接读取该日志流，渲染直观优雅的“操作履历时间线”。

---

## 5. 跨 CDN 相对与绝对路径解析规范 (RFC 3986)

所有模块的 URL 引用严格遵循标准 RFC 3986 递归解析协议，以**引用所在的父文档自身 Base URI** 为解析基准：

```
[Level 0] 客户端 Bootstrap URL
    └─► "https://cdn1.mygame.com/puzzles/manifest.json" (根 Base URI)
          │
          ├── [Level 1] modules['main'].url
          │     ├─ 若为 "main/index.json" (相对路径) 
          │     │    └─► 解析为: "https://cdn1.mygame.com/puzzles/main/index.json" (模块 Base URI)
          │     │
          │     └─ 若为 "https://cdn2.other-storage.com/main/index.json" (跨 CDN 绝对路径)
          │          └─► 直接使用: "https://cdn2.other-storage.com/main/index.json" (模块 Base URI)
          │
          └── [Level 2] 模块内部资源 (以 main/index.json 或 batches/*.json 为自身 Base 递归解析)
                ├─ batches[].url: "batches/batch_001.json"
                │    └─► 相对模块 Base 解析: "{moduleBaseUri}/batches/batch_001.json"
                │
                └─ levels[].url: "../images/0201.webp"
                     └─► 相对批次 Base 解析: "{batchBaseUri}/../images/0201.webp" 
                          == "{moduleBaseUri}/images/0201.webp" ✅ (RFC 3986 标准行为)
```

---

## 6. 客户端全生命周期处理规范 (Client Lifecycle & Sync Engine)

客户端（Flutter App）遵循**“离线优先、极速秒开、后台协商缓存检测、批次差集下载、原子落盘”**的完整状态机：

```mermaid
flowchart TD
    Launch[应用冷启动 Cold Launch] --> Phase1[阶段一: 离线优先极速秒开]
    Phase1 --> ReadDiskCache[读取本地磁盘持久化缓存<br/>manifest_cache / levels_cache]
    ReadDiskCache --> InitMemory[恢复内存字典 _levelsMap<br/>首屏 20ms 零等待秒开呈现]
    
    InitMemory --> Phase2[阶段二: 后台网络检测与主备容灾]
    Phase2 --> FetchManifest[向 CDN 轮询拉取 manifest.json<br/>带 ETag / 3秒超时 / 备用 CDN 降级]
    FetchManifest --> CheckVersion{对比各模块版本:<br/>remoteVersion > localVersion 或 hash 不一致?}
    
    CheckVersion -->|全部模块无变更| Idle[退出同步, 保持当前状态]
    CheckVersion -->|存在更新模块| Phase3[阶段三: 模块级精细化差异同步 (Delta Sync)]
    
    Phase3 --> MainSync[Main 模块: 批次差集增量下载]
    Phase3 --> DailySync[Daily 模块: 月份检查与 ZIP 解压]
    Phase3 --> EventsSync[Events 模块: 活动状态机与 GC]
    Phase3 --> CollectionsSync[Collections 模块: 图集清单更新]
    
    MainSync --> Phase4[阶段四: 原子落盘与 UI 响应式刷新]
    DailySync --> Phase4
    EventsSync --> Phase4
    CollectionsSync --> Phase4
    
    Phase4 --> AtomicPersist[原子写入本地缓存 .tmp -> flush -> replace]
    AtomicPersist --> NotifyUI[触发 contentUpdateNotifier<br/>UI 平滑无感刷新]
    
    NotifyUI --> Phase5[阶段五: 运行时资源懒加载与存储 GC]
    Phase5 --> LazyImage[关卡图片按需异步加载 + LRU 磁盘缓存]
    Phase5 --> AutoGC[自动清理过期活动 ZIP 与临时解压目录]
```

### 6.1 阶段一：离线优先极速秒开 (Offline-First)
* 启动时 UI 线程零阻塞，直接反序列化 `content_cache/` 本地持久化文件，在 20ms 内直接渲染玩家已知的所有关卡。

### 6.2 阶段二：后台网络检测与主备容灾
* 异步后台网络请求带有本地 `If-None-Match` (ETag)，CDN 未更新时返回 304，0 流量判定结束；
* 主备 CDN 轮询支持 3 秒单节点超时降级。

### 6.3 阶段三：Main 批次差集增量消费 (Batch Difference & Sequential Apply)
1. **批次数组硬规则**：`main/index.json` 中的 `batches` 数组**只增不改、只追加不重排 (Append-Only)**。数组的先后顺序即代表了补丁演进与覆盖的自然时间线；
2. **计算差集**：`missingBatches = remoteBatches.where((b) => !localBatchIds.contains(b.batchId)).toList()`；
3. **按数组先后顺序增量处理**：只对 `missingBatches` 发起 HTTP 请求（例如仅下载 2KB 的 `batch_002.json`），历史已同步批次 0 冗余拉取；
4. **纯异步非阻塞合并逻辑 (零同步 I/O，杜绝 UI 掉帧)**：
   ```dart
   // 严格采用纯异步非阻塞 I/O (await)，坚决不使用任何 *Sync 方法
   for (final batch in missingBatches) {
     final batchJson = await _httpClient.fetchJson(batch.url);
     if (batchJson is! Map<String, dynamic>) continue;
     
     final rawLevels = batchJson['levels'] as List<dynamic>? ?? [];
     for (final raw in rawLevels) {
       if (raw is! Map<String, dynamic>) continue;
       final level = _parseLevelItem(raw);
       if (level == null) continue;

       final existing = _levelsMap[level.id];
       if (existing != null) {
         // 同一关卡再次出现（命中修图补丁或配置更新）
         // 若 Hash 发生变化或图片 URL 改变，异步清除本地旧缓存
         if (existing.hash != level.hash || existing.imagePathOrUrl != level.imagePathOrUrl) {
           final oldFile = File(_getLocalImagePath(level.id));
           if (await oldFile.exists()) {
             try {
               await oldFile.delete();
             } catch (e) {
               AppLogger.mainPipe.warning('Failed to delete stale cache: $e');
             }
           }
         }
         // 后出现的条目直接覆盖旧条目，逻辑 ID (如 main:201) 绝对保持稳定
         _levelsMap[level.id] = level;
       } else {
         // 全新关卡正常追加
         _levelsMap[level.id] = level;
       }
     }
     localBatchIds.add(batch.batchId);
   }
   ```
5. **配套关键实现规范 (消解 P0-3 致命缺陷)**：
   * **规范一：`PuzzleLevelItem` 模型增加 `hash` 字段**：
     ```dart
     class PuzzleLevelItem {
       const PuzzleLevelItem({
         required this.id,
         required this.imagePathOrUrl,
         required this.isLocalFile,
         this.hash, // <-- 新增：目标图片 SHA-256 内容指纹，用于补丁与热更比对
         ...
       });
       final String? hash;
       ...
     }
     ```
   * **规范二：`_parseLevelItem` 严格以显式 `id` 为准**：
     ```dart
     PuzzleLevelItem? _parseLevelItem(Map<String, dynamic> raw) {
       final url = raw['url']?.toString();
       if (url == null || url.trim().isEmpty) return null;

       // 核心修复：优先使用清单显式下发的稳定 id (如 main:201)，坚决杜绝从 URL 动态反推
       // 若根据补丁 URL ("../images/0201-r2.webp") 反推会得出错误 ID ("main:0201-r2") 产生孪生关卡
       final canonicalId = raw['id']?.toString() ??
           CanonicalId.fromSource(
             sourceModule: CanonicalId.prefixMain,
             pathOrUrl: url,
           );
       final hash = raw['hash']?.toString();
       ...
       return PuzzleLevelItem(
         id: canonicalId,
         hash: hash,
         imagePathOrUrl: url,
         ...
       );
     }
     ```
   * **规范三：`_persistToCache` 显式持久化 `id` 与 `hash`**：
     ```dart
     // 修复冷启动 ID 漂移：落盘时必须保存 id 与 hash
     // 绝不能仅存 url，因为下载后 url 已被改写为本地绝对路径，冷启动若从本地路径反推会导致 ID 永久漂移成 main:main_201
     final payload = {
       'version': _localVersion,
       'levels': _levelsMap.values.map((l) => {
         'id': l.id,       // <-- 显式持久化
         'hash': l.hash,   // <-- 显式持久化
         'url': l.imagePathOrUrl,
         'order': l.order,
         'tags': l.tags,
         if (l.addedAt != null) 'addedAt': l.addedAt!.toIso8601String(),
         if (l.unlockCoins != null) 'unlockCoins': l.unlockCoins,
         if (l.unlockCode != null) 'unlockCode': l.unlockCode,
       }).toList(),
     };
     ```
6. 推进本地已缓存批次集合。

### 6.4 阶段四：原子落盘与防写坏
* 所有本地缓存写入遵循纯异步流程：`写 .tmp -> await file.writeAsString(..., flush: true) -> await tmpFile.rename(targetPath)`，杜绝闪退损坏缓存文件；
* 响应式总线 `contentUpdateNotifier.value++` 驱动 Flutter 界面局部刷新，无闪烁呈现新关卡红点。

### 6.5 阶段五：图片运行时懒加载与修图处理
* 关卡图片仅在滑动入屏或开始拼图时按需下载；
* **单关修图热更处理**：若某批次对已有关卡提供了更新的 `hash`（目标图片 SHA-256 改变），客户端在阶段三中已异步清理掉本地旧图片，玩家再次点击进入该关卡时，将自然发起异步下载加载新图片（如 `0201-r2.webp`），实现零重启无缝热更；
* **游戏会话保护**：若玩家当前正处于该关卡的拼图游戏中，不中断当前游戏体验，新图片在下一次重新进入关卡或返回主界面时平滑生效。

---

## 7. 部署与运维规范 (The Clean Deploy Contract)

由于 `out/` 目录 100% 纯净公开，部署命令退化为最简单、最安全的形式：

```bash
# 1. 生产发布：无任何过滤参数，也没有任何私有数据可泄露
rclone sync ./out remote:puzzles-cdn

# 2. 生产发布硬规则：禁止使用 --delete，防止误删线上生产数据
# 3. 孤儿文件回收：由独立的 GC 审计命令带 dry-run 确认执行
```

### CDN 推荐缓存配置 (Cache-Control)

| 文件路径特征 | 建议 Cache-Control | 理由 |
| :--- | :--- | :--- |
| `manifest.json` | `no-cache, must-revalidate` + ETag | 根指针，秒级感知模块更新 |
| `*/index.json` | `max-age=60, must-revalidate` + ETag | 模块分卷指针，短缓存 |
| `main/batches/*.json` | `public, max-age=31536000, immutable` | 不可变批次分卷，发布后永不修改 |
| `main/images/*.webp` | `public, max-age=31536000, immutable` | 关卡图片，追加写入 |
| `*/zips/*.zip`, `*/packs/*.zip` | `public, max-age=31536000, immutable` | 月度与活动归档整包，只读不可变 |

### 7.2 未来面向 GitHub / GitHub Pages / Releases 部署说明
未来若将游戏内容资产部署至 GitHub 环境（如 GitHub Pages、GitHub Releases 或 Raw CDN）：
1. **统一相对路径自适应**：Studio 输出的 `manifest.json`、`index.json` 和 `batch_xxx.json` 内部一律采用标准 RFC 3986 相对路径（如 `main/index.json`、`../images/0101.webp`），因此不论 Base URL 挂载在顶级域名（`https://cdn.example.com/`）还是 GitHub Pages 的二级子路径（`https://user.github.io/jigsaw-assets/`），均由客户端以当前 Manifest 自身的 Base URI 为准递归解析，**无需修改 Studio 导出的任何内部文件内容**；
2. **大文件与分流由部署脚本接管**：若超过单文件大小限制，或需将 ZIP / WebP 自动托管至 GitHub Releases 或第三方对象存储，URL Base 注入与路径映射均由独立的 CI/CD 自动化部署脚本处理，Studio 核心构建与相对路径契约保持规范一致。

---

## 8. 实施路线图 (Implementation Roadmap)

1. **Phase 1: 源侧隐藏工作区与权威账本管理器 (`studio/core/workspace.py` & `studio/core/exports_ledger.py`)**
   * 管理 `srcDir/.studio/` 的结构初始化、`tags.json` 读写迁移、`ledger/exports.json` 原子追加与原图 SHA-256 跨模块查重；
2. **Phase 2: 共享包导出引擎 (`studio/exporters/pack_exporter_base.py`)**
   * 抽取 Events 与 Collections 的共享流水线（Staging 转码、不可变 ZIP 压缩、纯净封面输出）；
3. **Phase 3: 四大导出器改造与对齐**
   * `MainExporter`：输出至 `.studio/release/main/`（自包含、不可变 `batches/`、纯数字命名 `0201.webp`、相对路径引用 `../images/`）；
   * `DailyExporter`：输出至 `.studio/release/daily/`；
   * `EventExporter` / `CollectionExporter`：基于基类输出至 `.studio/release/events/` 与 `collections/`；
   * `ManifestManager`：统一生成纯净根 `manifest.json`；
   * **交付阶段**：整体原子拷贝至用户指定的 `outDir`；
4. **Phase 4: Studio 前端与状态感知 API**
   * 接入 `/api/export/inspect`，展示主线当前批次与自动续接序号；
5. **Phase 5: Flutter 客户端 Pipelines 对齐 (消解 P0-3 缺陷)**
   * `PuzzleLevelItem` 模型增加 `final String? hash;` 属性及 `copyWith` 支持；
   * `MainContentPipeline._parseLevelItem` 改为显式 `raw['id']` 优先，杜绝 URL 动态反推；
   * `_persistToCache` 显式持久化 `id` 与 `hash`，彻底消除冷启动从本地文件路径反推造成 ID 漂移；
   * `ContentHttpClient` 接入标准 `Uri.resolve` 规范解析相对路径；
   * `MainContentPipeline` 接入批次差集增量同步、批次 Append-Only 顺序合并与 `existing.hash != level.hash` 异步旧图清理。
