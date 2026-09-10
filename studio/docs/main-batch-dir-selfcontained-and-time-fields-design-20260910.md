# main 批次目录自包含 + 导出时间字段统一（实施方案）

> 日期：2026-09-10
> 状态：已拍板实施（A 增量 / batch id 保持 / 无历史全切）
> 关联：`studio/docs/export-ledger-operations-and-rollback-design-20260909.md`（L1/L1.1 事件+回滚）；本方案为其镜像组织的补充演进。

## 1. 背景与决策

- **main 镜像组织**：现状所有批次的图片混在 `main/images/` 平铺（文件名=order / order-r{rev}），归属信息依赖批次 json 的 `../images/` 相对约定；撤销批次时无法整批物理删除图片，镜像残留孤儿文件。
- **决策**：采用 **批次目录自包含（方案 A）**：`batches/{batchId}/index.json + batches/{batchId}/images/`，一个批次 = 一个自包含单元（与 daily/events/collections 的"一单元=一 zip"心智对齐）。
  - **batch id 保持不动**（`batch_001` 顺序自增）：batchId 是账本/index/客户端补丁顺序的稳定标识，只应"生成一次、永不改变"；时间信息进元数据字段而非目录名（时间戳 id 会破坏幂等重试与账本↔index 匹配）。
  - **无历史批次**：至今全部为数据测试、未发布 → **全量切换，无兼容迁移**。
- **时间字段统一（增量方案 A）**：全导出体系统一 UTC ISO8601（`...Z`，与 ledger `exportedAt`、事件流 `ts` 格式一致）。
  - 新增 `createdAt`（实体首次创建）/ `updatedAt`（最后修改）；
  - main batch json 逐关的 **`addedAt` 键名保留**（客户端 `puzzle_level_item.dart` 正在解析/序列化该键，改名需跨 studio/app 联动，收益不成比例）；
  - ledger record `exportedAt` / 事件流 `ts` 保留，语义等价 createdAt（文档字典定义）。

## 2. 目标目录结构（release 与 outDir 同构）

```
main/
  index.json                    # 模块索引：version + totalCount/maxOrder/updatedAt + items[batch entries]
  batches/
    batch_001/
      index.json                # 批次清单：batchId/version/count/startOrder/endOrder/createdAt/updatedAt
                                #   + items[]（每关 id/order/url/tags/hash/addedAt）
      images/
        0101.webp ...
    batch_002/                  # patch 批次：修订文件 0101-r2.webp 随本批生灭
      index.json
      images/
```

相对引用（客户端 RFC3986 递归解析，已核实 `main_content_pipeline.dart` 218/240 行）：
- 模块 index items[].url = `batches/{batchId}/index.json`（相对 main/index.json）
- 批次清单 items[].url = `images/{file}`（相对本批次 index.json 同目录）

## 3. 时间字段字典（各载体统一约定）

| 载体 | 字段 | 语义 |
|---|---|---|
| 模块 index.json 顶层（main/daily/events/collections） | `updatedAt` | 模块最后一次导出 |
| main 批次 entry（模块 index items[i]） | `createdAt` = `updatedAt` = 本次导出时刻 | 批次创建；当前无修改场景二者相等 |
| main 批次清单 json 顶层 | `createdAt` / `updatedAt`（与 entry 同值） | 同上 |
| main 批次清单 items[i]（关卡） | `addedAt`（保留既有键） | 该关加入本批时刻（= 批次导出时刻） |
| daily month_entry / pack item_entry | `createdAt`（首次导出该月/该 pack）+ `updatedAt`（每次修订） | 重导替换 entry 时**保留旧 createdAt** |
| ledger record | `exportedAt`（保留既有键） | = 该记录（源素材导出）创建时间 |
| 事件流 / 审计日志 | `ts`（保留） | 事件发生时间 |

## 4. 改动清单

| 文件 | 改动 |
|---|---|
| `studio/exporters/main_exporter.py` | 目录拓扑改 `batches/{batchId}/{index.json,images/}`；批次清单 url `images/{file}`、模块 index entry url `batches/{batchId}/index.json`；patch 修订文件入 patch 批目录（随批生灭）；批次清单与 entry 顶层增加 `createdAt`/`updatedAt` |
| `studio/exporters/daily_exporter.py` | month_entry 增加 `createdAt`（=now）；重导同月替换时保留旧 `createdAt` |
| `studio/exporters/pack_exporter_base.py` | item_entry 增加 `createdAt`（=now）；替换 pack 时保留旧 `createdAt` |
| `studio/core/export_rollback.py` | `_cleanup_main_release` 由删除单文件改为 **rmtree 整批次目录**（图片随批物理清理，孤儿消除） |
| `studio/test_studio.py` / `studio/test_rollback.py` / `temp/rollback_e2e/run_e2e.py` | 路径断言改批次目录形式；补 createdAt/updatedAt 断言 |
| `studio/docs/CHANGES-20260910.md` | 顶部记录 |

不改：客户端 lib/（resolveUrl 通用递归解析）、manifest、发布脚本 `scripts/deploy/export_data.py`（只改写 zip 模块 zipUrl，不解析 main 内部 url）、ledger schema、rollback 事件/审计格式。

## 5. 自审结论（对照代码逐项验证）

| 核查点 | 证据 | 结论 |
|---|---|---|
| 图片 url 相对解析基点 | `main_content_pipeline.dart:240` `resolveUrl(batchUrl, rawUrl)`；batch json 相对模块 index（218 行） | ✓ `images/xxx` 同目录相对正确，app 零改动 |
| 批次 json 命名 index.json 是否撞缓存 | `_getLocalImagePath` 本地缓存文件名=order；批次 json 仅内存 fetchJson 不落盘 | ✓ 无冲突 |
| 补丁覆盖顺序 | pipeline 216 行 append-only items 顺序 | ✓ index 移除 entry 语义不变 |
| 发布链 | export_data.py 仅处理 zip 模块 zipUrl + manifest hash | ✓ 无路径假设 |
| exporter 读状态源 | main_exporter 从 release/main/index.json items 恢复，不 glob batches/ | ✓ |
| 撤销清理 | export_rollback rmtree 批次目录 | ✓ 孤儿消除 |
| daily/pack 时间保留 | 替换分支拷贝旧 createdAt | ✓ 首次创建语义成立 |

## 6. 测试与验证计划

- test_studio main/daily/event/collection：断言批次目录结构与 `createdAt`/`updatedAt`；
- test_rollback TestUndoMainRelease：夹具改批次目录形式，撤销断言批次目录整体消失；
- e2e（真实素材）路径断言同步 + 撤销后 `batches/batch_002/` 目录不存在；
- 全量回归 87 项 + e2e ALL PASS；行尾 LF；`py_compile`；
- 变更记入 `studio/docs/CHANGES-20260910.md`；commit 待用户放行。
