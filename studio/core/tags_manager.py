#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.core.tags_manager — tags.json 统一读取、清洗、合并与原子保存
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from studio.core.scanner import find_tags_file
from studio.taxonomy import (
    get_catalogs_for_tags,
    guess_tags_from_path,
    normalize_token,
)


def load_tags_file(path: Path | str) -> tuple[Any, str | None]:
    """读取 tags.json 文件，返回 (raw_data, error_msg)。"""
    p = Path(path)
    if not p.exists() or not p.is_file():
        return None, "File not found"
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
        return data, None
    except Exception as e:
        return None, str(e)


def normalize_records(raw_data: Any, root: Path) -> tuple[list[dict[str, Any]], str]:
    """
    兼容归一化各种 tags.json 格式:
      1. 列表格式: list[{path/file, tags/tag, confidence, ...}]
      2. 字典格式: {"images": [...]} 或 {"records": [...]}
    返回: (标准化 records 列表, 格式名称)
    """
    records: list[dict[str, Any]] = []

    def _extract_tags(item: dict[str, Any], rel_path: str) -> list[str]:
        # 1. tags 数组
        if "tags" in item and isinstance(item["tags"], list) and item["tags"]:
            res: list[str] = []
            for t in item["tags"]:
                canon = normalize_token(str(t)) or str(t).strip().lower()
                if canon and canon not in res:
                    res.append(canon)
            if res:
                return res

        # 2. 单 tag / correctedTag 字符串
        raw_t = (item.get("correctedTag") or item.get("tag") or "").strip()
        if raw_t:
            canon = normalize_token(raw_t) or "Others"
            return [canon]

        # 3. 回退路径推断
        if rel_path:
            return guess_tags_from_path(root / rel_path, root=root)

        return ["Others"]

    raw_items: list[Any] = []
    format_name = "unknown"

    if isinstance(raw_data, list):
        raw_items = raw_data
        format_name = "list"
    elif isinstance(raw_data, dict):
        if "images" in raw_data and isinstance(raw_data["images"], list):
            raw_items = raw_data["images"]
            format_name = "dict-images"
        elif "records" in raw_data and isinstance(raw_data["records"], list):
            raw_items = raw_data["records"]
            format_name = "dict-records"

    for item in raw_items:
        if not isinstance(item, dict):
            continue
        rel = (item.get("path") or item.get("file") or "").replace("\\", "/")
        tags = _extract_tags(item, rel)
        cats = get_catalogs_for_tags(tags)
        conf = float(item.get("confidence", 0) or 0)
        review = bool(item.get("review_required", False)) or (conf < 0.75) or ("others" in tags)

        rec = {
            "path": rel,
            "file": Path(rel).name,
            "tags": tags,
            "catalogs": cats,
            "confidence": conf,
            "review_required": review,
            "subject": item.get("subject", ""),
            "scene": item.get("scene", ""),
            "reason": item.get("reason", ""),
            "hash": item.get("hash") or item.get("sha256", ""),
            "sha1": item.get("sha1", ""),
            "model": item.get("model", ""),
        }
        if item.get("exported"):
            rec["exported"] = item["exported"]
        if item.get("width"):
            rec["width"] = int(item["width"])
        if item.get("height"):
            rec["height"] = int(item["height"])
        if item.get("format"):
            rec["format"] = str(item["format"]).upper()
        if item.get("size"):
            rec["size"] = int(item["size"])
        if item.get("mtime"):
            rec["mtime"] = int(item["mtime"])
        if item.get("aspect_ratio"):
            rec["aspect_ratio"] = float(item["aspect_ratio"])
        elif rec.get("width") and rec.get("height"):
            rec["aspect_ratio"] = round(rec["width"] / rec["height"], 2)

        records.append(rec)

    return records, format_name


