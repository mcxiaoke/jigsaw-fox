# 在线图库选图与关卡来源追踪设计方案

## 1. 概述与核心目标

为了让用户拥有丰富的高质量拼图素材，本方案在「我的自制」模块中引入**全屏在线免版权图库浏览器（Pixabay / Unsplash / Pexels）**，实现与本地相册选图并行的“双通道自制拼图”体验。

### 核心体验目标：
1. **三通道入口**：【我的自制】Tab 顶部采用三个扁平紧凑小卡片——「📷 相册选图（批量导入）」「📦 素材库」「🌐 在线搜图」，其中素材库卡片实时联动素材总数量。
2. **单 WebView 极简内存架构（移动端）**：通过顶部站点切换栏在同一 WebView 实例中平滑切换 Pixabay、Unsplash、Pexels，彻底避免多 WebView 导致的内存暴涨与卡顿；桌面端另以独立 `desktop_webview_window`（WebView2）大窗口承载。
3. **批量搜集与统一素材库（不打断心流）**：相册批量多选导入、网络图库下载图片统一汇聚到「素材库」，用户在素材库面板中查看分辨率、文件大小、来源平台，并挑选进行拼图制作。
4. **关卡全链路来源追踪**：自制关卡完整记录来源（相册/网络平台）及 `sourceUrl`，并在关卡卡片和难度弹窗中展示专属平台徽标。

---

## 2. 整体交互流程与界面架构

### 2.1 整体业务流程图

```mermaid
graph TD
    A["「我的自制」Tab 顶部入口"] -->|点击左卡片| B["系统相册 ImagePicker (支持多选)"]
    A -->|点击中卡片| H["素材库面板 (Material Drawer)"]
    A -->|点击右卡片| C["全屏在线图库浏览器 (单 WebView)"]
    
    B -->|选 1 张: 自动入库 + 立即制作| G["CropPuzzlePage (缩放裁剪与规格选择)"]
    B -->|选多张: 批量入库| H
    
    C -->|顶部切换| C1["Pixabay / Unsplash / Pexels"]
    C -->|方式1: 点击网页下载| D["拦截器捕获下载直链"]
    C -->|方式2: 悬浮大图嗅探| E["JS 智能提取最高清原图"]
    
    D --> F["Dio 后台下载器 (带 Referer/UA)"]
    E --> F
    
    F -->|下载完成| H
    H -->|展示元数据| H1["分辨率(4K/FHD) / 体积 / 来源平台徽标"]
    H -->|点击'自制此拼图'| G
    
    G -->|保存自制关卡| I["CustomPuzzleItem (记录来源类型与 sourceUrl)"]
    I --> J["自制关卡列表 (显示相册/Unsplash/Pixabay等徽标)"]
```

---

### 2.2 界面布局与线框设计

#### 1. 【我的自制】Tab 顶部三入口扁平卡片布局
```
┌────────────────────────────────────────────────────────────┐
│ ┌─────────────┐  ┌─────────────┐  ┌─────────────┐          │
│ │ 📷 相册选图 │  │ 📦 素材库(n)│  │ 🌐 在线搜图 │          │
│ │ 批量多选导入│  │ 待制素材管理│  │ 海量图库    │          │
│ └─────────────┘  └─────────────┘  └─────────────┘          │
│                                                            │
│  我的自制合辑 (共 6 个关卡)                                  │
│  ┌──────────────────────┐    ┌──────────────────────┐      │
│  │ [🏷️ Unsplash]        │    │ [🏷️ 本地相册]        │      │
│  │     自制拼图缩略图   │    │     自制拼图缩略图   │      │
│  │ 森林清晨 · 64 块     │    │ 家中萌宠 · 36 块     │      │
│  └──────────────────────┘    └──────────────────────┘      │
└────────────────────────────────────────────────────────────┘
```
> 「素材库」卡片通过 `ValueListenableBuilder` 实时联动 `DownloadManager` 素材张数。

#### 2. 【在线图库选图】全屏浏览主界面 (Single WebView)
```
┌────────────────────────────────────────────────────────────┐
│  [✕ 关闭]  [◀ 后退][▶ 前进]  [Pixabay|Unsplash|Pexels]  📥(3)│
├────────────────────────────────────────────────────────────┤
│  [==================== 网页加载进度条 60% =================]│
│  🧩 提取本页大图（AppBar 下方右侧半透明墨绿毛玻璃胶囊）      │
│                                                            │
│                    单实例 WebView 主区域                   │
│          （支持手势滑动、关键词搜索、分类筛选等）          │
│           中下方交互区 100% 无遮挡，规格选择/下载无障碍       │
│                                                            │
└────────────────────────────────────────────────────────────┘
```
> 说明：网页内前进/后退按钮随 WebView 历史堆栈动态启用/禁用（`canGoBack`/`canGoForward`）；物理/手势返回优先执行网页内 `goBack`，仅在无历史时退出页面（`PopScope` 防误退）。「提取本页大图」按钮置于 AppBar 下方右侧，避免遮挡图库底部的下载规格选择浮层。

