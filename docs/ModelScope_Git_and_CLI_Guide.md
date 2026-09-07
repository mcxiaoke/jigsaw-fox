# ModelScope (魔搭社区) 资源分发与版本管理实战指南

本指南专为游戏 App 静态资源（Assets/Zip/Data）分发设计，重点讲解 **Git + Git LFS 原生版本管理** 与 **ModelScope 官方 CLI 工具** 的完整使用流程，解决仓库类型混淆、版本分支游离及大文件追踪问题。

---

## 核心概念：Model 库 vs Dataset 库

在 ModelScope 中，**模型（Model）** 和 **数据集（Dataset）** 是两套相互独立的底层 Git 仓库系统：

* **模型仓库 URL 结构**：`https://modelscope.cn/models/<namespace>/<repo-name>`
* **数据集仓库 URL 结构**：`https://modelscope.cn/datasets/<namespace>/<repo-name>`

> **关键避坑点**：  
> 官方 CLI 工具 `modelscope upload` 默认推送目标是 `model`。若在网页端创建的是 **数据集 (Dataset)**，任何 CLI 命令都必须显式声明 `--repo-type dataset`，否则文件会被推送到系统隐式自动创建的同名模型库中。

---

## 第一部分：获取与配置访问凭证 (Access Token)

无论使用 Git 还是官方 CLI，均需要使用 ModelScope 的 Access Token 进行身份验证。

