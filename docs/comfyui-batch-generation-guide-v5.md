# ComfyUI 批量生成拼图素材开发与使用指南 v5

> **文档版本**：v5.1（全量目录驱动 + 摄影/插画双管线 + 构图防截断增强）  
> **更新日期**：2026-09-02  
> **目标硬件**：单卡消费级 GPU（基准测试：NVIDIA RTX 4070 12GB）  
> **Python 环境**：`C:\Home\Develop\venv`（预装 numpy / Pillow / opencv-python / requests / rich）  
> **ComfyUI 根目录**：`F:\ai\ComfyUI\ComfyUI`（API 端口：`http://127.0.0.1:8188`）  

---

## 1. v5 相比 v4 的核心架构演进

v5 是拼图素材生成管线的重大代际升级，彻底重构了提示词组织逻辑与挂机调度机制：

| 维度 | v4 方案 | v5 / v5.1 方案 | 核心价值与收益 |
|---|---|---|---|
| **题库驱动源** | 依赖 hand-crafted 的优质预设池（每 Tag 仅 12 个写死 subject） | **全量目录驱动（Pure Catalog-Driven）**，直连 `docs/jigsaw-tag-subject-catalog.md` | 题目覆盖率扩大 5 倍（1200+ 独立主体），20 个 Tag 全部覆盖 |
| **生图风格管线** | 摄影与插画混编（同一词库中硬性切分） | **摄影流（Photo）与插画流（Illust）双库独立** | 插画流彻底剔除相机光圈词，引入水彩水粉大师艺术风格，避免风格杂糅 |
| **构图层次设计** | 前景/中景堆叠，易出现贴脸近景截断 | **模板化三景深（FG/MG/BG）+ 建立镜头约束** | 引入 `generous headroom, no cropped roof` 与中景锁定，彻底解决屋顶/烟囱被切问题 |
| **算力投放重心** | 盲目堆叠随机种子 `--reseed 2~3` | **主推 `--cards-per-subject`（不同修饰词变体）** | 实证实测证明同 prompt 换 seed 88% 无质变，不同修饰词组合收益高 3 倍以上 |
| **画幅与切片** | 混合 1:1, 2:3, 3:2 | **默认 1:1 原生正方形**（配置内保留 4:3 / 3:2 可选扩展） | 100% 契合游戏客户端原生物理切片网格，杜绝游戏内二次裁切导致的面积损失 |
| **工程健壮性** | 易因 ComfyUI 驱动假死而中断挂机 | **Hang 检测 + 每张实时落盘 + 定时深度卸载显存** | 90s 无响应主动探测进程、每张即时保存 `_progress.json`、断点续跑零损失 |
| **开箱易用性** | 每次必须手动输入长路径参数 | **`--workflow` 与 `--comfyui-root` 内置本地默认值** | 一键直接运行 `python scripts/my_comfyui_batch_gen_v5.py` 即可开跑 |

---

## 2. 工具链与核心文件清单

```text
scripts/
├── my_comfyui_batch_gen_v5.py         # [核心] 批处理调度引擎（纯 Python 标准库，零外部依赖）
├── my_prompt_library_v5.json          # [题库] 实景摄影专属词库（20 Tag / 1165 主体）
├── my_prompt_library_illust_v5.json   # [题库] 复古手绘插画专属词库（20 Tag / 1213 主体）
├── zimage_api_workflow_v5.json        # [工作流] 快手 Z-Image Turbo 官方 API 工作流
└── puzzle_quality_analyzer.py         # [质检] 拼图适玩度与物理指标打分工具

temp/
├── build_v5_library.py                # 摄影版提示词库构建脚本
└── build_illust_library.py            # 插画版提示词库构建脚本
```

---

## 3. 环境准备与验证

### 3.1 启动 ComfyUI

建议启动参数（针对 RTX 4070 12GB 优化显存）：
```bash
python main.py --listen 127.0.0.1 --port 8188 --fast fp8_matrix_mult --fp8_e4m3fn-text-enc --use-ck-attention
```

### 3.2 运行环境快速冒烟检查