#### 3. 【素材库管理面板】（从底部滑出或点击右上角打开）
```
┌────────────────────────────────────────────────────────────┐
│  📦 素材库 (3 张)                         [清空全部]  [关闭 ✕] │
├────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────┐  ┌──────────────────────────┐ │
│  │ ┌─────────────────────┐ │  │ ┌──────────────────────┐ │ │
│  │ │                     │ │  │ │                      │ │ │
│  │ │       高清缩略图    │ │  │ │        高清缩略图    │ │ │
│  │ │                     │ │  │ │                      │ │ │
│  │ └─────────────────────┘ │  │ └──────────────────────┘ │ │
│  │ 🏷️ 本地相册 · 4K 超清   │  │ 🏷️ Pixabay · FHD 全高清  │ │
│  │ 📐 3840 × 2160          │  │ 📐 1920 × 1080           │ │
│  │ 💾 3.4 MB · 12:35       │  │ 💾 1.2 MB · 12:38        │ │
│  │ ─────────────────────── │  │ ──────────────────────── │ │
│  │ [🧩 制作拼图]      [🗑️] │  │ [🧩 制作拼图]      [🗑️] │ │
│  └─────────────────────────┘  └──────────────────────────┘ │
│                                                            │
│  💡 提示：点击任意素材卡片即可进入缩放裁剪与难度设定页面。  │
└────────────────────────────────────────────────────────────┘
```

---

## 3. 核心技术实现细节与拦截机制

### 3.1 单 WebView 实例与站点平滑切换（移动端）
- **插件选型**：移动端 `webview_flutter: ^4.10.x`；桌面端 `desktop_webview_window: ^0.2.3`（基于 Microsoft Edge WebView2 的独立大窗口）。
- **内存优化原则**：
  - 移动端整个页面生命周期内只初始化 1 个 `WebViewController`；
  - 切换站点时仅调用 `controller.loadRequest(Uri.parse(targetSiteUrl))`；
  - 预设 URL：
    - Pixabay: `https://pixabay.com/zh/photos/`
    - Unsplash: `https://unsplash.com/`
    - Pexels: `https://www.pexels.com/zh-cn/`
- **网页导航增强**：显式「✕ 关闭」按钮；AppBar 提供网页内前进/后退（随历史栈置灰）；`PopScope` 拦截物理/手势返回，有历史则优先 `goBack`。

### 3.2 三层下载拦截与嗅探机制（双保险）

1. **第一层：`NavigationDelegate` 导航拦截**
   - 监听 `onNavigationRequest`：
     - 当 URL 命中图片扩展名（`.jpg`, `.jpeg`, `.png`, `.webp`）或特征下载路径（如 `unsplash.com/photos/.../download`, `pexels.com/.../?dl=1`, `pixabay.com/get/...`）时；
     - 返回 `NavigationDecision.prevent`；
     - 自动触发后台下载管道。
2. **第二层：Android / iOS 原生 `DownloadListener` 拦截**
   - 监听 HTTP `Content-Disposition: attachment` 附件流下载事件；
   - 截获下载 URL 和推荐文件名，交由后台下载器处理。
3. **第三层：JS 智能嗅探（兜底与便捷操作）**
   - 用户在详情页浏览时，点击 AppBar 下方右侧的「🧩 提取本页大图」按钮；
   - 执行轻量 JavaScript，智能按优先级查找高分辨率大图：
     ```javascript
     (function() {
       // 1. 优先提取 meta 原图
       let og = document.querySelector('meta[property="og:image"]');
       if (og && og.content) return og.content;
       // 2. 遍历页面主图中面积最大或包含 srcset 的图片
       let imgs = Array.from(document.querySelectorAll('img'))
                       .filter(img => img.naturalWidth > 600);
       if (imgs.length > 0) {
         imgs.sort((a, b) => (b.naturalWidth * b.naturalHeight) - (a.naturalWidth * a.naturalHeight));
         return imgs[0].currentSrc || imgs[0].src;
       }
       return '';
     })()
     ```

### 3.3 网络下载器与防盗链处理 (`Dio`)
- **防盗链 Headers**：
  - `Referer: <当前 WebView 页面 URL>`
  - `User-Agent: <移动端标准 UserAgent>`
- **下载流与元数据提取**：
  1. 使用 `Dio.download` 下载到应用临时目录 `download_cache/`；
  2. 结合 `dart:ui` 的 `instantiateImageCodec` 快速读取图片的真实像素宽高等元数据；
  3. 计算文件大小（MB/KB），记录 `sourcePlatform` 和 `sourceUrl`。
