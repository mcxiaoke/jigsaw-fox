# Flutter 异形拼图游戏 · 工程架构文档

本文档定义系统的分层架构、核心算法模型、几何数学、图层渲染管线与测试策略。

---

## 1. 技术栈决策

| 分层 | 选型 | 决策依据与选型考量 |
|---|---|---|
| **UI 表现框架** | Flutter 3.x (Dart 3) | 跨 Android / iOS / Windows / Web 一致渲染 |
| **游戏/渲染引擎** | **Flame** (Canvas 抽象 + 2D 组件树) | 单画布批量渲染，规避多 Widget 堆叠的性能与手势穿透瓶颈；内置平移缩放视口与组件生命周期 |
| **本地持久化** | **GameRepository / SharedPreferences** | 轻量高效的本地沙盒持久化，管理关卡进度、断点存档、自制图库与用户设置 |
| **图片处理与超分辨率** | `image` + `image_picker` + `dart:ui` | 本地相册选取、自由裁剪、正交旋转与纯 Dart 非 AI 图像保边降噪 (Guided Filter) + CAS 超分辨率增强 |

---

## 2. 整体分层架构

系统采用 **「领域核心算法 / 游戏渲染引擎 / UI 交互表现」** 严格三层分离架构。领域核心不依赖任何 Flutter UI 或 Flame 引擎代码，保证 100% 可脱机单元测试。

```
┌─────────────────────────────────────────────────────────────┐
│  1. UI 表现层 (Flutter Widgets)                            │
│  HomePage / GamePage / CropPuzzlePage / Dialogs             │
│  - 负责页面路由、弹窗动效、分层工具栏、音效触觉触发与无障碍   │
│  - 驱动数据流并响应玩家全局交互意图                           │
└──────────────────────────────┬──────────────────────────────┘
                               │ 用户操作 / 状态传递
┌──────────────────────────────▼──────────────────────────────┐
│  2. 游戏引擎层 (Flame Game Engine)                          │
│  JigsawPuzzleGame (FlameGame)                               │
│   ├─ BoardGhostComponent (底图透视参考水印层)                │
│   ├─ TrayBackgroundComponent (托盘纯色半透明遮罩与手势捕获)   │
│   ├─ PuzzlePieceComponent (单碎片: 局部渲染/拖拽手势/拾取反馈)│
│   └─ GhostOutlineComponent (磁吸虚线高亮层)                 │
│  * 职责: 60fps 实时手势平移、磁吸 Tween 缓动、Canvas 批渲染  │
└──────────────────────────────┬──────────────────────────────┘
                               │ 拖拽释放结算 / 纯函数调用
┌──────────────────────────────▼──────────────────────────────┐
│  3. 领域逻辑与数据层 (Pure Dart, 零 UI/Flame 依赖)           │
│  ├─ 几何切割: EdgeLayout (确定性拓扑) / PieceShape (贝塞尔路径)│
│  ├─ 状态机模型: PuzzleDifficulty / Snapshot v2 / UndoManager │
│  ├─ 纯函数群: resolveSnap() / isSolved() / hintFor()        │
│  ├─ 超分引擎: ImageUpscaler (导向滤波降噪/Cubic插值/CAS锐化) │
│  └─ 持久化仓储: GameRepository & CustomPuzzleItem           │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. 核心算法：异形切割与拼合几何

### 3.1 5 种标准比例与正方形基础切片单元模型

内核支持 5 种规整的标准图片比例（`1:1`、`2:3`、`3:2`、`3:4`、`4:3`），且每种比例的网格划分严格满足：
$$\frac{\text{cols}}{\text{rows}} = \frac{W_{\text{image}}}{H_{\text{image}}}$$

- **严格正方形基础切片 ($w = h$)**：
  在屏幕棋盘基准尺寸下：
  $$w = \frac{\text{boardW}}{\text{cols}}, \quad h = \frac{\text{boardH}}{\text{rows}} = \frac{\text{boardW} \cdot \frac{H_{\text{image}}}{W_{\text{image}}}}{\text{cols} \cdot \frac{H_{\text{image}}}{W_{\text{image}}}} = \frac{\text{boardW}}{\text{cols}} = w$$
  因此，切片在施加贝塞尔凹凸卡扣前，基础单元格恒定为严格正方形。
- **智能棋盘最大化居中排布**：
  - 设游戏工作区可用尺寸为 $W_{\text{avail}} \times H_{\text{avail}}$（扣除底部托盘高度与 Margin）。
  - 原图长宽比 $R_{\text{img}} = \frac{\text{image.width}}{\text{image.height}}$，工作区长宽比 $R_{\text{avail}} = \frac{W_{\text{avail}}}{H_{\text{avail}}}$。
  - **最大化占满策略**：
    $$\begin{cases} \text{boardW} = W_{\text{avail}} \times 0.90, \quad \text{boardH} = \frac{\text{boardW}}{R_{\text{img}}} & (R_{\text{img}} \ge R_{\text{avail}} \text{，图片偏宽/横屏}) \\ \text{boardH} = H_{\text{avail}} \times 0.90, \quad \text{boardW} = \text{boardH} \times R_{\text{img}} & (R_{\text{img}} < R_{\text{avail}} \text{，图片偏高/竖屏/正方形}) \end{cases}$$
  - 原图切片对应的像素基准尺寸：
    $$\text{srcW} = \frac{\text{image.width}}{\text{cols}},\quad \text{srcH} = \frac{\text{image.height}}{\text{rows}} \quad (\text{srcW} = \text{srcH})$$

```
       列 0        列 1        列 2        列 (cols-1)
    ┌───────────┬───────────┬───────────┬───────────┐