1. 登录 [ModelScope 官网](https://modelscope.cn/)。
2. 点击右上角头像 -> **个人中心** -> **访问令牌 (Access Token)**。
3. 点击 **新建访问令牌**，权限勾选 **读写 (Read & Write)**，复制生成的 Token 字符串。

---

## 第二部分：推荐方案 —— Git & Git LFS 原生版本管理

Git 方式最透明、直观，版本历史（Commit / Branch / Tag）与 GitHub / GitLab 完全一致，不会受到 CLI 隐藏上传缓存的干扰。

### 1. 环境准备

确保本地已安装 Git 以及 Git LFS（大文件存储扩展）：

```bash
# 检查 git 与 git-lfs 安装情况
git --version
git lfs version

# 全局初始化 Git LFS（仅需执行一次）
git lfs install
```

### 2. 克隆数据集仓库

```bash
# 数据集仓库的标准 Git 克隆地址格式
git clone https://www.modelscope.cn/datasets/<你的用户名>/<仓库名>.git

# 示例：
git clone https://www.modelscope.cn/datasets/scocahh/jigsaw-data.git
cd jigsaw-data
```

> **身份验证提示**：  
> * **Username**: 你的 ModelScope 账户用户名或注册绑定的手机号/邮箱。  
> * **Password**: 填入前面获取的 **Access Token**（切勿填网页登录密码）。

### 3. 配置 Git LFS 追踪大文件

ModelScope 单个常规文件如果超过 50MB 建议使用 LFS，超过 100MB 必须使用 LFS 追踪。

在仓库根目录下运行以下命令追踪 `.zip` 或资源包文件：

```bash
# 追踪常见资源包格式
git lfs track "*.zip"
git lfs track "*.bin"
git lfs track "*.pak"

# 将生成的 .gitattributes 配置文件加入版本控制
git add .gitattributes
git commit -m "chore: track asset binaries with Git LFS"
```

### 4. 日常添加与提交资源

```bash
# 1. 将打包好的 assets 放入仓库目录（如放入 daily/ 目录）
# 2. 查看文件变更与 LFS 追踪状态
git status
git lfs ls-files

# 3. 正常执行 Git 提交
git add .
git commit -m "feat: release daily puzzle assets v1.0.1"

# 4. 推送到远程 master 分支
git push origin master
```

### 5. 版本打标 (Tag / Release)

若要为 App 客户端固定某个资源版本（避免 master 分支更新覆盖线上旧版本客户端），推荐使用 Git Tag：

```bash
# 创建轻量标签或附注标签
git tag -a v1.0.1 -m "Game assets for app version 1.0.1"

# 推送标签至 ModelScope 远程
git push origin v1.0.1
```

---

## 第三部分：官方 CLI 快速上传方案

如果需要将打包产物直接集成到 Python 自动化构建流水线中，可使用 `modelscope` 命令行工具。

### 1. 安装与登录

```bash
pip install --upgrade modelscope

# 配置本地登录凭证（会保存凭证至 ~/.modelscope/credentials）
modelscope login --token YOUR_ACCESS_TOKEN
```

### 2. 核心命令规范（重点注意 `--repo-type`）

#### 场景 A：上传单个文件到数据集根目录

```bash
modelscope upload <用户名>/<仓库名> ./daily/puzzle_20260907.zip \
    --repo-type dataset \
    --revision master
```

#### 场景 B：上传整个文件夹到数据集指定子目录

```bash
# 将本地 daily/ 下的内容上传到远端仓库的 daily/ 路径下
modelscope upload <用户名>/<仓库名> ./daily/ \
    --repo-type dataset \
    --revision master \
    --destination daily
```

### 3. 常用关键参数解析

| 参数 | 缩写 | 默认值 | 详细说明 |
| :--- | :--- | :--- | :--- |
| `--repo-type` | `-r` | `model` | **必填**。必须显式设为 `dataset`，否则会静默推送到模型库。 |
| `--revision` | `-b` | `master` | 目标分支或 Tag 名称。建议始终显式写明 `master`。 |
| `--destination` | `-d` | `/` (根目录) | 上传到远端仓库的相对路径。留空则直接平铺在根目录。 |

### 4. 解决本地上传缓存锁死问题 (Skipped Cached)

`modelscope upload` 会在本地生成一个隐藏的进度追踪缓存。如果上次上传意外中断、或误推到了别的分支，再次上传时可能会触发：  
`Scan complete: X total, X committed (skip), 0 to process.`

**清理方法**：
* Windows PowerShell:
  ```powershell
  Remove-Item -Path ".\.modelscope" -Recurse -Force -ErrorAction SilentlyContinue
  ```
* Linux / macOS:
  ```bash
  rm -rf ./.modelscope
  ```
清理后重新执行 `upload` 命令即可强制全量扫描并重新推送。

---

## 第四部分：客户端（游戏 App）直链下载规范

文件成功推送到公开数据集后，无需网页端授权，客户端可直接通过标准 HTTP/HTTPS GET 请求进行断点续传下载。

### 1. 下载直链 URL 构造规则

公开数据集的基础下载 URL 结构如下：

```
https://www.modelscope.cn/datasets/<用户名>/<仓库名>/resolve/<分支或Tag>/<文件相对路径>
```

#### 示例对照：

* **按 master 最新分支下载**：
  ```
  https://www.modelscope.cn/datasets/scocahh/jigsaw-data/resolve/master/daily/20260907.zip
  ```
* **按特定 Git Tag 版本下载（线上生产推荐，保障版本不可篡改）**：
  ```
  https://www.modelscope.cn/datasets/scocahh/jigsaw-data/resolve/v1.0.1/daily/20260907.zip
  ```

### 2. 客户端下载的最佳实践

1. **配置 CDN 缓存绕过/校验**：由于 ModelScope 边缘节点可能缓存文件内容，若通过 `master` 分支热更新同名文件，App 请求头中建议带上版本指纹或在客户端进行 MD5/SHA256 校验。
2. **支持 Range 请求**：ModelScope 的底层对象存储支持标准 HTTP `Range` 头，App 客户端下载引擎（如 UnityWebRequest、Dio、OkHttp）可直接启用多线程分段与断点续传。
3. **私有仓库鉴权（如需要）**：
   若将数据集设为了 Private，请求该直链时必须在 HTTP Header 中附带鉴权凭证：
   ```http
   Authorization: Bearer <YOUR_ACCESS_TOKEN>
   ```
