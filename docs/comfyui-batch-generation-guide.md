# 本地 ComfyUI 批量生成拼图素材操作指南

> **文档状态**：可执行 v1.0（生成链路已用 mock 服务冒烟验证，尚未在真实 GPU 上跑通全量）  
> **目标硬件**：NVIDIA RTX 4070 12GB（其他 12GB 卡同理，8GB 需改用 GGUF 量化版）  
> **创建日期**：2026-08-30  
> **关联文档**：`docs/puzzle-image-selection-standard.md`（选图标准）、`docs/jigsaw-image-tagging-specification.md`（21 tag 定义）  
> **配套文件**：`scripts/comfyui_batch_gen.py`、`scripts/jigsaw_prompt_library.json`

---

## 1. 模型选型结论

**主力：Z-Image Turbo（FP8 量化版）**

| 模型                                 | 参数        | 步数    | 许可                  | 4070 12GB | 判定     |
| ---------------------------------- | --------- | ----- | ------------------- | --------- | ------ |
| **Z-Image Turbo FP8**              | 6B        | 8     | **Apache 2.0（可商用）** | 舒适        | **选它** |
| FLUX.2 Klein 4B FP8                | 4B        | 4     | Apache 2.0（可商用）     | ~8.4GB    | 备选     |
| SDXL 微调（Juggernaut XL / RealVisXL） | 3.5B      | 20~30 | OpenRAIL 及各自许可      | 舒适        | 仅作精修补位 |
| ~~FLUX.1-dev / FLUX.2-dev~~        | 12B / 32B | 20~50 | **非商业**             | 勉强        | **排除** |

选它的三条理由：

1. **许可**。素材要进 App。FLUX.1-dev 与 FLUX.2-dev 都禁止商用，跑一晚上最后不能用是纯浪费。Z-Image Turbo 与 FLUX.2 Klein 4B 均为 Apache 2.0，生成内容归你。
2. **步数**。8 步 vs SDXL 的 20~~30 步，同样的挂机时间产能是 3~~4 倍。
3. **中文 prompt**。文本编码器是 Qwen3-4B，中文描述直出，20 个 tag 里的「节日」「四季」这类中文语境很好写。

> Z-Image 由阿里通义实验室（Tongyi-MAI）于 2025-11 发布，HuggingFace 仓库 `Tongyi-MAI/Z-Image-Turbo`，ComfyUI 有 Day-0 原生支持。

---

## 2. 环境准备

### 2.1 模型文件

从 HuggingFace `Tongyi-MAI/Z-Image-Turbo` 下载，按以下位置放置：

| 文件                                     | 目标目录                               | 体积      |
| -------------------------------------- | ---------------------------------- | ------- |
| `z_image_turbo_fp8_e4m3fn.safetensors` | `ComfyUI/models/diffusion_models/` | ~6 GB   |
| ` .safetensors`                        | `ComfyUI/models/text_encoders/`    | ~7 GB   |
| `ae.safetensors`                       | `ComfyUI/models/vae/`              | ~335 MB |

放大模型 `4x-UltraSharp.pth` 放 `ComfyUI/models/upscale_models/`。

> 12GB 显存放不下 FP8 全量常驻时，ComfyUI 会自动做 CPU offload，速度会掉。若频繁 OOM，改用社区 GGUF Q4/Q3 量化版（降到 5~6GB），代价是系统内存占用升高，建议 32GB 内存。

### 2.2 磁盘与内存

- 模型约 14 GB，输出 3100 张 1024² PNG 约 4~6 GB，**预留 40 GB 空闲空间**
- 系统内存建议 ≥ 16 GB（GGUF 方案需 32 GB）

### 2.3 启动参数（4070 性能关键，实测相差 6 倍）★

Z-Image Turbo 是 FP8 量化模型，必须同时满足两点才快：

1. **让 FP8 张量核心参与计算**：加 `--fast fp8_matrix_mult`（Ada 架构 sm89 原生支持 FP8 矩阵乘）
2. **把 8GB 文本编码器也量化**：加 `--fp8_e4m3fn-text-enc`（8GB → ~4GB），否则 6.1+8=14GB 超出 12GB 显存，触发频繁 CPU offload

