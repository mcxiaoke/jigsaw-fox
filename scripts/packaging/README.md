# Content Studio — 拼图内容打包工具（原型）

> 按需启动的本地工具，用于承接 `scripts/ai_tag_images.py` 的 `tags.json`（21 类单主标签），人工秒级校正后一键导出 `main.json / daily ZIP / events.json`。

## 快速开始

```powershell
# 1. 启动（默认 127.0.0.1:5173）
python scripts/packaging/server.py --open
# 或指定端口
python scripts/packaging/server.py --port 5173 --host 127.0.0.1 --open

# 2. 浏览器打开 http://127.0.0.1:5173
# 源目录填： D:\raw\home_202609
# 输出目录填： X:\www\game\test  或  D:\puzzle\out
# 点「扫描」→ 网格校正 →「保存 tags.json」→「导出 main.json」
```

- 缩略图依赖 `Pillow`（可选）：`pip install Pillow` 后缩略图更快、更省流量；未安装则直出原图。
- 无需 `npm`，单 `index.html + server.py`。

## 目录与数据流

```
[图片源目录]
  ├─ img1.jpg
  ├─ img2.webp
  └─ tags.json   ← 由 scripts/ai_tag_images.py 生成（list[{path,tag,confidence,...}]）
        │
        │  本工具加载 → 人工校正（写入 correctedTag）
        ▼
  tags.json (已校正，仍为 list 格式，兼容 ai 脚本增量)
        │
        ├─► out/main.json + out/main/*.jpg  （供 ContentManager 同步）
        ├─► out/daily/YYYYMM.zip             （零元数据）
        └─► out/events/events.json (+ .zip)
```

`tags.json` 单图仅 1 个主标签（`TAGS_21`），导出时映射为 `levels[].tags: ["Pets"]` 单元素数组，兼容 `lib/logic/content/models/puzzle_level_item.dart:39` 的多标签模型。

## 25→21 变更

已对齐 `docs/jigsaw-image-tagging-specification.md v1.1`：移除 `Travel/Vintage/Cozy/Landmarks`，剩余 21 类：

`Animals / Pets / Nature / Landscapes / Flowers / Ocean / Birds / Cities / Architecture / Food / Art / Fantasy / Space / Transportation / People / Sports / Seasons / Holidays / Abstract / Cartoon / Others`

`confidence<0.75` 或 `Others` 自动标为待复核（`review_required=true`）。

## API（本地回环）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/` | 单页前端 |
| GET | `/api/health` | `{has_pil, tags}` |
| GET | `/api/scan?dir=D:\raw` | 扫描图片 + 读取 `tags.json` |
| GET | `/api/thumb?path=D:\a.jpg&size=360` | 缩略图（Pillow 可选） |
| GET | `/api/file?path=...` | 原图 |
| POST | `/api/tags {dir, records:[{path,tag,correctedTag,confidence}]}` | 原子写回 `tags.json` |
| POST | `/api/export/main {srcDir,outDir,httpBase,version}` | 生成 `main.json` + 复制图片到 `out/main/` |
| POST | `/api/export/daily {srcDir,outDir,month:YYYYMM}` | 生成 `out/daily/YYYYMM.zip` |
| POST | `/api/export/events {outDir,httpBase,events:[...]}` | 生成 `events.json` (+ zip) |

## 常见问题

- **中文路径乱码？** 本工具全程 `utf-8`，`path` 经 `encodeURIComponent` 传输。
- **图片很多很慢？** 首屏懒加载 + 缩略图；`Pillow` 未安装时会传输原图，建议安装。
- **自动打标如何接入？** 先跑 `python scripts/ai_tag_images.py D:\raw --output D:\raw\tags.json`，再用本工具「扫描」自动加载。