行 0 │  (0, 0)   │  (0, 1)   │  (0, 2)   │ (0,cols-1)│  h
    ├───────────┼───────────┼───────────┼───────────┤
行 1 │  (1, 0)   │  (1, 1)   │  (1, 2)   │ (1,cols-1)│  h
    ├───────────┼───────────┼───────────┼───────────┤
行 R │  (R-1, 0) │  (R-1, 1) │  (R-1, 2) │ (R-1, C-1)│  h
    └───────────┴───────────┴───────────┴───────────┘
          w           w           w           w  (w == h)
```

---

### 3.2 确定性切割布局 (EdgeLayout + Seed)

为了保证「相同种子下切割拓扑恒定、存档无需记录复杂轮廓」，采用全局网格随机矩阵：

- **矩阵定义**：
  - 横向边矩阵 `_h[M-1][N]`：描述第 $r$ 行与第 $r+1$ 行之间的水平切线（取值 $+1$ 或 $-1$）。
  - 纵向边矩阵 `_v[M][N-1]`：描述第 $c$ 列与第 $c+1$ 列之间的垂直切线（取值 $+1$ 或 $-1$）。
  - 所有值由 `Random(seed)` 伪随机数发生器一次性初始化生成。

- **单片四边类型推导**：

| 边缘方位 | 推导规则 | 几何语义 |
|---|---|---|
| **Top** | $r = 0 \implies \text{flat}$；否则 `_h[r-1][c] == 1 ? blank : tab` | 顶边 |
| **Bottom** | $r = M-1 \implies \text{flat}$；否则 `_h[r][c] == 1 ? tab : blank` | 底边 |
| **Left** | $c = 0 \implies \text{flat}$；否则 `_v[r][c-1] == 1 ? blank : tab` | 左边 |
| **Right** | $c = N-1 \implies \text{flat}$；否则 `_v[r][c] == 1 ? tab : blank` | 右边 |

> **互补性保证**：第 $(r, c)$ 片的 Bottom 边与第 $(r+1, c)$ 片的 Top 边严格由同一个 `_h[r][c]` 变量推导，天然互为镜像（一凸一凹），杜绝裂缝或重叠。

---

### 3.3 局部坐标系与 Overhang 数学模型 (PieceShape)

#### A. 局部坐标系原点标准
**严格规定：碎片局部坐标系的原点 $(0, 0)$ 恒定设为「基准矩形（Base Cell）的左上角」**。

```
(-overhang.left * w, -overhang.top * h)  ┌──────────────────────────────┐ (fillRect 左上)
                                         │  Top Tab 凸起                │
                       (0, 0) ───────────┼──────────┬───────────────────┤
                                         │          │                   │
                      Left Tab           │ BaseCell │     Right Tab     │
                        凸起             │  (w × h) │       凸起        │
                                         │          │                   │
                                         ├──────────┴───────────────────┤
                                         │  Bottom Tab 凸起             │
                                         └──────────────────────────────┘
                                           ((1+right)*w, (1+bottom)*h) (fillRect 右下)