**反例（踩过坑）**：`--fast fp16_accumulation` 只启用 FP16 累积，FP8 权重走 FP16 计算路径，4070 的 FP8 张量核心闲置，且文本编码器不量化导致 offload —— 实测 **21.6 秒/张**（正确配置应 < 10 秒/张，相差 6 倍）。

启动脚本已放在 ComfyUI 根目录：

| 脚本 | 参数 | 用途 |
|------|------|------|
| `run_nvidia_gpu_fp8.bat` | `--fast fp8_matrix_mult --fp8_e4m3fn-text-enc` | 推荐，全速 |
| `run_nvidia_gpu_fp8_safe.bat` | `--fp8_e4m3fn-text-enc` | 保守回退（fp8_matrix_mult 崩溃或出图有瑕疵时用） |

**验证**：重启后跑 `python temp/benchmark_zimage.py`（5 张 1024²），平均应 < 10 秒/张，此前基线为 22 秒。

---

## 3. 搭建工作流并导出 API JSON

> **本仓库已提供验证过的现成工作流**：`scripts/zimage_api_workflow.json`（10 节点，UNETLoader fp8 + CLIPLoader lumina2 + EmptySD3LatentImage + KSampler 9步/cfg1.1/res_multistep + ModelSamplingAuraFlow shift=3，已在 4070 真机出图验证）。以下步骤仅在你想自行修改工作流时参考。

脚本不猜测节点结构，只往你导出的工作流里注入参数，因此**工作流由你在 ComfyUI 里搭**。

### 3.1 最小工作流

用 ComfyUI 内置 Z-Image 模板（或手动连）：

```
UNETLoader (z_image_turbo_fp8) ─┐
                                ├─> KSampler ─> VAEDecode ─> SaveImage
CLIPTextEncode (Qwen3-4B) ──────┘        ↑
                                         │
                            EmptyLatentImage (宽高)
```

**四个节点必须设置 title**（右键节点 → Title），脚本靠 title 定位：

| 节点               | 建议 title          | 脚本注入            |
| ---------------- | ----------------- | --------------- |
| CLIPTextEncode   | `Positive Prompt` | 正向提示词           |
| KSampler         | `Sampler`         | seed、steps、cfg  |
| EmptyLatentImage | `Empty Latent`    | width、height    |
| SaveImage        | `Save`            | filename_prefix |

> 若忘记设 title，脚本会退化为按 class_type 自动探测，多数情况下也能命中。想完全可控就用 `--prompt-node` 等参数显式指定节点 ID。

### 3.2 导出

ComfyUI 菜单 → **Save (API Format)** → 存为 `wf_zimage_api.json`。

注意：**不是**普通的 `Save`，普通格式带 UI 布局信息，脚本无法解析。

### 3.3 采样参数

| 项         | 值                               | 说明                            |
| --------- | ------------------------------- | ----------------------------- |
| steps     | 8                               | 蒸馏模型为 8 步优化，加步数不涨质量只费时间       |
| cfg       | **1.0**                         | 蒸馏模型固定；**CFG=1 意味着负向提示词完全无效** |
| sampler   | euler                           |                               |
| scheduler | simple                          |                               |
| 尺寸        | 1024×1024 / 896×1344 / 1344×896 | 见 §4                          |

---

## 4. 分辨率策略：小图生成 + 2x 超分

**不要直接生成 2K 以上**——Z-Image 超过 2K 输出会发软，且显存与时间翻倍。

| 目标比例  | 生成尺寸      | 2x 超分后    | 短边       | 400 块档单块像素 |
| ----- | --------- | --------- | -------- | ---------- |
| 1:1   | 1024×1024 | 2048×2048 | **2048** | 102 px     |
| 2:3 竖 | 896×1344  | 1792×2688 | **1792** | 90 px      |
| 3:2 横 | 1344×896  | 2688×1792 | **1792** | 112 px     |

三个都落在选图标准的 1440~2160 甜点区，够 400 块大师档。

**超分做法**：生成阶段先只出图，全部跑完后用 ComfyUI 建一条批量放大流（`Load Image Batch From Dir` → `Upscale Image (using Model)` → `Save Image`），装 `ComfyUI-Inspire-Pack` 提供目录批量加载节点。batch size 保持 1，靠 Batch Count 顺序处理，避免 OOM。

---

