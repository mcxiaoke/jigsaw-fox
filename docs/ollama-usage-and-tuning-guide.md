# Ollama 基础使用与模型配置调优指南

> 本文档系统整理了 Ollama 的基础操作、系统环境配置、显存与性能调优策略、Modelfile 核心参数详解以及常见实战模板，旨在帮助开发者快速掌握本地大模型（LLM/VLM）的高效部署与精细化调优。

---

## 目录

- [1. Ollama 架构与运行概览](#1-ollama-架构与运行概览)
- [2. 基础使用与常用 CLI 命令](#2-基础使用与常用-cli-命令)
- [3. 深入解析：Ollama 显存与内存占用机制](#3-深入解析ollama-显存与内存占用机制)
- [4. 全局环境变量配置](#4-全局环境变量配置)
- [5. Modelfile 语法与核心配置参数详解](#5-modelfile-语法与核心配置参数详解)
- [6. 场景化性能调优与优化策略](#6-场景化性能调优与优化策略)
- [7. Modelfile 实战配置模版](#7-modelfile-实战配置模版)
- [8. API 动态参数覆盖与程序化调用](#8-api-动态参数覆盖与程序化调用)
- [9. 日志查看与故障排查](#9-日志查看与故障排查)

---

## 1. Ollama 架构与运行概览

Ollama 采用轻量化、模块化的设计，底层主要由以下组件构成：

```
+-------------------------------------------------------------+
|               用户交互层 (CLI / Desktop GUI / WebUI)        |
+-------------------------------------------------------------+
                              | (HTTP REST / OpenAI API)
+-------------------------------------------------------------+
|                Ollama Server 调度与服务层                    |
|   - 模型注册表与文件管理 (Blobs / Manifests)                |
|   - 动态显存管理与多模型并发调度                            |
+-------------------------------------------------------------+
                              | (C/C++ Binding)
+-------------------------------------------------------------+
|                 Llama.cpp 高性能推理引擎                    |
|   - CUDA / ROCm / Metal / CPU AVX2 算子加速                 |
|   - GGUF 格式解析、KV Cache 管理、多模态 Vision 编码器      |
+-------------------------------------------------------------+
```

---

## 2. 基础使用与常用 CLI 命令

### 2.1 核心命令清单

| 命令 | 语法说明 | 示例 |
| :--- | :--- | :--- |
| `run` | 下载（如本地无）并运行交互式模型 | `ollama run qwen2.5:7b` |
| `serve` | 启动 Ollama 后台服务 | `ollama serve` |
| `pull` | 仅从远程仓库下载/更新模型 | `ollama pull deepseek-r1:8b` |
| `push` | 上传自定义模型到 Ollama Registry | `ollama push myusername/mymodel` |
| `list` / `ls` | 列出本地所有已下载的模型 | `ollama list` |
| `ps` | 查看当前正在内存/显存中运行的模型 | `ollama ps` |
| `stop` | 从显存中卸载指定模型，立即释放显存 | `ollama stop qwen2.5:7b` |
| `rm` | 删除本地模型文件 | `ollama rm llama3.2:1b` |
| `cp` | 复制并重命名本地模型 | `ollama cp qwen2.5:7b my-qwen` |
| `show` | 查看模型的 Modelfile、参数与架构信息 | `ollama show --modelfile qwen2.5:7b` |
| `create` | 基于自定义 Modelfile 构建新模型 | `ollama create my-custom -f ./Modelfile` |

### 2.2 CLI 交互模式快捷指令

在 `ollama run <model>` 交互会话中，输入以 `/` 开头的快捷指令：
* `/?` 或 `/help`：查看所有命令说明。
* `/set parameter <name> <value>`：临时调整当前会话参数（如 `/set parameter num_ctx 4096` 或 `/set parameter temperature 0.2`）。
* `/show parameters`：查看当前正在生效的运行参数。
* `/clear`：清空当前上下文历史对话记忆。
* `/bye` 或 `Ctrl + D`：退出交互会话。

### 2.3 多模态（VLM）命令行输入图片

对于多模态模型（如 `qwen2.5-vl`, `llava` 等），支持在交互中直接传入本地图片路径：
```text
>>> 这张图片里有什么？ c:\path\to\image.png
>>> 请提取图中的表格数据并转为Markdown: /Users/username/Desktop/chart.jpg
```

---

## 3. 深入解析：Ollama 显存与内存占用机制

为什么一个标称 3.3 GB 的量化模型，运行后可能会吃掉 8~12 GB 甚至更多显存？

### 3.1 显存消耗公式

$$\text{总显存} = \text{模型权重} + \text{KV Cache 缓存} + \text{计算临时缓冲区 (Scratch Buffer)} + \text{CUDA 运行时底座} + \text{多模态编码器 (若有)}$$

```
+-------------------------------------------------------------------------+
|                              显存总空间 (VRAM)                          |
+-------------------+--------------------+-------------------+------------+
|  模型权重 (Weights) | KV Cache (上下文)  | Compute Graph     | CUDA Context
|  ~3.3 GB (固定)    | ~4~8 GB (动态可调)  | ~0.5~1.5 GB (动态)| ~0.5~1.0 GB
+-------------------+--------------------+-------------------+------------+
```

### 3.2 显存四大组成部分深度剖析

1. **模型权重（Model Weights）**：
   * GGUF 文件的纯参数大小（例如 Q4_K_M 的 7B 模型约 4.5 GB，4B 模型约 3.3 GB）。完全卸载到 GPU 时为固定开销。
2. **KV Cache（键值缓存 —— 显存弹性波动的最大元凶）**：
   * 推理时模型需要缓存 Attention 的 Key 和 Value 矩阵，避免重复计算。
   * **计算公式**：$\text{KV Cache 大小} = 2 \times \text{层数} \times \text{KV头数} \times \text{头维度} \times \text{精度字节数} \times \text{上下文长度 (num\_ctx)}$。
   * **示例**：当 `num_ctx` 设置为 `64,000` (64k) 时，在默认 FP16 精度下，单是 KV Cache 就需要预分配 **7.5 ~ 8.5 GB** 显存！
3. **计算临时缓冲区（Compute Graph / Scratch Buffer）**：
   * 推理引擎在执行矩阵乘法（GEMM）和 Softmax 时存放中间激活值（Activation）的空间。`num_ctx` 和并发 Batch 越大，此区域越大。
4. **视觉编码器与图像 Tokens（仅限多模态模型）**：
   * 多模态模型拥有独立的 Vision Transformer (ViT)。图像输入会被切片拆解为数百到数千个视觉 Token，这些 Token 一并载入上下文，增加前向传播显存峰值。

---

## 4. 全局环境变量配置

通过配置操作系统环境变量，可以全局控制 Ollama 的存储、并发、监听与显卡调用策略。

### 4.1 核心环境变量列表

| 变量名 | 默认值 | 作用与配置说明 |
| :--- | :--- | :--- |
| `OLLAMA_MODELS` | Windows: `%USERPROFILE%\.ollama\models`<br>Linux: `/usr/share/ollama/.ollama/models`<br>macOS: `~/.ollama/models` | **修改模型文件存储路径**。建议将其指向容量充足的 SSD 数据盘（如 `D:\ollama_models`）。 |
| `OLLAMA_HOST` | `127.0.0.1:11434` | **修改监听地址**。若需局域网共享，可设置为 `0.0.0.0:11434`。 |
| `OLLAMA_NUM_PARALLEL` | `1`（自动根据显存调节） | **并发请求处理数**。设为 2 表示同时处理 2 个请求，注意：**KV Cache 显存会按倍数翻倍**。 |
| `OLLAMA_MAX_LOADED_MODELS` | `1`（自动根据显卡计算） | **同时常驻显存的模型数量**。设为 1 可防止多模型争抢显存引发 OOM。 |
| `OLLAMA_KEEP_ALIVE` | `5m` (5分钟) | **模型无请求后在显存保留时间**。<br>• `5m`：5分钟后自动卸载释放显存<br>• `-1`：永久常驻显存（适合专用服务器）<br>• `0`：请求处理完立即卸载 |
| `CUDA_VISIBLE_DEVICES` | 全部 GPU | **指定可见显卡**。多卡环境下指定使用哪张卡（如 `0` 或 `0,1`）。 |
| `OLLAMA_FLASH_ATTENTION` | `false` (部分版本默认自动) | 设置为 `1` 强制开启 Flash Attention 加速，可大幅缩减长文本推理的显存和加速计算。 |

### 4.2 Windows 环境变量配置方法

#### 方式 1：PowerShell 临时生效
```pwsh
$env:OLLAMA_MODELS="D:\AI_Models\ollama"
$env:OLLAMA_HOST="0.0.0.0:11434"
$env:OLLAMA_KEEP_ALIVE="10m"
ollama serve
```

#### 方式 2：Windows 系统永久生效
1. 按快捷键 `Win + R` 输入 `sysdm.cpl` 打开系统属性。
2. 依次点击「高级」->「环境变量」。
3. 在「系统变量」中新建对应键值（如 `OLLAMA_MODELS` = `D:\AI_Models\ollama`）。
4. **完全退出并重启 Ollama 托盘程序**。

---

## 5. Modelfile 语法与核心配置参数详解

Modelfile 是定制、固化 Ollama 模型行为的最强工具（类似于 Dockerfile）。

### 5.1 Modelfile 基础指令

```dockerfile
# 1. 基础模型源（可以是官方模型 tag，也可以是本地 GGUF 文件绝对路径）
FROM qwen2.5:7b

# 2. 运行时核心参数调整
PARAMETER num_ctx 8192
PARAMETER temperature 0.3
PARAMETER top_p 0.85
PARAMETER repeat_penalty 1.1

# 3. 系统提示词预设 (System Prompt)
SYSTEM """
你是一名资深的软件架构师。请以专业、精炼、严密的逻辑回答技术问题，优先输出高效且经过边界检查的代码。
"""

# 4. 自定义对话模板 (支持 Go Template 语法，通常沿用底模默认即可)
# TEMPLATE """..."""
```

使用命令构建：
```bash
ollama create my-architect -f ./Modelfile
```

---

### 5.2 核心参数（Parameters）全景速查表

| 参数名 | 类型 | 默认值 | 推荐取值范围 | 核心作用与调优指南 |
| :--- | :--- | :--- | :--- | :--- |
| `num_ctx` | int | `2048` (GUI版可调) | `2048` ~ `32768` | **上下文窗口大小 (Token)**。<br>• **显存第一杀手**。显存紧张时设为 `4096` 或 `8192`。<br>• 超过需求设得过大（如 64k）会浪费数 GB 显存。 |
| `num_gpu` | int | 自动判断 (全部) | `0` ~ `100` | **卸载到 GPU 的模型层数**。<br>• 设为 `0` 完全使用 CPU 推理。<br>• 若显存不够全放，可手动指定（如 24 层放 18 层），剩余放 CPU 内存。 |
| `temperature` | float | `0.8` | `0.0` ~ `2.0` | **生成温度/随机性**。<br>• `0.0 ~ 0.2`：极其严谨、确定，适合代码生成、数学推导、JSON 结构化提取。<br>• `0.7 ~ 0.8`：通用对话。<br>• `1.0 ~ 1.5`：小说创作、发散性头脑风暴。 |
| `top_p` | float | `0.9` | `0.1` ~ `0.95` | **核采样（Top-P / Nucleus Sampling）**。<br>在累积概率达到 `top_p` 的候选词集合中采样。越低越集中，越高更多样。配合 temperature 调节。 |
| `top_k` | int | `40` | `10` ~ `100` | **Top-K 采样**。<br>每步仅从概率最高的前 K 个词中挑选。降低该值可减少荒谬词汇的出现。 |
| `min_p` | float | `0.0` | `0.05` ~ `0.1` | **Min-P 采样（现代推荐采样方式）**。<br>过滤掉概率低于“最高词概率 $\times$ min_p”的所有词，在保证创造力的同时显著减少胡言乱语。 |
| `repeat_penalty` | float | `1.1` | `1.0` ~ `1.3` | **重复惩罚系数**。<br>• `1.0`：不惩罚。<br>• `1.1 ~ 1.2`：有效避免模型无限复读废话或卡在复读死循环。<br>• 设过高（>1.3）会导致模型拒绝使用常见介词和重复词汇。 |
| `presence_penalty` | float | `0.0` | `0.0` ~ `1.0` | **存在惩罚**。只要一个词在历史中出现过，就对其惩罚，鼓励谈论新话题。 |
| `frequency_penalty` | float | `0.0` | `0.0` ~ `1.0` | **频率惩罚**。词出现次数越多惩罚越大，减少同一词语反复出现。 |
| `num_predict` | int | `-1` (无限) | `128` ~ `4096` | **单次最大输出 Token 数**。<br>• `-1`：直到遇到停止词或达到上下文上限。<br>• 设固定值（如 `512`）可防止模型失控长篇大论。 |
| `stop` | string | 依赖模板 | 字符串列表 | **停止词**。<br>遇到该字符串立刻停止生成。如 `stop "<|im_end|>"`、`stop "User:"`。 |
| `seed` | int | `0` (随机) | 任意整数 | **随机种子**。固定种子（如 `42`）搭配 `temperature 0` 可实现 100% 确定可复现的输出结果。 |
| `num_thread` | int | 自动 (物理核数) | CPU 物理核心数 | **CPU 推理线程数**。在 CPU 或 GPU/CPU 混跑时，建议设为**物理核心数**，设为超线程逻辑核心数反而可能变慢。 |

---

## 6. 场景化性能调优与优化策略

### 6.1 场景一：显存不足 / 爆显存 (OOM) 瘦身调优

如果显卡显存较小（例如 6G / 8G / 12G）遇到显存吃满：

1. **第一优先级：缩减上下文窗口（`num_ctx`）**
   * 从默认过高的 32k/64k 降到日常够用的 `4096` 或 `8192`。
   * 仅此一项即可为显卡**释放 3G ~ 6G 显存**。
2. **选择适合的量化级别（Quantization）**
   * `Q4_K_M`：体积与精度黄金平衡点（推荐默认）。
   * `Q3_K_M` / `IQ3_XXS`：极限显存不足时使用，占用显存缩减约 20~30%。
   * `Q8_0` / `FP16`：仅在显存极其富余时用于追求极致精度。
3. **关闭不必要的并发**
   * 确保 `OLLAMA_NUM_PARALLEL=1`。

### 6.2 场景二：代码编写与结构化 JSON 输出调优

代码和数据提取场景要求逻辑严谨、格式绝对合规，不需要任何发散性思维：

* **推荐参数组合**：
  ```dockerfile
  PARAMETER temperature 0.1
  PARAMETER top_p 0.8
  PARAMETER repeat_penalty 1.05
  ```

### 6.3 场景三：CPU + GPU 混合推理（Offloading）性能调优

当模型体积大于显存容量（例如 12G 显存运行 70B 模型）：

1. **合理规划 GPU Offload 层数（`num_gpu`）**
   * 在 Modelfile 中指定加载部分层数到 GPU：
     ```dockerfile
     PARAMETER num_gpu 28
     ```
   * 监控显存，将 GPU 显存利用率维持在 85%~90%，留下 1~2GB 给 KV Cache 和 Compute Buffer。
2. **调优 CPU 推理线程数（`num_thread`）**
   * 设为 CPU 的 **物理核心数**（不要算超线程）。例如 8 核 16 线程的 CPU，设置 `num_thread 8`。
3. **保证足够的系统内存（RAM）带宽**
   * 纯 CPU/混合推理高度依赖内存带宽，确保双通道/四通道内存处于 XMP 高频状态。

---

## 7. Modelfile 实战配置模版

### 模版 1：日常低显存省电助手（高响应、轻显存）

适合 6G~8G 显卡，将显存占用压至 4G~5G 以内：

```dockerfile
FROM qwen2.5:7b
# 严格限制上下文至 4k，大幅缩减 KV Cache
PARAMETER num_ctx 4096
PARAMETER temperature 0.7
PARAMETER top_p 0.9
PARAMETER repeat_penalty 1.1
PARAMETER num_predict 2048

SYSTEM """
你是贴心高效的个人 AI 助理。请用简洁明了、逻辑清晰的中文回答问题。
"""
```

---

### 模版 2：极客代码与架构专家（严格确定性输出）

适合编程辅助、Shell 脚本编写、Bug 诊断：

```dockerfile
FROM qwen2.5-coder:7b
PARAMETER num_ctx 8192
# 低温度抑制幻觉，保证代码准确性
PARAMETER temperature 0.1
PARAMETER top_p 0.7
PARAMETER repeat_penalty 1.05

SYSTEM """
你是一名资深的全栈技术专家与架构师。
要求：
1. 给出高质量、现代化、符合生产规范的代码。
2. 包含必要的类型标注与关键边界错误处理。
3. 解释说明力求直击要害，代码先行。
"""
```

---

### 模版 3：多模态视觉图文分析助手（VLM 专用配置）

适合运行 `qwen2.5-vl:7b` 或 `minicpm-v`：

```dockerfile
FROM qwen2.5-vl:7b
# 多模态模型包含高分辨率图像 token，8192 是平衡显存与多图分析的理想尺寸
PARAMETER num_ctx 8192
PARAMETER temperature 0.2
PARAMETER top_p 0.85
PARAMETER repeat_penalty 1.15

SYSTEM """
你是一名具备敏锐视觉理解能力的专家。在分析图片时：
1. 准确定位并识别画面中的文字、图表、物体与空间关系。
2. 若涉及图表和表格，优先将其结构化还原为 Markdown 表格。
"""
```

---

## 8. API 动态参数覆盖与程序化调用

除了通过 Modelfile 固化参数外，Ollama 的 HTTP API 允许在每次请求时**动态覆盖参数**。

### 8.1 原生 Ollama API (`POST /api/chat`)

```json
POST http://localhost:11434/api/chat
Content-Type: application/json

{
  "model": "qwen2.5:7b",
  "messages": [
    {
      "role": "user",
      "content": "请用Python写一个快速排序算法"
    }
  ],
  "stream": false,
  "options": {
    "num_ctx": 4096,
    "temperature": 0.1,
    "top_p": 0.8,
    "repeat_penalty": 1.1,
    "num_predict": 1024
  }
}
```

### 8.2 OpenAI 兼容接口 (`POST /v1/chat/completions`)

Ollama 原生内置了与 OpenAI 兼容的端点，可无缝对接各类生态客户端（如 LangChain、LlamaIndex、NextChat、Cherry Studio 等）：

* **Base URL**：`http://localhost:11434/v1`
* **API Key**：任意字符串（如 `ollama`）

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:11434/v1",
    api_key="ollama"
)

response = client.chat.completions.create(
    model="qwen2.5:7b",
    messages=[
        {"role": "system", "content": "你是一个严谨的助手。"},
        {"role": "user", "content": "你好！"}
    ],
    temperature=0.3,
    max_tokens=500,
    extra_body={
        # 传入 Ollama 特有高级参数
        "options": {
            "num_ctx": 4096
        }
    }
)

print(response.choices[0].message.content)
```

---

## 9. 日志查看与故障排查

### 9.1 查看实时运行日志

当遇到模型加载失败、显存异常或推理缓慢时，首先查看服务器日志：

* **Windows (桌面版)**：
  日志文件位于：`%LOCALAPPDATA%\Ollama\server.log`
  ```pwsh
  # PowerShell 实时追踪最新日志
  Get-Content "$env:LOCALAPPDATA\Ollama\server.log" -Wait -Tail 30
  ```
* **Linux (Systemd 服务)**：
  ```bash
  journalctl -u ollama -e --no-pager -f
  ```
* **macOS**：
  ```bash
  tail -f ~/.ollama/logs/server.log
  ```

### 9.2 如何看懂日志中的“显存分配表”？

当 Ollama 加载模型时，日志中会打印类似如下的关键段落：

```text
llama_model_loader: loaded meta data with 33 key-value pairs
llm_load_print_meta: model type       = 7B
llm_load_print_meta: n_ctx_train      = 32768
llm_load_tensors: offloaded 28/28 layers to GPU
llm_load_tensors: VRAM used: 4480.25 MiB (model weights)
llama_new_context_with_model: n_ctx   = 8192
llama_new_context_with_model: KV self size  = 1024.00 MiB
llama_new_context_with_model: compute buffer = 450.00 MiB
llama_new_context_with_model: total VRAM estimated = 5954.25 MiB
```

* `offloaded X/Y layers to GPU`：验证模型层是否全部进入显卡（如 28/28 表示 100% 显卡运行，若为 15/28 则为混合推理）。
* `model weights`：权重显存大小。
* `n_ctx` 与 `KV self size`：当前实际分配的上下文大小与 KV 缓存显存占用。
* `compute buffer`：计算图临时空间。

### 9.3 常见问题快速解决方案

1. **报错 `CUDA out of memory` 或直接闪退**：
   * 检查 `num_ctx`，将其缩小到 `4096` 或 `2048`。
   * 检查后台是否有其他程序占用了显存（使用 `nvidia-smi` 查看）。
2. **模型生成时无限重复或陷入死循环**：
   * 检查 `repeat_penalty`，适当提升至 `1.15 ~ 1.2`。
   * 检查该模型对应的 Modelfile 是否缺少正确的 `stop` 词（如 `<|im_end|>`）。
3. **输出过于保守、机械，缺乏创造力**：
   * 适当提高 `temperature`（至 `0.8 ~ 1.0`）和 `top_p`（至 `0.9 ~ 0.95`）。
4. **更换模型存储路径后原有模型不见了**：
   * 检查 `OLLAMA_MODELS` 路径是否正确写入系统环境变量，并将原目录下的 `manifests` 和 `blobs` 文件夹完整拷贝至新路径中。