```

#### B. Overhang 参数化与分轴深度
- 定义标准 Tab 深度比例 $\text{tip} = 0.245$（约为边长的 $1/4$）。
- 各方向外扩比例 `overhang`：
  - `top`: 若顶边为 tab 则为 $\text{tip}$，否则为 $0.0$；
  - `bottom`: 若底边为 tab 则为 $\text{tip}$，否则为 $0.0$；
  - `left`: 若左边为 tab 则为 $\text{tip}$，否则为 $0.0$；
  - `right`: 若右边为 tab 则为 $\text{tip}$，否则为 $0.0$。

#### C. 局部包围盒 (`fillRect`) 与原图采样矩形 (`srcRect`) 精确对齐
- **局部绘制目标矩形 (`fillRect`)**：
  $$\text{fillRect} = \text{Rect.fromLTWH}(-\text{overhang.left} \cdot w,\; -\text{overhang.top} \cdot h,\; (1 + \text{overhang.left} + \text{overhang.right}) \cdot w,\; (1 + \text{overhang.top} + \text{overhang.bottom}) \cdot h)$$
- **原图像素采样矩形 (`srcRect`)**：
  $$\text{srcRect} = \text{Rect.fromLTWH}((c - \text{overhang.left}) \cdot \text{srcW},\; (r - \text{overhang.top}) \cdot \text{srcH},\; (1 + \text{overhang.left} + \text{overhang.right}) \cdot \text{srcW},\; (1 + \text{overhang.top} + \text{overhang.bottom}) \cdot \text{srcH})$$

> **1:1 映射保证**：`srcRect` 与 `fillRect` 的四个边界通过相同的 `overhang` 参数向外线性扩展，避免任何像素拉伸或纹理错位。

---

### 3.4 长方形碎片 90° 旋转几何与置换矩阵

当碎片启用旋转功能时（朝向 $\text{rot} \in \{0, 1, 2, 3\}$，分别代表顺时针 $0^\circ, 90^\circ, 180^\circ, 270^\circ$）：

- **尺寸互换**：当 $w \neq h$ 且碎片旋转 $\text{rot} \in \{1, 3\}$ 时，碎片的有效占位尺寸发生长宽置换：
  $$w' = (\text{rot} \% 2 == 0) \;?\; w : h,\quad h' = (\text{rot} \% 2 == 0) \;?\; h : w$$
- **边缘置换矩阵（顺时针旋转 $90^\circ$）**：
  $$\begin{pmatrix} \text{top}' \\ \text{right}' \\ \text{bottom}' \\ \text{left}' \end{pmatrix} = \begin{pmatrix} \text{left} \\ \text{top} \\ \text{right} \\ \text{bottom} \end{pmatrix}$$
- **命中测试逆变换 (Hit-Testing)**：
  触控点相对碎片基准锚点计算局部偏移后，绕局部中心点做逆向旋转 $R(-90^\circ \times \text{rot})$，再执行贝塞尔封闭路径的命中测试。

---

### 3.5 吸附、归位锁定 (Locking) 与四阶 Priority 层级体系

- **吸附阈值**：$\text{snapDistance} = \min(w, h) \times 0.48$（黄金手感吸附比例）。
- **粘连语义 (Adhere & Cluster Merging)**：未归位碎片在空中相互触碰对齐时形成「自由碎片组（Cluster）」，支持整组协同拖拽与重排。
- **托盘隔离 (onBoardPieceIds)**：托盘内碎片（`isInTray == true`）绝不参与任何空间邻居合并与级联吸附，杜绝高倍率缩放下归一化间距落入容差导致的误粘连，拖回托盘的碎片只做平滑入槽。
- **主装配体单向吸附 (isInMainAssembly)**：两块集群吸附时按规模识别主装配体（大集群）与小集群，永远由小集群/单块向大集群平移对齐，大集群坐标绝对静止，消除半成品被小碎片拉跑偏位的违和感。
- **归位锁定 (Solved Piece Locking)**：
  - 当碎片或集群吸附到目标棋盘网格槽位（`isSolved == true`）时，系统立即将其标记为 `isLocked = true`；
  - **锁定拦截**：锁定后的碎片禁止再次被鼠标/触摸拾起或拖拽，彻底杜绝误触移位；
  - **层级降至底层**：已归位碎片的渲染层级（Priority）强制降至底层（Priority = 5），贴底渲染，绝不遮挡上层任何浮动碎片。
- **四阶 Priority 渲染与交互层级规范**：
  $$\begin{cases}
  \text{Layer Top (Priority } \ge 1000\text{)}: & \text{当前正在拖拽或被光标抓取跟随的活动碎片集群（最高层级与交互优先级）} \\
  \text{Layer Board Floating (Priority } = 20\text{)}: & \text{棋盘上漂浮/散落的未归位碎片与自由集群（浮于已归位底板碎片上方）} \\
  \text{Layer Tray (Priority } = 10\text{)}: & \text{底部托盘中的待拼碎片} \\
  \text{Layer Solved (Priority } = 5\text{)}: & \text{已吸附归位的正确碎片（锁定禁止移动，贴底渲染）} \\
  \text{Layer Board (Priority } = 0 \sim 2\text{)}: & \text{底板边框、底图透视水印与托盘背景}
  \end{cases}$$
- **命中测试天然上层优先**：Flame 的 Hit-testing 遵循 Priority 倒序遍历。当未归位碎片与底层已归位碎片重叠时，鼠标/触控点击 100% 优先拾取上层的未归位碎片。
- **通关判定**：所有碎片归位到目标槽位且旋转朝向均为 $0^\circ$ 时判定通关，底板转为完整大图无缝呈现；通关后**保留**所有碎片的冲压接缝切线、立体倒角与亚麻纹质感，呈现真实成品。
- **边缘闭环自动感知 (isEdgeComplete)**：`PuzzleBoardState` 维护 `isEdgeComplete` 闭环属性；仅看边缘筛选模式下，外框一圈全部归位后自动解除筛选、平滑淡入复原内部碎片。
- **失踪碎片自愈 (Missing Piece Check)**：剩余未拼碎片 $\le 2$ 块时，后台自检视口外碎片并平滑弹回可视区域，杜绝“找不到最后一块”。

---

### 3.6 撤销 / 重做机制 (Undo/Redo via Pure Snapshot Stack)

采用轻量不可变纯状态快照栈：
- 每次有效拖拽吸附、合并或提示时将状态压入撤销栈；
- 支持最大 30 步历史记录无损还原与重做；
- 状态栈占用内存小（$< 400\text{KB}$），无副作用且稳定。

---

### 3.7 底部托盘碎片尺寸归一化与动态缩放过渡

- **基准触控尺寸归一化**：无论切片数多少（9 至 400 块），托盘内碎片统一缩放至舒适触控长边（约 $64\text{px}$）：
  $$\text{trayScale} = \frac{S_{\text{trayBase}}}{\max(w, h)}$$
- **进出棋盘动态缩放**：按住碎片拖出托盘时平滑插值放大至物理尺寸 $1.0$；放回托盘时平滑缩回归一化尺寸。
- **命中测试动态逆缩放**：拖拽过程中根据实时缩放比动态进行局部坐标逆变换，保证抓握点零抖动。

---

### 3.8 实体硬纸板渲染管线 (Physical Cardboard Render Pipeline)

`PuzzlePieceComponent` 采用多层复合渲染管线（详见专项文档 [`physical-cardboard-rendering-and-lighting-design.md`](file:///c:/Home/Projects/jigsawpuzzle/docs/physical-cardboard-rendering-and-lighting-design.md)）：

1. **动态悬浮阴影**：静止状态绘制紧致贴地接触微阴影（Contact AO）；拖拽悬浮时切换为深层大模糊右下方扩散软投影。
2. **4 大方案实体纸板分层**：
   - **方案 1 四向光照冲压切线**：Top/Left 边绘制 0.8px 半透明柔白高光微边，Bottom/Right 边绘制 1.2px 半透明深黑冲压切缝，模拟刀模挤压倒角；
   - **方案 2 纸板厚度截面**：悬浮/拾起时向右下方偏移填充纸板夹芯色并描底边暗线，呈现 1.8mm 实体侧截面；
   - **方案 3 多阶阴影**：静止贴地 AO + 拾起深层扩散投影；
   - **方案 4 亚麻布纹压花**：64x64 程序化亚麻网格微纹理，经 GPU `ImageShader(TileMode.repeated)` + `BlendMode.softLight` 叠加在正面图案上，还原哑光纸质漫反射。
3. **吸附高亮 / 边缘筛选光晕**：吸附就位或边缘筛选激活时无缝切换为全圈高亮。
4. **冲压主切缝**：主线宽 1.2px、41% 深黑（`0x68000000`），保证暗色复杂纹理下图块咬合缝隙清晰可辨。

---

### 3.9 图层堆叠与渲染管线 (Wallpaper & Overlay Pipeline)

游戏主界面采用基于 Flutter `Stack` + `Column` 的复合渲染管线（头部纵向排布、画布不重叠）：

1. **底图层 (`Layer 0: Seamless Tabletop Backdrop`)**：全屏平铺**无缝桌板背景**（当前 12 款 `assets/bg/tile_000~011.webp`，`ImageRepeat.repeat`），任意窗口与屏幕尺寸 1:1 像素级清晰、零拉伸模糊。
2. **头部区 (Header: Column 顶部纵向排布)**：标准 AppBar + 独立悬浮 Sub-Bar + 细线性进度条，与画布互不重叠，横屏不遮挡。
3. **游戏引擎层 (`Layer 1: Flame GameWidget`)**：背景完全透明；画布区域绘制半透明暗色底槽与底图透视水印（`BoardGhostComponent`）；外层包裹 `ClipRect` 防止碎片放大/平移溢出穿透头部。
4. **托盘遮罩层 (`Layer 2: Tray Mask`)**：`TrayBackgroundComponent` 绘制半透明纯色底板与微圆角边框，消除背景纹理干扰。
5. **原图全景覆盖层 (`Layer 3: Original Image Overlay`)**：点击眼睛图标激活，居中呈现高清原图，点击背景即刻切回拼图。
6. **悬浮层 (`Layer 4: Floating HUD`)**：放大倍率徽标 + 一键复位；通关后底部常驻庆祝 Banner。
7. **两层式导航与悬浮工具栏层 (`Layer 5: Two-Tier Navigation & Sub-Bar`)**：
   - **Tier 1 (标准 AppBar)**：返回、大号关卡标题 + 4 个高频工具（智能提示 / 壁纸切换 / 原图眼睛 / 暂停菜单）；
   - **Tier 2 (独立悬浮 Sub-Bar)**：实时用时、已拼碎片胶囊 + 5 大对局工具组（撤销/重做/透视/边缘筛选/托盘整理）与细线性进度条；
   - 彻底杜绝超窄屏下的 RenderFlex 溢出问题。

---

### 3.10 自适应响应式网格与跨平台拖拽滚动管线

1. **统一自适应网格委托 (`SliverGridDelegateWithMaxCrossAxisExtent`)**：
   - 关卡画廊、每日挑战与我的自制三大 Tab 统一采用 `maxCrossAxisExtent: 220, childAspectRatio: 1.0`；
   - 窄屏自动计算为 2 列，宽屏自适应扩展为 3~6 列，保证卡片无拉伸变形。
2. **跨平台多模态手势滚动 (`AppScrollBehavior`)**：
   - 扩展 `dragDevices` 包含 `{touch, mouse, trackpad, stylus}`；
   - 保证分类筛选胶囊与托盘在桌面端鼠标左键拖拽、触控板双指滑动与移动端触摸下均可流畅水平滚动。

---

### 3.11 Windows 鼠标单击吸附抓取 (Click-to-Pick & Move-to-Drop) 与双模手势架构

为彻底消除桌面端/Windows 玩家长时间按住鼠标拖动导致的食指疲劳，系统内置**智能双模手势状态机**：

```
                    ┌────────────────────────┐
                    │ 用户在未归位碎片上按下   │
                    └───────────┬────────────┘
                                │ onDragStart
                                ▼
                    ┌────────────────────────┐
                    │ 记录起始位置与时间戳     │
                    │ _dragStartTime / Pos   │
                    └───────────┬────────────┘
                                │ onDragEnd (松开)
                ┌───────────────┴───────────────┐
                │                               │
    [位移 < 8px 且 时间 < 350ms]      [位移 ≥ 8px 或 长按拖动]
    (典型鼠标单击 / 点选)             (传统按住拖拽 / 移动端触控)
                │                               │
                ▼                               ▼
    ┌────────────────────────┐      ┌────────────────────────┐
    │ 开启光标吸附跟随模式    │      │ 直接释放放置           │
    │ startHoldingPiece      │      │ handlePieceDragEnd     │
    └───────────┬────────────┘      └────────────────────────┘
                │
                │ onMouseMove (光标任意移动，无需长按)
                ▼
    ┌────────────────────────┐
    │ 碎片及其集群跟随光标平滑 │
    │ 移动并实时计算缩放插值   │
    └───────────┬────────────┘
                │
        ┌───────┴───────────────────────┐
        │                               │
    [再次单击鼠标左键]             [右键单击 或 按 ESC 键]
        │                               │
        ▼                               ▼