## 5. 关键约束：CFG=1 时负向提示词无效

Z-Image Turbo 是蒸馏模型，**CFG 固定 1.0，negative prompt 不参与采样计算**。

所以没法写 `blurry, plain background` 来防死区。只能两条路：

1. **正向描述硬编码防死区** —— 已内置在 prompt 库的 `quality_suffix` 中：
   ```
   highly detailed, intricate detail across the entire frame, dense visual texture,
   rich and varied color palette, busy composition, filled frame with corner-to-corner detail,
   sharp focus throughout, even balanced lighting
   ```
2. **事后质检过滤** —— 用 `puzzle_quality_analyzer.py` 把不合格的直接扔掉（见 §8）

这是 Turo/Klein 这类蒸馏模型的通用特性，不是 bug。若确实需要负向控制，只能换非蒸馏模型（SDXL 或 Z-Image-Base），代价是速度掉 3~5 倍。

---

## 6. Prompt 库与配额

`scripts/jigsaw_prompt_library.json` 定义了 20 个 tag，按拼图适玩性分三级：

| 级别    | tag                                                                                                     | 每 tag 张数    | 说明             |
| ----- | ------------------------------------------------------------------------------------------------------- | ----------- | -------------- |
| **A** | Nature, Landscapes, Flowers, Cities, Architecture, Food, Art, Transportation, Seasons, Holidays, Others | 180×10 + 80 | 纹理密、色彩多、分布散    |
| **B** | Animals, Pets, Birds, Fantasy, People                                                           | 150×5       | 需强制加环境，避免棚拍纯背景 |
| **C** | Ocean, Space, Abstract, Cartoon                                                                         | 80×4        | 死区或歧义高危，配额减半   |

**合计 2950 张**，RTX 4070 约 6~8 小时跑完。

### 6.1 C 级 tag 的专项处理

| tag          | 风险               | 库内已做的规避                                                |
| ------------ | ---------------- | ------------------------------------------------------ |
| **Ocean**    | 大片水面与天空是经典死区     | 只生成珊瑚礁、潮池、浪花、海港、礁石滩；禁 "empty sea / open horizon"       |
| **Space**    | 黑色太空在检测器里就是死区    | 只生成星云、行星地表、空间站内部、船坞；禁 "black void"                     |
| **Abstract** | 规则图案造成位置歧义，比死区更糟 | 只生成有机不规则纹理（大理石纹、树皮、锈迹、岩层）；禁 "grid / stripes / tiling"  |
| **Cartoon**  | 扁平卡通背景是死区        | 强制 "fully rendered detailed background"；建议换 Z-Anime 变体 |

### 6.2 People 的合规处理

`People` tag 全部走**人群场景**（市集、游行、厨房、图书馆），不生成单人肖像。这一箭双雕：

- 规避棚拍纯背景死区
- 规避肖像权风险（App 要商用，可识别人脸是雷区）

---

## 7. 脚本用法

### 7.1 查看配额

```bash
python scripts/comfyui_batch_gen.py --list-tags
```

### 7.2 干跑（不调 ComfyUI，只看生成的 prompt）

```bash
python scripts/comfyui_batch_gen.py \
  --workflow wf_zimage_api.json \
  --dry-run --dry-run-count 5
```

**这一步必做。** 确认节点探测正确（`[plan] nodes prompt=6 seed=3 size=5 save=9`）且 prompt 读起来合理，再上真机。

### 7.3 小批量验证

```bash
python scripts/comfyui_batch_gen.py \
  --workflow wf_zimage_api.json \
  --comfyui-root D:/ComfyUI \
  --out D:/jigsaw_raw \
  --tags Nature,Flowers,Ocean \
  --per-tag 20
```

先跑 60 张：看显存峰值、单张耗时、实际画质。确认无问题再全量。

### 7.4 全量挂机

```bash
python scripts/comfyui_batch_gen.py \
  --workflow wf_zimage_api.json \
  --comfyui-root D:/ComfyUI \
  --out D:/jigsaw_raw \
  --steps 8 --cfg 1.0 \
  --timeout 300 --retries 2 --clean-every 100
```

### 7.5 常用参数

