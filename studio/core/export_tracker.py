#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.core.export_tracker — 导出账本只读视图适配层

唯一事实源：.studio/ledger/exports.json（见 studio.core.exports_ledger.ExportsLedger）。
本模块只做一件事：把权威账本的记录集投影成旧版 dict 视图
（hashes / path_to_hash / total_exported），供 HTTP 层与历史调用方消费。

旧版 exported.json 兼容层已整体移除：不再读取、不再写入、不再迁移。
"""

from __future__ import annotations

import datetime as dt
from pathlib import Path
from typing import Any

from studio.core.exports_ledger import ExportsLedger

# 视图结构版本号（仅标识本模块返回的 dict 形状，与磁盘账本 schemaVersion 无关）
LEDGER_VIEW_VERSION = "2.0.0"


def create_empty_ledger() -> dict[str, Any]:
    return {
        "version": LEDGER_VIEW_VERSION,
        "updated_at": "",
        "total_exported": 0,
        "hashes": {},
        "path_to_hash": {},
    }


def load_exported_ledger(src_dir: Path | str) -> dict[str, Any]:
    """读取导出账本视图。

    唯一数据来源为 .studio/ledger/exports.json；该账本不存在时返回空视图，
    不再回退到任何旧版文件。
    """
    ledger_mgr = ExportsLedger(src_dir)

    view = create_empty_ledger()
    if not ledger_mgr.records:
        return view

    view["updated_at"] = ledger_mgr.updated_at
    hashes_map: dict[str, Any] = {}
    path_map: dict[str, str] = {}

    for r in ledger_mgr.records:
        h = (r.get("sourceHash") or "").strip().lower()
        rel_path = (r.get("sourcePath") or "").replace("\\", "/")
        item_view = {
            "hash": h,
            "path": rel_path,
            "file_name": Path(rel_path).name,
            "file_size": r.get("sourceSize", 0),
            "export_type": r.get("module", "main"),
            "target": r.get("targetFile", ""),
            "order": r.get("order"),
            "exported_at": r.get("exportedAt", ""),
            "logicalId": r.get("logicalId"),
            "recordId": r.get("recordId"),
        }
        if h:
            hashes_map[h] = item_view
        if rel_path and h:
            path_map[rel_path] = h

    view["hashes"] = hashes_map
    view["path_to_hash"] = path_map
    view["total_exported"] = len(hashes_map)
    return view


def record_exports(
    src_dir: Path | str, items: list[dict[str, Any]]
) -> tuple[dict[str, Any], int]:
    """
    记录一批新导出的图片至唯一权威账本 .studio/ledger/exports.json。

    每项需包含: hash, path, export_type, target 等元数据。
    返回: (最新账本视图, 新增记录数)

    写入失败会直接向上传播异常——绝不静默吞掉，否则账本与实际交付状态会分叉。
    """
    ledger_mgr = ExportsLedger(src_dir)
    existing = ledger_mgr.get_exported_hashes()
    seen: set[str] = set()

    new_count = 0
    now_iso = dt.datetime.now(dt.timezone.utc).isoformat()
    v2_records: list[dict[str, Any]] = []

    for it in items:
        h = (it.get("hash") or it.get("sourceHash") or "").strip().lower()
        rel_path = (it.get("path") or it.get("sourcePath") or "").replace("\\", "/").strip()
        if not h:
            continue

        if h not in existing and h not in seen:
            new_count += 1
        seen.add(h)

        exp_type = it.get("export_type") or it.get("module") or "main"
        order = it.get("order")
        month = it.get("month")
        event_id = it.get("event_id")
        col_id = it.get("collection_id")

        if exp_type == "main" and order:
            logical_id = f"main:{order}"
        elif exp_type == "daily" and month:
            logical_id = f"daily:{month}"
        elif exp_type == "event" and event_id:
            logical_id = f"event:{event_id}"
        elif exp_type == "collection" and col_id:
            logical_id = f"collection:{col_id}"
        else:
            logical_id = it.get("logicalId") or f"{exp_type}:{Path(rel_path).stem}"

        v2_records.append(
            {
                "sourceHash": h,
                "sourcePath": rel_path,
                "sourceSize": it.get("file_size") or it.get("sourceSize") or 0,
                "module": exp_type,
                "logicalId": logical_id,
                "order": order,
                "batchId": it.get("batchId"),
                "targetFile": it.get("target") or it.get("targetFile") or "",
                "targetHash": it.get("targetHash") or "",
                "revision": int(it.get("revision") or 1),
                "supersedes": it.get("supersedes"),
                "cropInfo": it.get("cropInfo"),
                "exportedAt": it.get("exported_at") or it.get("exportedAt") or now_iso,
            }
        )

    if v2_records:
        ledger_mgr.append_records(v2_records)

    return load_exported_ledger(src_dir), new_count


def get_exported_hashes(src_dir: Path | str) -> set[str]:
    """获取所有已导出图片的 SHA-256 集合。"""
    ledger = load_exported_ledger(src_dir)
    return set(ledger.get("hashes", {}).keys())


def get_exported_map(src_dir: Path | str) -> dict[str, dict[str, Any]]:
    """
    获取相对路径到已导出详情的字典映射（支持 Hash 反查兜底）。
    返回: { rel_path: export_info }
    """
    ledger = load_exported_ledger(src_dir)
    hashes = ledger.get("hashes", {})
    path_to_hash = ledger.get("path_to_hash", {})

    res: dict[str, dict[str, Any]] = {}
    for p, h in path_to_hash.items():
        if h in hashes:
            res[p] = hashes[h]

    # 同时将每个 hash 记录的最新 path 也放入字典
    for h, info in hashes.items():
        p = info.get("path")
        if p and p not in res:
            res[p] = info

    return res