┌────────────────────────┐      ┌────────────────────────┐
│ 释放放置并执行吸附判定  │      │ 取消抓取并平滑飞回原位 │
│ dropHoldingPiece       │      │ cancelHoldingPiece     │
└────────────────────────┘      └────────────────────────┘
```

1. **全链路轻点响应与零漏触**：`PuzzlePieceComponent` 同时混入 `DragCallbacks` 与 `TapCallbacks`，并在 `onTapDown` 与 `onDragStart` 中双向拦截响应，无论是轻点还是按住拖动均 100% 灵敏秒响应。
2. **归一化抓取锚点模型 (Normalized Grab Anchor Model)**：
   - 拾起碎片时，计算光标在碎片逻辑尺寸中的相对比例锚点：
     $$anchorX = \frac{x_{\text{cursor}} - pos.x}{size.x \cdot scale.x}, \quad anchorY = \frac{y_{\text{cursor}} - pos.y}{size.y \cdot scale.y}$$
   - 碎片在托盘与棋盘之间平滑连续缩放（例如从托盘 $0.35$ 放大至棋盘 $1.0$ 或 $3.0$ Zoom）时，碎片的左上角位置实时由下列公式严格推导：
     $$pos.x = x_{\text{cursor}} - anchorX \cdot size.x \cdot scale_{\text{current}}$$
     $$pos.y = y_{\text{cursor}} - anchorY \cdot size.y \cdot scale_{\text{current}}$$
   - **数学保证**：光标永远 100% 牢牢对准碎片上玩家最初抓取的那一个相对纹理点，无论变大变小多少倍，光标与抓握点零位移发散、零距离拉大，实现绝对跟手！
3. **再次单击放置**：光标移动到目标区域（棋盘或托盘）后，再次单击左键即可放置并触发精准吸附或托盘收纳。
4. **传统拖动与触屏 100% 兼容**：若玩家采用“按住拖动到位置后松开”的传统操作，位移超过阈值时直接在松手时放置，两套习惯无缝共存。
5. **防误触与快捷取消**：在吸附状态下，点击鼠标右键或按键盘 `ESC` 键，碎片将平滑缓动飞回原位。

---

### 3.12 画布缩放平移、窗口自适应与桌面散落布局

#### A. 全局缩放与定点平移 (Zoom & Pan)
- **缩放上限**：`_maxZoom = 3.0`（300%），无论原图分辨率多大均不过度放大，保持适度视野与操作手感。
- **触屏双指**：以两指中心为基准的仿射变换，捏合缩放 + 双指拖拽平移，缩放时中心图案绝对锁定无漂移。
- **桌面定点缩放**：`Ctrl/⌘ + 鼠标滚轮` 以鼠标光标为中心定点缩放；`Ctrl` 未按且在棋盘区域滚轮亦触发；
- **拖拽漫游**：鼠标中键按住拖拽平移；放大状态（`zoom > 1.0`）下按住空白区域（未拖拽任何碎片）以左键/单指直接平移画布。
- **漫游边界 (Pan Clamping Bounds)**：按放大后棋盘内容外接包围盒与视口物理尺寸精确推导上/下/左/右非对称边界，保证四角与边缘可畅行漫游、定点缩放稳定不跳。

#### B. Windows 窗口 Resize 自适应
- 监听 `onGameResize`，以 `_lastGameSize` 尺寸变更守卫防重入；
- 游离单块按视口安全边界 Clamp 并反向更新归一化坐标，多块自由集群以外接包围盒整体原子平移（绝不拆散）；
- 桌面散落槽位缓存随尺寸重置；重组 `PieceShape` 与 `pieceSize`，碎片按 `nx, ny` 等比换算屏幕坐标。

#### C. 桌面散落模式 (Tabletop Mode) 与 8 扇区环形全域发散
- **设置开关**：`pieceScatterMode`（`tray` / `tabletop`）持久化；桌面模式仅在宽场景（`size > 450px`）启用，窄场景自动回退托盘收纳。
- **8 扇区环形全域发散**：将屏幕除中央棋盘安全区外的空间划分为 8 个方位扇区，四向交替（Round-Robin）注入槽位、`0.78 · pieceSize` 步长多行多列、基于种子 `±10%` 自然抖动，棋盘居中比例约 0.56 黄金比例留白。
### 3.13 UGC 自制关卡非 AI 图像超分辨率与保边降噪增强管线 (ImageUpscaler)

为解决玩家导入小尺寸/低分辨率图片在切片后出现马赛克模糊、且确保切片碎片边长安全满足最小物理分辨率（$\ge 30\text{px}$）的要求，系统内置了**纯 Dart 非 AI 图像超分辨率与保边降噪引擎**：

1. **真实物理像素自适应与短边 2160 上限制约**：
   - 裁切导出尺寸由玩家在视口中所框选的原图实际物理像素范围 $\left(W_{\text{crop}}, H_{\text{crop}}\right)$ 动态自适应决定；
   - 施加**短边最大 2160px 4K 黄金上限约束**（1:1 最大 $2160 \times 2160$、2:3 最大 $2160 \times 3240$、3:4 最大 $2160 \times 2880$），避免极端大图引起显存暴涨与切片卡顿；
   - 1080P~2K 正常高清原图保持 100% 1:1 无损物理裁切导出。
2. **低分辨率智能触发条件**：
   - 若实际裁切导出的像素尺寸满足 **短边 $\le 750\text{px}$** 或 **长边 $\le 1000\text{px}$**（满足任意一个），自动触发 2x 高清超分辨率增强管线。
3. **三阶滤波管线流程**：
   - **温和导向滤波 (Guided Filter)**：基于 $O(1)$ 盒状可分离均值加速，仅平滑传感器暗光杂色与 JPEG 压缩伪影，结合线性残差混合，100% 锁死动物毛发与物体轮廓；
   - **高质量空间插值**：采用双三次（Cubic）平滑重采样；
   - **对比度自适应锐化 (CAS)**：基于 AMD FidelityFX CAS 的感知线性化重构，动态约束负权重，恢复边缘微小细节。
4. **裁切交互上限保护**：
   - 裁切视图 `InteractiveViewer` 与鼠标滚轮动态限制最大缩放倍率 $\text{maxScale} = \max(1.0, 1.0 / \text{baseScale})$，禁止放大超出原图原本物理分辨率。
5. **异步并发与无感体验**：
   - 全流程由 `Isolate.run` 调度至后台线程并发执行，主 UI 保持 60fps 配合半透明加载遮罩，零丢帧、零卡顿。

### 3.14 UGC 素材库 (Material Box) 与关卡制作两阶段流水线设计

为解决移动端原生相册选择器单选即退、重复翻找痛点，以及消除相册选图与网络搜图两条割裂的素材路径，系统引入「**素材库 (Material Box)**」中枢，将 UGC 关卡构建解耦为两阶段流水线：

```
                    ┌────────────────────────┐
                    │    多渠道生素材收集     │
                    │  (相册批量多选 / 在线下载) │
                    └───────────┬────────────┘
                                │ 统一入库
                                ▼
                    ┌────────────────────────┐
                    │  「素材库」待制作素材池  │
                    │   (Downloaded/Material)│
                    └───────────┬────────────┘
                                │ 挑选单张精细加工
                                ▼
                    ┌────────────────────────┐
                    │  CropPuzzlePage 制作关卡│
                    │ (自由裁剪 / 超分 / 难度) │
                    └───────────┬────────────┘
                                │ 生成关卡
                                ▼
                    ┌────────────────────────┐
                    │   「我的自制合辑」关卡   │
                    │   (CustomPuzzleItem)   │
                    └────────────────────────┘