| 参数                        | 默认                      | 说明                                                 |
| ------------------------- | ----------------------- | -------------------------------------------------- |
| `--host`                  | `http://127.0.0.1:8188` | ComfyUI 地址                                         |
| `--comfyui-root`          | —                       | **必填**，用于把图从 ComfyUI output 目录搬走，否则文件会堆在 ComfyUI 里 |
| `--out`                   | `jigsaw_raw`            | 输出根目录                                              |
| `--tags`                  | 全部                      | 逗号分隔，限定跑哪些 tag                                     |
| `--per-tag`               | 库内 quota                | 覆盖每 tag 张数                                         |
| `--rounds`                | —                       | **每 subject 抽 N 张卡**，总张数 = 各 tag subject 数 × N，优先级最高 |
| `--sec-per-image`         | 16                      | 仅用于 ETA 估算显示的假设单张耗时（4070 fp8 不同 prompt 实测值）      |
| `--seed-base`             | `20260830`              | 改它可整体重洗所有 prompt                                   |
| `--clean-every`           | 100                     | 每 N 张做一次深度显存清理                                     |
| `--hard-reset-minutes`    | 10                      | **每 N 分钟强制卸载模型 + 释放显存**，防长跑碎片累积拖垮驱动           |
| `--stuck-timeout`         | 90                      | 超该秒数未出图即探活，判定驱动卡死（正常 ~16s）                      |
| `--max-stuck`             | 3                       | 连续卡死 N 次主动中止并保存进度（避免整机假死）                       |
| `--no-resume`             | off                     | 忽略进度重跑（换 prompt 库后用）                               |
| `--timeout` / `--retries` | 300 / 2                 | 单张超时与重试                                            |

### 7.6 如何规划跑批时长（跑多久 = 张数 × 单张耗时）

单张耗时（RTX 4070 实测）：`--rounds` 模式下计划行会直接打印预计小时数。

| 目标 | 命令示例 | 张数 | 预计 |
|------|----------|------|------|
| 快速验收 | `--rounds 1` | ~260 | 0.9 小时 |
| 一晚（8h） | `--rounds 10` | ~2600 | 8.8 小时 |
| 一天一夜（20h） | `--rounds 24` | ~6240 | 21 小时 |
| 想跑更久 | 加大 rounds，或 `--rounds 10 --tags Nature,Flowers` 只跑指定类 | 按需 | 按需 |

**轮次与多样性的关系**：每轮覆盖全部 subject 一次（相邻张必不同场景），轮与轮之间同一 subject 会换一组光线/视角/细节/色调并换 seed —— 相当于对每个场景抽 N 张卡，从中挑最好的。

**断点续跑**：跑任意时长，关机/中断/换机都不怕，重跑同一条命令自动跳过已完成。想"分批跑"就反复执行同一条命令，每次跑到想停就 Ctrl+C。

**加 subject**：编辑 `scripts/jigsaw_prompt_library.json` 对应 tag 的 `subjects` 数组追加描述即可，`--rounds` 会自动按新数量重算总张数。

### 7.7 长跑稳定性（防驱动卡死）★

**实测教训**：连续跑 1550 张（约 7 小时）后 CUDA 驱动卡死，整机假死只能强制关机。但**进度文件完好、0 失败**，重跑同命令即从第 1551 张续跑 —— 断点续跑机制在真实故障下验证有效。

三层防护（脚本内置，默认值即可用）：

| 机制 | 默认 | 作用 |
|------|------|------|
| 定时硬重置 | 每 10 分钟 | `unload_models + free_memory`，清空显存碎片与驻留模型，让 GPU 周期性"喘气" |
| 卡死探测 | 单张超 90s | 探活 `/system_stats`，驱动挂起时立即判定而非干等 240s 超时 |
| 连续卡死中止 | 3 次 | 判定不可恢复时主动退出并落盘进度，避免整机假死 |

**注意**：驱动级硬卡死软件无法自救。脚本能做到的是**预防**（定时释放）+ **早止损**（保住进度）。真卡死后：重启机器 → 启动 ComfyUI → 重跑同一条命令续跑。

**降低卡死概率的额外措施**（推荐全做）：

