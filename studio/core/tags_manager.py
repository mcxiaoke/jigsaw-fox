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

        records.append({
            "path": rel,
            "file": Path(rel).name,
            "tags": tags,
            "catalogs": cats,
            "confidence": conf,
            "review_required": review,
            "subject": item.get("subject", ""),
            "scene": item.get("scene", ""),
            "reason": item.get("reason", ""),
            "sha1": item.get("sha1", ""),
            "model": item.get("model", ""),
        })

    return records, format_name


def merge_scanned_images(
    images: list[Path],
    root: Path,
    existing_records: list[dict[str, Any]] | None,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """
    将扫描到的实际图片与现有 records 进行对齐：
    - 已存在的图片保留打标结果；
    - 新增的图片自动按目录规则推断初始标签；
    - 统计标签分布与待复核数量。
    """
    records: list[dict[str, Any]] = list(existing_records) if existing_records else []
    known_paths = {r["path"].replace("\\", "/") for r in records}

    for p in images:
        rel = p.relative_to(root).as_posix().replace("\\", "/")
        if rel not in known_paths:
            guessed = guess_tags_from_path(p, root=root)
            cats = get_catalogs_for_tags(guessed)
            is_others = any(t.lower() == "others" for t in guessed)
            records.append({
                "path": rel,
                "file": p.name,
                "tags": guessed,
                "catalogs": cats,
                "confidence": 1.0 if not is_others else 0.0,
                "review_required": is_others,
                "subject": "",
                "scene": "",
                "reason": f"智能推断: {', '.join(guessed)}" if not is_others else "未打标",
                "sha1": "",
                "model": "rule",
            })
            known_paths.add(rel)

    # 统计指标
    by_tag: dict[str, int] = {}
    review_count = 0
    for r in records:
        for t in r.get("tags", []):
            by_tag[t] = by_tag.get(t, 0) + 1
        if r.get("review_required") or any(t.lower() == "others" for t in r.get("tags", [])):
            review_count += 1

    stats = {
        "byTag": by_tag,
        "reviewCount": review_count,
        "totalImages": len(images),
        "totalRecords": len(records),
    }

    return records, stats


def save_tags_file(root: str | Path, records: list[dict[str, Any]], target_file: Path | None = None) -> tuple[bool, str, int]:
    """
    原子安全保存 tags.json。
    写入 .tmp 文件校验无误后再原子替换，杜绝断电损坏。
    返回: (success: bool, filepath_or_error: str, count: int)
    """
    r = Path(root).resolve()
    dest = target_file if target_file else (r / "tags.json")

    # 保留原有的 sha1 映射
    sha_map: dict[str, str] = {}
    if dest.exists():
        try:
            old_raw = json.loads(dest.read_text(encoding="utf-8"))
            if isinstance(old_raw, list):
                for item in old_raw:
                    if isinstance(item, dict) and item.get("path"):
                        sha_map[item["path"]] = item.get("sha1", "")
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

        out_list.append({
            "path": rel,
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
        })

    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp_file = dest.with_suffix(".tmp")
        tmp_file.write_text(json.dumps(out_list, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp_file.replace(dest)
        return True, str(dest.resolve()), len(out_list)
    except Exception as e:
        return False, str(e), 0