使用配置好的 Python 虚拟环境验证连通性：
```powershell
# 1. 验证 Python 科学计算库
& "C:/Home/Develop/venv/Scripts/python.exe" -c "import numpy, PIL, cv2, rich; print('Python 依赖正常')"

# 2. 验证 ComfyUI 服务状态与工作流配置（空跑 5 个任务计划）
& "C:/Home/Develop/venv/Scripts/python.exe" scripts/my_comfyui_batch_gen_v5.py --dry-run --dry-run-count 5
```

---

## 4. 命令行参数完整参考手册

```powershell
python scripts/my_comfyui_batch_gen_v5.py [OPTIONS]
```

### 4.1 路径与服务配置

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--library` | `scripts/my_prompt_library_v5.json` | 提示词库 JSON 路径（换插画请传 `scripts/my_prompt_library_illust_v5.json`） |
| `--workflow` | `scripts/zimage_api_workflow_v5.json` | ComfyUI API 格式工作流 JSON 文件 |
| `--comfyui-root` | `F:\ai\ComfyUI\ComfyUI` | ComfyUI 根目录，用于将图片自动移动到目标输出目录 |
| `--host` | `http://127.0.0.1:8188` | ComfyUI HTTP 监听地址 |
| `--out` | **(必填)** | 图片最终归档输出目录（生成图片时强制必填，无默认值，防止误写入默认目录；`--dry-run` 或 `--list-tags` 时可省略） |

### 4.2 任务范围与调度策略

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--tags` | (全部) | 限定执行的分类 ID，以逗号分隔（如 `Architecture,Cartoon,Pets`） |
| `--list-tags` | - | 打印题库中包含的所有标签 ID、中文名及主体数量后退出 |
| `--per-tag N` | (全量) | 限制每个 Tag 仅生成 N 张（适合小批量测试验证） |
| `--cards-per-subject N`| `1` | **每种主体生成的卡片数**（每张独立抽取不同修饰词与种子，强烈推荐设为 `2` 或 `3`） |
| `--reseed N` | `1` | 同一 Prompt 抽取 N 个不同噪声种子（种子抽卡模式） |
| `--seed-base S` | `20260830` | 全局确定性随机数基底；换一个基数可重排全库修饰词搭配 |
| `--batch-per-tag N` | `4` | 每次交替调度每个 Tag 的出图数量；设为 `0` 表示串行跑完一个 Tag 再跑下一个 |

### 4.3 显卡运维与安全防护

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--hard-reset-minutes` | `10.0` | 每隔 N 分钟强制执行一次模型卸载与 VRAM 清空，杜绝显存碎片引发的驱动崩溃 |
| `--clean-every N` | `100` | 每生成 N 张图片进行一次显存释放清理 |
| `--timeout T` | `300.0` | 单张图片最大超时时间（秒） |
| `--retries R` | `2` | 单张图片遇到报错或超时后的自动重试次数 |
| `--resume` | `True` | 开启断点续跑（默认开启；读取目标目录下的 `_progress.json`，跳过已完成项） |
| `--no-resume` | - | 忽略已有进度，强制重新生成全量任务 |
| `--prune-missing` | - | 磁盘与进度联动同步：自动检测磁盘上已被删除的残次图片，重置其进度状态以便自动补生成 |
| `--dry-run` | - | 仅在控制台打印提示词组装计划与参数，不向 ComfyUI 发送真实请求 |
| `--dry-run-count N` | `5` | Dry-run 时打印的样例条数（**只要显式传入此参数，即自动激活 `--dry-run` 预览模式**） |

---

## 5. 两大生图管线实战范例

### 场景 A：复古水粉水彩插画管线（Jigsaw Illustration Pipeline）

针对欧美经典田园小屋、童话绘本、手作工坊等水彩水粉插画风格。

