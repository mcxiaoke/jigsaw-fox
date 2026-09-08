# Content Studio — 拼图内容管理与打包工作台

> 现代化、工业级本地拼图素材管理、智能物理质检、标签运营与多模式资产打包平台。  
> 对齐规范: `docs/catalog-tags-mapping-specification.md` (v3.0 Final)  
> 技术架构详见: [`studio/docs/studio-technical-architecture.md`](docs/studio-technical-architecture.md)

---

## 一、 工作台定位与核心特性

Content Studio 是为 JigsawFox 拼图游戏生态打造的本地化生产力工作台，专门解决图库规模膨胀（数万张图片）带来的**扫描缓慢**、**死区废图混入**、**人工打标低效**、**跨版本重复发布**等核心痛点。

### 🌟 核心功能亮点

1. **⚡ 0ms 增量秒开扫描（SQLite3 算力缓存）**
   - 源目录下维护 `.studio.db` 缓存文件，初次扫描自动固化文件元数据与 SHA-256 哈希；
   - 二次启动扫描直接命中缓存，无需重复读取磁盘和重新计算哈希，实测扫描速度达到 **2,500+ 张/秒**。
2. **🧩 工业级拼图物理质检与四周智能裁剪**
   - 8×8 切片分析，重点严惩**内部核心盲盒死区**（权重 $1.6\times$），大幅容忍**四周边框死区**（权重仅 $0.4\times$）；
   - 自动检测顶部纯色天空或底部暗部死区，给出四周智能裁切建议与适玩度提分预测；
   - 给出 S/A/B/C/F 品质评级及自适应推荐最大难度切片档位（如 225 块大师级）。
3. **🏷️ 纯批量标签操作模型（Batch First）**
   - 告别单图编辑的繁琐，选中即批量；
   - 支持**覆盖设置 (Set)、追加 (Add)、移除 (Del)、重置 (Clear)、一键复核/标记待复核**；
   - 基于父级物理目录名称自动推断初始标签。
4. **🛡️ 全生命周期防重发布账本（`exported.json`）**
   - 每次导出自动沉淀图片内容哈希与归属信息，卡片直观显示 `✔ 已导出` 角标；
   - 支持「隐藏已导出」与「选未导出」，轻松掌控可用新图库存水位。
5. **🔄 文件改名与移动路径自愈**
   - 依赖内容 SHA-256 哈希作为唯一技术凭证；
   - 无论图片在磁盘上被重命名还是移动到不同子目录，已有标签、审核状态和质检评分 **100% 自动继承**。
6. **🚀 策略模式资产打包引擎（Exporters）**
   - 支持四大业务模式一键导出：**主线关卡 (Main)、月度日历 (Daily)、限时活动 (Event)、精选合集 (Collection)**；
   - 自动进行 WebP/JPEG 格式转码与自适应规格生成，原子维护客户端 `manifest.json` 路由清单。
7. **🔒 Windows Winsock 端口独占防护**
   - 强制启用 `SO_EXCLUSIVEADDRUSE` 独占监听，彻底杜绝两个终端意外启动同一端口引发的静默踩踏。

---

## 二、 环境准备与启动指南

### 1. 环境依赖

- **Python**: 3.10 及以上（推荐 Python 3.12+）；
- **Pillow**: 用于基础图片读取与 WebP 导出转码；
- **OpenCV & NumPy**（推荐）：
  - 用于高精度物理适玩度与切片死区计算；
  - 若系统主 Python 未安装 `opencv-python`，系统会自动探测并调用 `C:\Home\Develop\venv` 虚拟环境中的解释器执行，或优雅降级为 Pillow 计算，**服务永不崩溃**。

### 2. 启动服务

进入项目根目录，在终端中运行：

```powershell
# 默认启动 (监听 127.0.0.1:5188 并在默认浏览器中自动打开)
python studio/server.py --open

# 模块化方式启动
python -m studio --open

# 指定自定义端口与主机 (测试或多开时推荐)
python studio/server.py --port 5200 --host 127.0.0.1 --open
```

### 3. 日志与调试参数