- **直链拦截识别增强**：`shouldOverrideUrlLoading` 识别带 `&dl=`、`?dl=`、`images.pexels.com/` 等参数的 Pexels 下载直链并保留其原始分辨率与参数；针对 Unsplash `/download` 官方直链保留原始下载地址（不强行加 `w=2400` 限制），完整享受 5000+ 原始超高像素。
- **多层严格防破损校验**：
  - **二进制合法性**：保存前必须通过 `ui.instantiateImageCodec` 解码验证，HTML 错误页 / 防盗链损坏数据自动删除临时文件并拒绝入库；
  - **最小分辨率过滤**：小于 `200×200` 的图标、头像、占位图自动清理；JS 嗅探器过滤 `.svg`、`placeholder`、`data:image` 及自然宽高 `< 250px` 的无杂质图。
- **下载结果通知**：下载成功仅浮现 5 秒自动隐藏的精致通知条（带显式 ✕ 关闭），不常驻遮挡。

---

## 4. 关卡数据模型与来源追踪扩展

### 4.1 关卡来源类型枚举与模型扩展

```dart
/// 自制关卡来源类型
enum PuzzleSourceType {
  gallery('相册导入', Icons.photo_library_outlined),
  online('网络图库', Icons.language_outlined),
  preset('官方预置', Icons.extension_outlined);

  final String label;
  final IconData icon;
  const PuzzleSourceType(this.label, this.icon);
}

/// 已下载图片模型
class DownloadedImageItem {
  final String id;
  final String localPath;
  final String sourcePlatform; // 'Unsplash' | 'Pixabay' | 'Pexels'
  final String sourceUrl;
  final int width;
  final int height;
  final int fileSizeBytes;
  final DateTime downloadedAt;

  String get resolutionLabel => '$width × $height';
  String get fileSizeLabel => '${(fileSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
```

### 4.2 `CustomPuzzleItem` 模型升级与向前兼容

在 `CustomPuzzleItem` 中增加来源追踪字段：
```dart
class CustomPuzzleItem {
  final String id;
  final String title;
  final String imagePathOrUrl;
  final bool isLocalFile;
  final PuzzleDifficulty difficulty;
  final DateTime? createdAt;
  
  // 新增来源追踪字段
  final String sourceType;      // 'gallery' | 'online' | 'preset'
  final String sourcePlatform;  // '本地相册' | 'Unsplash' | 'Pixabay' | 'Pexels'
  final String? sourceUrl;      // 网络原始URL 或 本地标识

  // ... 序列化与反序列化（向下兼容历史老数据）
}
```

- **向下兼容策略**：
  - 读取旧版本存档时，若 `sourceType` 缺失：
    - 若 `imagePathOrUrl` 包含 `assets/` -> 标记为 `preset`；
    - 否则默认归类为 `gallery`（本地相册导入）。
  - 老关卡在升级后仍能平滑运行，不会崩溃。

---

## 5. 异常处理与边界场景应对

| 边界场景 | 应对策略与优化手段 |
| :--- | :--- |
| **重复点击下载同一张图** | 在下载前比对 `sourceUrl`，若已存在于已下载列表中，弹出轻提示“该图片已在下载箱中”，避免重复消耗流量和存储。 |
| **超高清大图（如 8K/RAW）导致解码 OOM** | 在下载与裁剪前，若图片超长边大于 4096px，在生成拼图切片时按比例约束至 2048px 标准画质，保证低端机运行流畅。 |
| **网络波动/下载中断** | 下载过程中展示进度条与取消按钮；下载失败时给出明确的“重试”与错误提示，不破坏 WebView 浏览状态。 |
| **缓存文件占用空间膨胀** | 提供「一键清空下载箱」功能，自动删除 `download_cache/` 临时图片。已制作成功的关卡保存在独立的 `custom_puzzles/` 中，不受清空影响。 |
| **图库网页广告或 APP 推广条遮挡** | WebView 页面加载完成后注入轻量 CSS：`#app-banner, .mobile-app-banner { display: none !important; }`，净化界面。 |

---

## 6. 实施路线图

1. **第一阶段：数据模型与底层支持**
   - 升级 `CustomPuzzleItem` 增加 `sourceType`、`sourcePlatform`、`sourceUrl` 字段与向下兼容；
   - 封装 `DownloadedImageManager`（负责下载图片缓存、元数据解析、持久化记录）。
2. **第二阶段：全屏图库浏览器页面**
   - 添加 `webview_flutter` 依赖；
   - 实现 `OnlineImagePickerPage`（单 WebView 架构、站点切换栏、下载拦截器、JS 提取器、下载箱徽标）。
3. **第三阶段：已下载抽屉与制作串联**
   - 实现 `DownloadedDrawerSheet`（展示分辨率、体积、来源标签）；
   - 对接 `CropPuzzlePage` 裁剪流程，保存时写入完整来源元数据。
4. **第四阶段：【我的自制】Tab 改造与平台徽标展示**
   - 顶部改造为三个扁平紧凑入口卡片（相册选图 / 已下载 / 在线搜图）；
   - 关卡网格卡片和难度弹窗增加相册/网络平台徽标展示。
