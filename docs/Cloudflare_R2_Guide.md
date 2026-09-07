# Cloudflare R2 资源分发与自动化上传实战指南

本指南专为独立开发者与移动端 App 资源分发设计。Cloudflare R2 兼容标准 AWS S3 API，提供免费的 10GB 存储空间、每月千万级 API 操作额度，且**下行出站流量完全免费（Zero Egress Fees）**，是海外及免备案分发静态资源（Assets/Zip）的理想选择。

---

## 核心架构与免备案访问说明

* **存储层**：Cloudflare R2 Bucket。
* **访问层**：
  * **公开 R2 开发域名 (`*.r2.dev`)**：开箱即用，无需拥有域名，但 Cloudflare 会施加基础限速/并发限制，建议仅用于测试。
  * **绑定自定义域名 (推荐生产使用)**：将你托管在 Cloudflare 上的域名（如 `assets.yourdomain.com`）直接绑定至 Bucket，享受全球 Anycast CDN 边缘缓存加速，**无需工信部 ICP 备案**。

---

## 第一部分：创建存储桶与配置公开访问

### 1. 创建 Bucket
1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/)。
2. 侧边栏进入 **R2** -> 点击 **Create bucket**。
3. 填写存储桶名称（例如 `jigsaw-data`），位置建议选择 **Automatic**（根据访问自动优化）或按主要受众选择亚太地区。

### 2. 配置公开直链访问（二选一）

#### 方案 A：快速测试（启用 r2.dev 公开访问）
1. 进入该 Bucket -> 点击 **Settings** 选项卡。
2. 找到 **Public access** 区域 -> 点击 **Allow Access** 打开 `R2.dev subdomain`。
3. 系统将分配一个形如 `https://pub-xxxxxxxxxxxxxx.r2.dev` 的公共地址。

#### 方案 B：生产环境（绑定自定义二级域名）
1. 在 **Settings** -> **Public access** -> 点击 **Custom Domains** -> **Connect Domain**。
2. 输入你希望绑定的子域名，例如 `assets.yourdomain.com`（该域名必须已在 Cloudflare 解析）。
3. 点击 **Continue** 并确认 DNS 记录自动创建。完成绑定后，即可通过 `https://assets.yourdomain.com/<文件路径>` 直连下载。

---

## 第二部分：获取 S3 API 凭证 (Token)

若要通过命令行（CLI）、脚本或 CI/CD 自动上传文件，需要生成一组 S3 兼容密钥。

1. 返回 **R2 Overview** 页面（Bucket 列表外层）。
2. 在右侧栏点击 **Manage R2 API Tokens** -> 点击 **Create API token**。
3. 配置权限：
   * **Permissions**：选择 **Object Read & Write**。
   * **Apply to specific buckets**：可仅限定针对 `jigsaw-data`，或选所有 Bucket。
   * **TTL**：如长期使用，设为 Forever 或较长年限。
4. 保存后系统会展示凭证页面（**仅显示一次，请立即保存**）：
   * **Access Key ID**
   * **Secret Access Key**
   * **Jurisdiction-specific Endpoint / S3 Endpoint**：形如 `https://<account_id>.r2.cloudflarestorage.com`

---

## 第三部分：自动化上传工具与工作流

R2 完全兼容 S3 协议，因此有多种轻量级命令行工具可供选择。

### 方案 1：使用 rclone（强烈推荐，适合本地与服务器同步）

`rclone` 是性能强劲的文件同步命令行工具，支持增量同步、哈希校验与断点续传。

#### 1. 配置 rclone
安装后运行交互配置，或直接编辑配置文件 `~/.config/rclone/rclone.conf`（Windows: `%USERPROFILE%/.config/rclone/rclone.conf`）：

```ini
[r2]
type = s3
provider = Cloudflare
access_key_id = <你的_ACCESS_KEY_ID>
secret_access_key = <你的_SECRET_ACCESS_KEY>
endpoint = https://<account_id>.r2.cloudflarestorage.com
acl = private
```

#### 2. 常用上传命令

```bash
# 1. 复制单个文件到指定路径
rclone copy ./daily/20260907.zip r2:jigsaw-data/daily/

# 2. 增量同步整个目录（只上传新文件或有改动的文件）
rclone copy ./daily/ r2:jigsaw-data/daily/ --progress

# 3. 查看远端文件列表
rclone lsf r2:jigsaw-data/daily/
```

---

### 方案 2：使用官方 Wrangler CLI（适合无需配置 S3 秘钥的 Node.js 开发者）

```bash
# 全局或局部安装 wrangler
npm install -g wrangler

# 登录 Cloudflare 账户（浏览器授权）
wrangler login

# 直接上传单个对象
wrangler r2 object put jigsaw-data/daily/20260907.zip --file=./daily/20260907.zip
```

---

### 方案 3：使用 Python 脚本自动打包并上传 (boto3)

如果你的构建流程是 Python 脚本，可以直接内嵌上传代码：

```python
import boto3
from botocore.config import Config

s3 = boto3.client(
    service_name='s3',
    endpoint_url='https://<account_id>.r2.cloudflarestorage.com',
    aws_access_key_id='<你的_ACCESS_KEY_ID>',
    aws_secret_access_key='<你的_SECRET_ACCESS_KEY>',
    region_name='auto',
    config=Config(s3={'addressing_style': 'path'})
)

# 上传本地 zip 包到指定 key
s3.upload_file(
    Filename='./daily/20260907.zip',
    Bucket='jigsaw-data',
    Key='daily/20260907.zip',
    ExtraArgs={'ContentType': 'application/zip'}
)
print("Upload completed successfully.")
```

---

## 第四部分：客户端（游戏 App）下载规范与缓存优化

### 1. 直链 URL 构造
将资源上传至 `daily/20260907.zip` 后，客户端发起的 HTTP GET 请求格式为：

* **自定义域名方式（推荐）**：
  ```
  https://assets.yourdomain.com/daily/20260907.zip
  ```
* **R2 开发域名方式**：
  ```
  https://pub-xxxxxxxxxxxxxx.r2.dev/daily/20260907.zip
  ```

### 2. CDN 边缘缓存配置策略
由于 Cloudflare CDN 默认会对静态文件进行边缘节点缓存：
1. **热更新相同文件名**：如果更新了资源包但保持文件名不变，CDN 节点可能返回旧版本。
   * **解决对策 A（推荐）**：每次打包采用版本化命名或时间戳命名（如 `daily_v1.0.1.zip`、`data_20260907.zip`）。
   * **解决对策 B**：在 Cloudflare Dashboard -> **Caching** -> **Purge Cache** 中手动刷新该 URL 的单页缓存。
2. **断点续传支持**：Cloudflare R2 与 CDN 默认完美支持 HTTP `Range` 头，移动端下载引擎可直接进行多线程分块下载和中断重连。