1. **移除第三方 custom nodes**：长跑时第三方节点内存泄漏是头号嫌疑。批量跑的工作流只用核心节点，把 `custom_nodes/` 下非必需目录移走即可（保留 ComfyUI-Manager 无妨）
2. **不要同时开吃显存的程序**：浏览器（尤其开 WebGL 页面）、游戏、视频播放器
3. **中途检查**：每 4~6 小时扫一眼日志，若单张耗时从 16s 持续涨到 25s+，Ctrl+C 重启 ComfyUI 后续跑
4. **调大释放频率**：`--hard-reset-minutes 5` 更激进（代价：每次释放后下一张需重载模型 +7s，约 0.4s/张）

### 7.8 输出结构

```
D:/jigsaw_raw/
├── Nature/
│   └── Nature_0007_3841923847_896x1344.png
├── Flowers/
├── ...
├── _metadata/
│   ├── Nature.jsonl          # 每张图的 prompt / seed / 尺寸 / 时间戳
│   └── Flowers.jsonl
└── _progress.json            # 断点续跑进度
```

文件名格式：`<tag>_<序号>_<seed>_<宽>x<高>.png`，seed 直接可见，便于复现。

---

## 8. 挂机前检查清单

- [ ] `--dry-run` 通过，节点探测到 4 个节点且 ID 正确
- [ ] `--per-tag 20` 小批量跑过，显存峰值 < 11 GB，单张耗时可接受
- [ ] 磁盘剩余空间 > 40 GB
- [ ] 关闭 Windows 睡眠/休眠（电源计划设"从不"）
- [ ] 关闭占用显存的程序（浏览器硬件加速、其他 AI 工具）
- [ ] ComfyUI 以 `--listen` 之外的方式本地启动即可，无需外网暴露
- [ ] 确认存放 `--comfyui-root` 的路径正确，否则图会留在 ComfyUI 的 output 里

---

## 9. 生成后接质检

生成完直接跑已有的质检脚本，把不合格的先筛掉：

```bash
python scripts/puzzle_quality_analyzer.py --input D:/jigsaw_raw --recursive
```

参考 `docs/puzzle-image-selection-standard.md` §7.2 的等级映射，只保留 **A 级以上**进人工环节。

预期留存率：

| 阶段         | 数量    | 说明                 |
| ---------- | ----- | ------------------ |
| 生成         | 3100  | 挂机 6~8 小时          |
| OpenCV 机检后 | ~1100 | 淘汰死区、虚化、低色熵，约 5 分钟 |
| 人工缩略图墙后    | ~550  | 淘汰重复纹理与题材跑偏，约 1 小时 |
| 裁切归档入库     | ~520  | 每 tag 约 25 张       |

> 机检跑完再补一步：**按 tag 看缩略图墙**。AI 生成图特有的"局部结构崩坏"和"重复细节假锚点"是脚本抓不到的，只能人眼扫。

---

## 10. 故障排查

| 现象                                  | 原因                            | 处理                                                                |
| ----------------------------------- | ----------------------------- | ----------------------------------------------------------------- |
| `could not locate node(s): prompt`  | 节点无 title 且 class_type 不在已知列表 | 给节点设 title 含 prompt / seed / size / save，或用 `--prompt-node` 指定 ID |
| `no image file found in output dir` | `--comfyui-root` 没给或路径错       | 检查路径；脚本靠它拼 `output/<subfolder>/<file>`                            |
| 跑几十张后 OOM                           | 显存碎片累积                        | 调小 `--clean-every`（如 50）；模型换 GGUF 量化版                             |
| 单张超过 300s                           | 触发了 CPU offload               | 显存不够，换更小量化；或提高 `--timeout`                                        |
| prompt 没变化                          | 进度文件记录了已完成                    | 用 `--no-resume`，或换 `--seed-base`                                  |
| 图片发灰                                | VAE 不匹配                       | Z-Image 用配套 `ae.safetensors`，不要用 SDXL VAE                         |
| 出图软糊                                | 直接生成了 >2K                     | 回到 §4 的小图生成 + 2x 超分路径                                             |

---

## 11. 验证状态

已用 mock ComfyUI 服务（`temp/mock_comfyui_server.py`）冒烟验证：

- 节点探测与参数注入
- 排队 → 轮询 history → 搬文件 → 写元数据 完整链路
- ComfyUI output 目录不留残留文件
- 断点续跑不重复生成

**尚未在真实 GPU 上跑通全量**，首次真机运行务必走 §7.3 的小批量验证。
