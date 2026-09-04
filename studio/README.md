# Content Studio — 拼图内容打包工作台

> 新一代拼图素材管理与资产打包工具（基于模块化分层、策略模式导出器与声明式响应式前端重塑）。  
> 对齐规范: `docs/catalog-tags-mapping-specification.md` (v3.0 Final)

---

## 一、 核心特性

1. **单一事实源 (SSOT)**
   - 全局唯一分类法元数据 `studio/taxonomy.py`，涵盖 14 个主 Tags 与模式匹配词库 `tag_patterns`。
   - 前端通过 `/api/taxonomy` 动态拉取，前端代码零硬编码，杜绝前后端规则漂移。
2. **纯批量标签操作模型 (Batch First)**
   - 彻底废除原版拥挤繁杂的单卡片详情抽屉。
   - 选中 1 张卡片即为单个编辑，选中多张即为批量操作。
   - 顶部工具栏支持：**覆盖设置 (Set)、追加 (Add)、移除 (Remove)、重置为兜底 (Clear)、标记已复核/待复核**。
3. **策略模式 (Strategy Pattern) 资产导出器**
   - 彻底废除 500 行的巨型过程式导出函数，拆分为各司其职的独立 Exporter 类：
     - `MainExporter`: 生成 `main.json`，转码复制关卡图片，自增版本；
     - `DailyExporter`: 制作 `YYYYMM.zip` 并增量更新 `daily.json`；
     - `EventExporter`: 导出主题活动（支持 `zip` 模式与 `array` 散图模式）；
     - `CollectionExporter`: 导出主题合集；
     - `ManifestManager`: 统一原子维护 `manifest.json` 纯路由清单。
4. **轻量极速架构 (Zero-Build & Zero-NPM)**
   - 后端仅依赖 Python 标准库与可选 Pillow（无第三方 Web 框架负担）；
   - 前端本地静态引用单文件版 Vue 3 运行时，告别 1000 行原生 DOM `innerHTML` 拼串，声明式响应更新。

---

## 二、 快速上手

### 1. 启动服务

```powershell
# 启动工作台 (默认端口 5188，并在浏览器自动打开)
python studio/server.py --open

# 或指定端口与主机
python studio/server.py --host 127.0.0.1 --port 5188 --open

# 模块化运行方式
python -m studio --open
```

启动后在浏览器打开：`http://127.0.0.1:5188`

### 2. 使用工作流

1. **输入路径**：
   - 源目录 (Source Dir)：填入图片目录（例如 `C:\Home\Temp\Jigsaw_Organized` 或 `F:\Images\levels`）；
   - 输出目录 (Output Dir)：填入目标发布目录（例如 `X:\www\game\test` 或 `D:\puzzle\out`）；
   - HTTP 根路径 (HTTP Base)：例如 `http://192.168.1.118/data/www/game/test`。
2. **点击「扫描目录」**：
   - 自动扫描所有层级图片，智能识别并合并现有 `tags.json`；
   - 未打标图片将自动根据其**父级物理目录名**推断匹配标准标签。
3. **分类与筛选**：
   - 点击顶部 14 主 Tag 筛选栏（风光、自然、花卉、动物、宠物、旅行、交通、温馨、美食、艺术、奇幻、缤纷、节日、其他等）；
   - 点击「仅看待复核」快速定位置信度不足或未分类的图片。
4. **批量打标**：
   - 勾选目标图片（或使用 `全选` / `Ctrl+A` / `选待复核`）；
   - 在选择器中选取目标标签，点击 `覆盖`、`追加` 或 `移除`；
   - 修改完成后点击右上角「💾 保存 tags.json」原子写回磁盘。
5. **资产打包导出**：
   - 点击右上角「🚀 导出资产」；
   - 切换 Main / Daily / Event / Collection 标签页，配置转码格式（WebP/JPEG）与重命名规则；
   - 点击「立即开始导出」，在内置控制台中实时查看打包日志。

---

## 三、 目录结构说明

```text
studio/
├── __init__.py
├── __main__.py               # python -m studio 启动入口
├── server.py                 # HTTP 服务端与 API 路由分发
├── taxonomy.py               # 分类体系与标签规范 (SSOT)
├── test_studio.py            # 核心单元与集成测试套件
├── core/
│   ├── scanner.py            # 图片发现与递归扫描
│   ├── image_proc.py         # Pillow 缩略图与格式转码 (WebP/JPEG/PNG)
│   └── tags_manager.py       # tags.json 兼容读取、合并与原子保存
├── exporters/
│   ├── base.py               # 导出器抽象基类
│   ├── registry.py           # 导出器注册中心与工厂分发
│   ├── manifest_manager.py   # manifest.json 纯路由清单管理
│   ├── main_exporter.py      # Main 关卡导出
│   ├── daily_exporter.py     # Daily 日历导出
│   ├── event_exporter.py     # Event 活动导出
│   └── collection_exporter.py# Collection 合集导出
└── static/
    ├── index.html            # 语义化 HTML 模板
    ├── css/studio.css        # 现代响应式样式
    ├── js/
    │   ├── api.js            # REST API 客户端
    │   └── app.js            # Vue 3 应用主控制器
    └── vendor/
        └── vue.global.prod.js# 本地静态 Vue 3 运行时
```

---

## 四、 自动化测试

运行内置的自动化测试套件：

```powershell
python -m unittest studio.test_studio
```