```powershell
# 启用详细 DEBUG 调试日志 (在终端输出完整调试信息)
python studio/server.py --debug

# 指定日志级别与日志持久化路径 (默认按日期命名保存在 temp/studio-YYYYMMDD.log)
python studio/server.py --loglevel DEBUG --logfile temp/my_studio.log
```

服务启动后，在浏览器访问：`http://127.0.0.1:5188`

---

## 三、 用户操作指南（五步全流程）

```
[1. 目录扫描] ──> [2. 品质筛选与质检] ──> [3. 批量打标复核] ──> [4. 保存 tags.json] ──> [5. 一键导出打包]
```

### 步骤 1：配置路径并执行 0ms 扫描

1. 在顶部配置栏填入三项路径：
   - **图片源目录 (Source Directory)**：存放原始素材图片的本地目录（如 `C:\Home\Temp\Jigsaw_Organized`）；
   - **输出目录 (Output Directory)**：资源包导出目标目录（如 `D:\puzzle\out` 或网络共享目录）；
   - **HTTP 根地址 (HTTP Base)**：客户端下载资源的 Base URL（如 `http://192.168.1.118/data/www/game/test`）。
   > 提示：配置会自动保存在浏览器本地存储（LocalStorage），下次打开无需重复输入。
2. 点击 **「🔍 扫描目录」**：
   - 终端与界面将流式显示扫描进度；
   - 扫描完成后自动显示图片总数、缓存命中率、已导出数量及待复核数量。

### 步骤 2：把控图片品质与适玩度

1. **卡片品质徽章**：
   - 每张缩略图右下角直观显示品质徽章：
     - <span style="color:#059669; font-weight:bold;">🏆 S 级 (80~100分)</span>：构图饱满、细节丰富、几乎无死区，适合 64~225+ 块大师级难度；
     - <span style="color:#0284c7; font-weight:bold;">⭐ A 级 (68~79分)</span>：细节良好，适合 36~100 块进阶难度；
     - <span style="color:#4f46e5; font-weight:bold;">👍 B 级 (55~67分)</span>：四周有少量平坦区，核心区域良好，适合 16~25 块入门或边缘裁切后使用；
     - <span style="color:#d97706; font-weight:bold;">💡 C 级 (45~54分)</span>：四周边框存在较大单色区，建议边缘裁切后升级使用；
     - <span style="color:#dc2626; font-weight:bold;">⛔ F 级 (&lt;45分)</span>：内部核心存在大面积纯色死区或清晰度严重虚化，**建议淘汰不收录**；
     - `? 质检`：尚未分析的图片，点击即可即时执行分析。
2. **品质筛选与排序**：
   - 工具栏 **「品质」下拉框**：可快速过滤出 `S 级 (大师)`、`C 级 (需裁切)` 或 `未质检` 图片；
   - 工具栏 **「排序」下拉框**：选择 `适玩度得分`，即可按质量高低排序。
3. **批量质检**：
   - 点击工具栏 **「⚡ 批量质检」** 按钮，后台将以每次 30 张的速度分批对未评分图片执行增量分析并实时刷新页面。
4. **高清大图查看器**：
   - 双击卡片打开大图查看器；
   - 画面下方无缝嵌入质检面板：直观查看综合得分进度条、全图死区/核心死区/边框死区比例、自适应最大切片推荐档位以及四周裁切升级建议；
   - 可点击 `🔄 重新质检` 强制刷新。

### 步骤 3：高效分类与纯批量打标

1. **标签导航栏**：
   - 左侧常驻 14 个核心大类分类栏（风光、自然、花卉、动物、宠物、旅行、交通、温馨、美食、艺术、奇幻、缤纷、节日、其他等）；
   - 点击任一标签即可快速查看该分类下的全部图片及已打标统计。
2. **快捷选择控制**：
   - `全选`：选中当前筛选出的所有图片；
   - `选待复核`：快速选中需要人工介入确认的图片；
   - `选未导出`：快速选中未被使用的纯新图素材。
3. **批量修改标签**：
   - 在选择器中选取目标标签；
   - 点击 **`覆盖 (Set)`**：将所选图片的标签全部替换为选定标签；
   - 点击 **`追加 (Add)`**：在保留原有标签的基础上追加新标签；
   - 点击 **`移除 (Del)`**：从所选图片中移除指定标签；
   - 点击 **`✔ 已复核`** / **`⚠ 待复核`**：批量切换人工复核标记。