```powershell
# 1. 快速单图验证（测试建筑与卡通，每类各生成 1 张）：
& "C:/Home/Develop/venv/Scripts/python.exe" scripts/my_comfyui_batch_gen_v5.py `
  --library scripts/my_prompt_library_illust_v5.json `
  --tags Architecture,Cartoon `
  --per-tag 1 `
  --out D:/jigsaw_illust_test

# 2. 优选分类生产（田园庭院、欧洲小镇、复古交通、治愈宠物，每题材出 2 张变体）：
& "C:/Home/Develop/venv/Scripts/python.exe" scripts/my_comfyui_batch_gen_v5.py `
  --library scripts/my_prompt_library_illust_v5.json `
  --tags Architecture,Cities,Transportation,Pets `
  --cards-per-subject 2 `
  --out D:/jigsaw_illust_pack

# 3. 全量 20 个标签无人值守通宵挂机（共 1213 个主体，全量插画生成）：
& "C:/Home/Develop/venv/Scripts/python.exe" scripts/my_comfyui_batch_gen_v5.py `
  --library scripts/my_prompt_library_illust_v5.json `
  --out D:/jigsaw_illust_full
```

### 场景 B：纪实摄影写真管线（Realistic Photo Pipeline）

针对真实野生动物、宏观地理风光、花卉微距等摄影写实风格。

```powershell
# 1. 动植物与自然风光挂机（默认使用 my_prompt_library_v5.json）：
& "C:/Home/Develop/venv/Scripts/python.exe" scripts/my_comfyui_batch_gen_v5.py `
  --tags Animals,Birds,Nature,Landscapes,Flowers `
  --cards-per-subject 1 `
  --out D:/jigsaw_photo_raw

# 2. 中途意外断电或重启后的断点续跑：
& "C:/Home/Develop/venv/Scripts/python.exe" scripts/my_comfyui_batch_gen_v5.py `
  --resume `
  --out D:/jigsaw_photo_raw
```

---

## 6. 质量评估与后期放大（QA & Post-Processing）

### 6.1 拼图物理指标检测

生成完毕后，使用内置的物理引擎进行打分：

```powershell
# 1. 直接检测（未指定 --output 时，默认在输入目录中就地生成 HTML 与 JSON 报告）：
& "C:/Home/Develop/venv/Scripts/python.exe" scripts/puzzle_quality_analyzer.py `
  --input "D:/jigsaw_illust_pack" `
  --no-vlm

# 2. 或显式指定输出报告目录：
& "C:/Home/Develop/venv/Scripts/python.exe" scripts/puzzle_quality_analyzer.py `
  --input "D:/jigsaw_illust_pack" `
  --output "temp/qa_report_illust" `
  --no-vlm
```

* **合格指标基线**：
  * **评分**：`playability_score >= 75`（A 级以上）；
  * **死区率**：`dead_zone_ratio <= 0.05`（死黑/死白/纯色大色块不得超过 5%）；
  * **空间均衡度**：`spatial_balance_score >= 80`。

### 6.2 超分辨率放大（Upscale）建议

初次生成的 1024×1024 素材经过人工/机检初筛后，需要放大至 2048×2048 交付拼图切割：

* **实景照片（Photo）**：推荐使用 `4x-UltraSharp.pth` 或 `Nomos8k`，强化边缘与微观噪点质感；
* **水粉水彩插画（Illust）**：推荐使用 **`4x_NMKD-Superscale-SP_178000_G.pth`** 或 **`4x_foolhardy_Remacri.pth`**，保持手绘水粉笔触与色块边缘平滑，杜绝数码塑料感和高频噪点。

---

## 7. 常见故障排查（Troubleshooting）

| 异常现象 | 根本原因 | 解决方案 |
|---|---|---|
| `[fatal] no jobs produced, check --tags spelling` | 传入的 tag 名称拼写错误 | 运行 `--list-tags` 查看准确的标签英文 ID 列表 |
| `[hang] ComfyUI/driver unresponsive` | 长时间高负荷生成引起 CUDA 驱动轻微假死 | 脚本会在 90s 内主动探测并终止任务。调小 `--hard-reset-minutes`（如设为 `5.0`），重启 ComfyUI 后带 `--resume` 重新启动 |
| 生成图片被保存在 ComfyUI 目录未移动 | `--comfyui-root` 路径与实际安装路径不符 | 确认默认路径 `F:\ai\ComfyUI\ComfyUI` 是否存在，或手动传入 `--comfyui-root "你的路径"` |
| 生成插画中的建筑顶部被切掉 | 未使用 v5.1 提示词库或提示词中混入了近景词 | 确保使用 `my_prompt_library_illust_v5.json`，其内置的 `wide establishing view` 和 `midground` 约束会自动确保完整留白 |