def merge_scanned_images(
    images: list[Path],
    root: Path,
    existing_records: list[dict[str, Any]] | None,
    image_infos: dict[str, dict[str, Any]] | None = None,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """
    将扫描到的实际图片与现有 records 进行对齐：
    1. 路径完全匹配的已有图片：保留已有打标结果，补充缺失的元数据和 Hash；
    2. 孤儿记录（磁盘路径已不存在）：若其 Hash 与未认领的新文件 Hash 一致，
       自动判定为改名或移动，无缝更新路径并 100% 完整继承已有 tags 及人工复核成果；
    3. 真正的新增图片：自动按目录规则推断初始标签并注入完整元数据；
    4. 统计标签分布、复核数量及对齐指标。
    """
    existing = list(existing_records) if existing_records else []
    r_root = Path(root).resolve()
    disk_paths = {p.resolve().relative_to(r_root).as_posix().replace("\\", "/"): p for p in images}

    active_records: list[dict[str, Any]] = []
    orphan_records: list[dict[str, Any]] = []

    # 1. 先按磁盘实际存在性分类
    for r in existing:
        rel = r.get("path", "").replace("\\", "/")
        if rel in disk_paths:
            active_records.append(r)
        else:
            orphan_records.append(r)

    # 找出尚未被 active_records 占用的磁盘路径
    occupied_paths = {r["path"].replace("\\", "/") for r in active_records}
    unmapped_rel_paths = [rel for rel in disk_paths if rel not in occupied_paths]

    # 2. 自动认领引擎 (Auto-Reconciliation)：对孤儿记录按 SHA-256 Hash 匹配新路径文件
    orphan_by_hash: dict[str, dict[str, Any]] = {}
    for o in orphan_records:
        h = (o.get("hash") or "").strip().lower()
        if h and h not in orphan_by_hash:
            orphan_by_hash[h] = o

    reconciled_count = 0
    remaining_unmapped: list[str] = []

    for rel in unmapped_rel_paths:
        info = image_infos.get(rel, {}) if image_infos else {}
        file_hash = (info.get("hash") or "").strip().lower()

        if file_hash and file_hash in orphan_by_hash:
            # 命中 Hash 相同：判定文件发生了改名或跨目录移动！
            matched_rec = orphan_by_hash.pop(file_hash)
            matched_rec["path"] = rel
            matched_rec["file"] = Path(rel).name
            for k in ("width", "height", "format", "size", "mtime", "aspect_ratio", "orientation"):
                if info.get(k):
                    matched_rec[k] = info.get(k)
            matched_rec["hash"] = file_hash
            active_records.append(matched_rec)
            reconciled_count += 1
        else:
            remaining_unmapped.append(rel)

    # 3. 回填已有记录中可能缺失的图片元数据与 Hash
    if image_infos:
        for r in active_records:
            rel = r["path"].replace("\\", "/")
            if rel in image_infos:
                info = image_infos[rel]
                if not r.get("hash") and info.get("hash"):
                    r["hash"] = info["hash"]
                for k in ("width", "height", "format", "size", "mtime", "aspect_ratio", "orientation"):
                    if k not in r or not r[k]:
                        r[k] = info.get(k)

    # 4. 真正的新增图片：推断初始标签
    for rel in remaining_unmapped:
        p = disk_paths[rel]
        guessed = guess_tags_from_path(p, root=root)
        cats = get_catalogs_for_tags(guessed)
        is_others = any(t.lower() == "others" for t in guessed)
        info = image_infos.get(rel, {}) if image_infos else {}
        active_records.append({
            "path": rel,
            "file": p.name,
            "tags": guessed,
            "catalogs": cats,
            "confidence": 1.0 if not is_others else 0.0,
            "review_required": is_others,
            "subject": "",
            "scene": "",
            "reason": f"智能推断: {', '.join(guessed)}" if not is_others else "未打标",
            "hash": info.get("hash", ""),
            "sha1": "",
            "model": "rule",
            "width": info.get("width", 0),
            "height": info.get("height", 0),
            "format": info.get("format", ""),
            "size": info.get("size", 0),
            "mtime": info.get("mtime", 0),
            "aspect_ratio": info.get("aspect_ratio", 1.0),
            "orientation": info.get("orientation", "square"),
        })

    # 按相对路径小写排序保持稳定
    active_records.sort(key=lambda r: r["path"].lower())

    # 5. 统计指标
    by_tag: dict[str, int] = {}
    review_count = 0
    for r in active_records:
        for t in r.get("tags", []):
            by_tag[t] = by_tag.get(t, 0) + 1
        if r.get("review_required") or any(t.lower() == "others" for t in r.get("tags", [])):
            review_count += 1

    stats = {
        "byTag": by_tag,
        "reviewCount": review_count,
        "totalImages": len(images),
        "totalRecords": len(active_records),
        "reconciledCount": reconciled_count,
    }

    return active_records, stats


def save_tags_file(root: str | Path, records: list[dict[str, Any]], target_file: Path | None = None) -> tuple[bool, str, int]:
    """
    原子安全保存 tags.json。
    写入 .tmp 文件校验无误后再原子替换，杜绝断电损坏。
    返回: (success: bool, filepath_or_error: str, count: int)
    """
    r = Path(root).resolve()
    dest = target_file if target_file else (r / "tags.json")

    # 保留原有的 sha1 和 hash 映射
    hash_map: dict[str, str] = {}
    sha_map: dict[str, str] = {}
    if dest.exists():
        try:
            old_raw = json.loads(dest.read_text(encoding="utf-8"))
            if isinstance(old_raw, list):
                for item in old_raw:
                    if isinstance(item, dict) and item.get("path"):
                        pk = item["path"]
                        if item.get("hash"):
                            hash_map[pk] = item["hash"]
                        if item.get("sha1"):
                            sha_map[pk] = item["sha1"]
        except Exception:
            pass

    out_list: list[dict[str, Any]] = []
    for item in records:
        if not isinstance(item, dict):
            continue
        rel = (item.get("path") or item.get("file") or "").replace("\\", "/")
        if not rel:
            continue

        tags_raw = item.get("tags") or []
        tags_norm: list[str] = []
        for t in tags_raw:
            canon = normalize_token(str(t)) or str(t).strip().lower()
            if canon and canon not in tags_norm:
                tags_norm.append(canon)

        if not tags_norm:
            tags_norm = ["Others"]

        cats = get_catalogs_for_tags(tags_norm)
        conf = float(item.get("confidence", 0.8) or 0.8)
        review = bool(item.get("review_required", False)) or (conf < 0.75) or any(t.lower() == "others" for t in tags_norm)

        out_item = {
            "path": rel,
            "hash": item.get("hash") or hash_map.get(rel, ""),
            "sha1": item.get("sha1") or sha_map.get(rel, ""),
            "tags": tags_norm,
            "catalogs": cats,
            "confidence": conf,
            "subject": item.get("subject", ""),
            "scene": item.get("scene", ""),
            "reason": item.get("reason", ""),
            "review_required": review,
            "model": item.get("model", "manual"),
            "taxonomy_version": "jigsaw-tag-v3.0-14",
        }
        if item.get("width"):
            out_item["width"] = int(item["width"])
        if item.get("height"):
            out_item["height"] = int(item["height"])
        if item.get("format"):
            out_item["format"] = str(item["format"]).upper()
        if item.get("size"):
            out_item["size"] = int(item["size"])
        if item.get("mtime"):
            out_item["mtime"] = int(item["mtime"])
        if item.get("aspect_ratio"):
            out_item["aspect_ratio"] = float(item["aspect_ratio"])

        out_list.append(out_item)

    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp_file = dest.with_suffix(".tmp")
        tmp_file.write_text(json.dumps(out_list, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp_file.replace(dest)
        return True, str(dest.resolve()), len(out_list)
    except Exception as e:
        return False, str(e), 0