### 步骤 4：保存与持久化 `tags.json`

- 打标调整完成后，点击右上角绿色的 **「💾 保存 tags.json」** 按钮；
- 系统采用临时文件交换的原子写入模式写回源目录，绝不丢失数据。
> 关键特性：即使未点击保存就关闭页面，底层的 `.studio.db` 已经完成了元数据与质检缓存的持久化，下次打开仍然保留所有技术指标。

### 步骤 5：一键打包导出资产

1. 点击右上角蓝色的 **「🚀 导出资产」** 唤起导出模态框；
2. 选择要导出的业务模式：
   - **主线关卡 (Main)**：按勾选顺序或升序自增生成主线关卡，自增发布版本号并更新 `main/index.json` 与不可变分卷；
   - **月度日历 (Daily)**：选择目标月份（如 `202609`），自动制作日历包 `zips/202609.zip` 并增量更新 `daily/index.json`；
   - **限时活动 (Event)**：指定活动标识（如 `autumn_festival`），支持**中英双语配置**（英文 Title 必填，英文 Desc 选填；Title (中文) 与 Desc (中文) 选填），打包活动专属资源；
   - **精选合集 (Collection)**：配置合集 ID，支持**中英双语配置**（英文 Title 必填，英文 Desc 选填；Title (中文) 与 Desc (中文) 选填，支持分类与金币定价），打包合集归档；
3. 配置图片转码格式（推荐 `WebP`，兼顾画质与极高压缩比）及重命名规则；
4. 点击 **「立即开始导出」**，在内置日志控制台中实时查看打包进度。

---

## 四、 目录结构一览

```text
studio/
├── __init__.py
├── __main__.py               # 模块入口 (python -m studio)
├── server.py                 # HTTP 服务网关、独占端口监听与 REST 路由
├── taxonomy.py               # 分类体系与标签定义 (单一事实源 SSOT)
├── test_studio.py            # 后端 23 个自动化单元测试
├── test_frontend.py          # 前端冒烟与无头浏览器 CDP 挂载测试
├── README.md                 # 工作台介绍与使用指南
├── docs/
│   ├── studio-technical-architecture.md             # 系统完整技术架构文档
│   └── content-studio-hash-and-export-tracking-design.md # 哈希与导出防重设计
├── core/
│   ├── cache_db.py           # SQLite3 算力缓存引擎 (.studio.db WAL 模式)
│   ├── quality_evaluator.py  # OpenCV 物理质检与四周智能裁剪引擎
│   ├── scanner.py            # 递归目录扫描与增量哈希
│   ├── image_proc.py         # Pillow 缩略图生成与格式转码
│   ├── tags_manager.py       # tags.json 增量对齐与原子写回
│   └── export_tracker.py     # exported.json 防重账本读写
├── exporters/
│   ├── base.py               # 导出器抽象基类
│   ├── registry.py           # 导出器策略注册中心
│   ├── manifest_manager.py   # manifest.json 路由清单原子维护
│   ├── main_exporter.py      # 主线关卡导出器
│   ├── daily_exporter.py     # 月度日历导出器
│   ├── event_exporter.py     # 主题活动导出器
│   └── collection_exporter.py# 官方合集导出器
└── static/
    ├── index.html            # 语义化响应式 HTML 界面
    ├── css/studio.css        # 现代 UI 样式与品质徽章
    ├── js/
    │   ├── api.js            # REST API 异步调用封装
    │   ├── app.js            # Vue 3 应用主逻辑与响应式状态
    │   └── taxonomy.js       # 前端降级备用标签配置
    └── vendor/
        └── vue.global.prod.js# 本地静态 Vue 3 运行时 (无需 npm 构建)
```

---

## 五、 质量校验与自动化测试

在提交代码或发布前，可运行内置的全套自动化测试套件：

```powershell
# 1. 后端与数据库单元测试 (23 个测试)
python -m unittest studio/test_studio.py

# 2. 前端无头浏览器冒烟与语法校验 (Node.js check + Chrome/Edge CDP)
python studio/test_frontend.py

# 3. 游戏客户端健全性检查 (针对主工程)
flutter analyze
flutter test
```
