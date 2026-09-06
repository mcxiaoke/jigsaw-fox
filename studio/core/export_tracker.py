#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.core.export_tracker — 图片导出/已使用状态账本管理器 (exported.json)
以源目录 (Source Directory) 为基准，以 SHA-256 内容哈希为主键记录已导出图片，
防止跨包、跨批次重复使用素材，即使图片改名或移动也能精准识别。
"""

from __future__ import annotations

import datetime as dt
import json
from pathlib import Path
from typing import Any

from studio.core.exports_ledger import ExportsLedger
from studio.core.workspace import StudioWorkspace

EXPORTED_FILENAME = "exported.json"


def get_exported_file(src_dir: Path | str) -> Path:
    return Path(src_dir).resolve() / EXPORTED_FILENAME


def create_empty_ledger() -> dict[str, Any]:
    return {
        "version": "1.0.0",
        "updated_at": "",
        "total_exported": 0,
        "hashes": {},
        "path_to_hash": {},
    }


def load_exported_ledger(src_dir: Path | str) -> dict[str, Any]:
    """读取导出账本。优先从唯一权威账本 .studio/ledger/exports.json 构建；若不存在则回退读取 legacy exported.json。"""
    # 优先从 .studio/ledger/exports.json 读取 (唯一权威账本)
    ledger_mgr = ExportsLedger(src_dir)
    if ledger_mgr.records:
        legacy = create_empty_ledger()
        legacy["version"] = "2.0.0"
        legacy["updated_at"] = ledger_mgr.updated_at
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
        legacy["hashes"] = hashes_map
        legacy["path_to_hash"] = path_map
        legacy["total_exported"] = len(hashes_map)
        return legacy

    # 回退到旧版 exported.json (仅作为历史兼容)
    p = get_exported_file(src_dir)
    if p.exists() and p.is_file():
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                if "hashes" not in data or not isinstance(data["hashes"], dict):
                    data["hashes"] = {}
                if "path_to_hash" not in data or not isinstance(data["path_to_hash"], dict):
                    data["path_to_hash"] = {}
                data["total_exported"] = len(data["hashes"])
                return data
        except Exception:
            pass

    return create_empty_ledger()


def save_exported_ledger(src_dir: Path | str, ledger: dict[str, Any]) -> tuple[bool, str]:
    """原子保存 exported.json，防止并发或断电写损坏。"""
    target = get_exported_file(src_dir)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp_file = target.with_name(f"{target.name}.tmp")

    ledger["updated_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
    ledger["total_exported"] = len(ledger.get("hashes", {}))

    try:
        content = json.dumps(ledger, ensure_ascii=False, indent=2)
        tmp_file.write_text(content, encoding="utf-8")
        tmp_file.replace(target)
        return True, str(target)
    except Exception as e:
        tmp_file.unlink(missing_ok=True)
        return False, str(e)


def record_exports(src_dir: Path | str, items: list[dict[str, Any]]) -> tuple[dict[str, Any], int]:
    """
    记录一批新导出的图片至 exported.json 账本中，并同步写入 .studio/ledger/exports.json。
    每项需包含: hash, path, export_type, target 等元数据。
    返回: (最新 ledger, 新增记录数)
    """
    ledger = load_exported_ledger(src_dir)
    hashes_map: dict[str, Any] = ledger.setdefault("hashes", {})
    path_map: dict[str, str] = ledger.setdefault("path_to_hash", {})

    new_count = 0
    now_iso = dt.datetime.now(dt.timezone.utc).isoformat()
    v2_records: list[dict[str, Any]] = []

    for it in items:
        h = (it.get("hash") or it.get("sourceHash") or "").strip().lower()
        rel_path = (it.get("path") or it.get("sourcePath") or "").replace("\\", "/").strip()
        if not h:
            continue

        is_new = h not in hashes_map
        if is_new:
            new_count += 1

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

        rec = {
            "hash": h,
            "path": rel_path,
            "file_name": it.get("file_name") or Path(rel_path).name,
            "file_size": it.get("file_size") or it.get("sourceSize") or 0,
            "export_type": exp_type,
            "target": it.get("target") or it.get("targetFile") or "",
            "order": order,
            "month": month,
            "event_id": event_id,
            "collection_id": col_id,
            "exported_at": it.get("exported_at") or it.get("exportedAt") or now_iso,
        }
        # 移除 None 值键
        clean_rec = {k: v for k, v in rec.items() if v is not None}
        hashes_map[h] = clean_rec
        if rel_path:
            path_map[rel_path] = h

        v2_records.append({
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
            "exportedAt": clean_rec.get("exported_at") or now_iso,
        })

    # 同步写入新规范权威账本
    try:
        ledger_mgr = ExportsLedger(src_dir)
        ledger_mgr.append_records(v2_records)
    except Exception:
        pass

    ledger["total_exported"] = len(hashes_map)
    ledger["updated_at"] = now_iso

    # 仅在 legacy exported.json 已存在于磁盘时同步更新，不再自发创建
    p = get_exported_file(src_dir)
    if p.exists() and p.is_file():
        save_exported_ledger(src_dir, ledger)
    return ledger, new_count


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