```

1. **多选与分流交互原则 (方案 C)**：
   - **相册多选（$N > 1$）**：通过 `ImagePicker().pickMultiImage()` 一次性选取多张照片，后台并发校验分辨率并拷贝至 App 私有沙盒，生成缩略图元数据后批量入库素材库，并弹出轻量 SnackBar 提示（附带「查看素材库」快捷跳转）。
   - **相册单选（$N = 1$）**：自动将所选照片存入素材库备份，同时平滑无阻碍直接跳转进入 `CropPuzzlePage` 裁剪制作，兼顾即选即玩的超低门槛体验。
   - **在线图库下载**：Unsplash/Pixabay/Pexels 详情页点击下载或悬浮大图嗅探提取后，无缝汇聚入素材库。
2. **素材库全生命周期管理**：
   - 每张素材卡片展示来源平台（`本地相册` / `Unsplash` / `Pixabay` 等）、真实分辨率（`4K` / `2K` / `FHD` / `HD`）与文件体积；
   - 提供「制作拼图」直达裁剪流程、「单张删除」与「清空素材库」操作，彻底释放存储空间。

## 4. 数据持久化与存档体系

### 4.1 存档快照规范 (Snapshot v2)
- **坐标系统一规范**：碎片坐标统一采用**棋盘归一化浮点比例坐标**（$[0.0, 1.0]$）。
- **无损分辨率重映射**：跨设备同步或窗口拉伸 Resize 时，只需将归一化坐标乘当前屏幕实际 `(boardW, boardH)`，彻底解决错位问题。

### 4.2 本地仓储管理 (GameRepository)
- 管理 100 关官方关卡状态、多难度独立通关记录、每日挑战历史、自制拼图元数据与全局用户设置。
- **全局设置项**：拼图吸附音效 / 触感震动、12 款无缝桌板背景（`selectedBackground`，持久化 Key `jigsaw_setting_selected_background`）、碎片初始排布模式（`pieceScatterMode`：`tray | tabletop`）。
- **来源追踪字段**：`CustomPuzzleItem` 扩展 `sourceType`（`gallery | online | preset`）、`sourcePlatform` 与 `sourceUrl`，序列化向下兼容历史老数据。

---

## 5. 测试策略与矩阵

| 测试模块 | 测试类型 | 核心验证指标 |
|---|---|---|
| `EdgeLayoutTest` | 纯 Dart 单元测试 | 确定性（同 seed 拓扑恒定）、四向相邻互补镜像（一 tab 一 blank） |
| `PieceShapeTest` | 纯 Dart 几何测试 | 共享边路径重合度误差、局部包围盒与采样矩形 1:1 对齐 |
| `ImageUpscalerTest`| 纯 Dart 算法测试 | 2x 尺寸放大、温和导向降噪与 CAS 锐化管道正确性、低分辨率判定边界 |
| `SnapshotRestoreTest`| 纯 Dart 往返测试 | Snapshot v2 序列化与反序列化还原状态、坐标、朝向与簇归属 100% 一致 |
| `SnapAlgorithmTest` | 纯 Dart 算法测试 | 距离阈值内吸附、带朝向校验吸附、整组 Cluster 坐标协同平移 |
| `UndoManagerTest` | 纯 Dart 状态测试 | 连续多步状态入栈/撤销/重做幂等性 |
| `CropPuzzleTest` | Flutter Widget 测试 | 5 种标准长宽比、手势拖动裁切、动态最大缩放比限制校验 |
| `NewFeaturesTest` | Flutter Widget 测试 | 底图透视透明度循环、未解锁关卡预览/禁用、UGC 删除流程、自适应网格渲染 |

---

## 6. 开源许可证合规清单

| 依赖库 | 开源许可证 | 商业分发兼容性 |
|---|---|---|
| `flutter` | BSD-3-Clause | 宽松兼容 |
| `flame` | BSD-3-Clause | 宽松兼容 |
| `image_picker` / `path_provider` | BSD-3-Clause | 宽松兼容 |
| `shared_preferences` | BSD-3-Clause | 宽松兼容 |
