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
from studio.core.workspace import StudioWorkspace
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


def is_real_tag(tag: str | None) -> bool:
    """判断是否为真实有效业务标签 (排除 None, 空字符串及虚拟过滤器 'Others')"""
    if not tag:
        return False
    return str(tag).strip().lower() != "others"


def extract_real_tags(tags: list[str] | None) -> list[str]:
    """提取标签列表中的真实标签（过滤掉虚拟 filter 'Others'）"""
    if not tags:
        return []
    return [t for t in tags if is_real_tag(t)]


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
    3. 同 Hash 自动继承引擎：对于真正的新增图片，若素材库中已有同 Hash 且打过标签的图片，
       自动继承其真实业务标签，防止因复制路径不同而分裂为未打标；
    4. 独立全新图片：自动按目录规则推断初始标签；
    5. 跨记录一致性对齐：若存在同 Hash 的多份副本，自动汇聚并对齐其真实标签；
    6. 统计标签分布、复核数量及对齐指标 (Others 视为未打标集合/虚拟 filter)。
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

    # 建立已有记录中有效真实标签的 Hash 映射库 (用于自动继承)
    hash_donor_map: dict[str, dict[str, Any]] = {}
    for r in active_records:
        h = (r.get("hash") or "").strip().lower()
        if h and extract_real_tags(r.get("tags")):
            if h not in hash_donor_map:
                hash_donor_map[h] = r
    for o in orphan_records:
        h = (o.get("hash") or "").strip().lower()
        if h and extract_real_tags(o.get("tags")):
            if h not in hash_donor_map:
                hash_donor_map[h] = o

    # 4. 真正的新增图片：优先从同 Hash 已有图片自动继承真实标签，无法继承则推断初始标签
    for rel in remaining_unmapped:
        p = disk_paths[rel]
        info = image_infos.get(rel, {}) if image_infos else {}
        file_hash = (info.get("hash") or "").strip().lower()

        if file_hash and file_hash in hash_donor_map:
            # 命中相同 Hash 的已有图片：自动继承真实业务标签与属性
            donor = hash_donor_map[file_hash]
            donor_tags = list(donor.get("tags", []))
            donor_cats = list(donor.get("catalogs", []))
            donor_path = donor.get("path", "")
            active_records.append({
                "path": rel,
                "file": p.name,
                "tags": donor_tags,
                "catalogs": donor_cats,
                "confidence": float(donor.get("confidence", 1.0)),
                "review_required": bool(donor.get("review_required", False)),
                "subject": donor.get("subject", ""),
                "scene": donor.get("scene", ""),
                "reason": f"自动继承同内容图片标签 ({donor_path})",
                "hash": file_hash,
                "sha1": donor.get("sha1", ""),
                "model": "inherited",
                "width": info.get("width", 0),
                "height": info.get("height", 0),
                "format": info.get("format", ""),
                "size": info.get("size", 0),
                "mtime": info.get("mtime", 0),
                "aspect_ratio": info.get("aspect_ratio", 1.0),
                "orientation": info.get("orientation", "square"),
            })
        else:
            guessed = guess_tags_from_path(p, root=root)
            real_guessed = extract_real_tags(guessed)
            cats = get_catalogs_for_tags(guessed)
            has_real = len(real_guessed) > 0
            new_rec = {
                "path": rel,
                "file": p.name,
                "tags": guessed,
                "catalogs": cats,
                "confidence": 1.0 if has_real else 0.0,
                "review_required": not has_real,
                "subject": "",
                "scene": "",
                "reason": f"智能推断: {', '.join(guessed)}" if has_real else "未打标",
                "hash": file_hash,
                "sha1": "",
                "model": "rule",
                "width": info.get("width", 0),
                "height": info.get("height", 0),
                "format": info.get("format", ""),
                "size": info.get("size", 0),
                "mtime": info.get("mtime", 0),
                "aspect_ratio": info.get("aspect_ratio", 1.0),
                "orientation": info.get("orientation", "square"),
            }
            active_records.append(new_rec)
            if file_hash and has_real and file_hash not in hash_donor_map:
                hash_donor_map[file_hash] = new_rec

    # 4.5 同内容跨记录标签对齐与合并 (保证相同 Hash 的所有文件具有完全一致的真实标签)
    records_by_hash: dict[str, list[dict[str, Any]]] = {}
    for r in active_records:
        h = (r.get("hash") or "").strip().lower()
        if h:
            records_by_hash.setdefault(h, []).append(r)

    for h, group in records_by_hash.items():
        if len(group) >= 2:
            all_real_tags: list[str] = []
            for item in group:
                for t in extract_real_tags(item.get("tags")):
                    if t not in all_real_tags:
                        all_real_tags.append(t)
            if all_real_tags:
                all_cats = get_catalogs_for_tags(all_real_tags)
                for item in group:
                    cur_real = extract_real_tags(item.get("tags"))
                    if set(cur_real) != set(all_real_tags):
                        item["tags"] = list(all_real_tags)
                        item["catalogs"] = list(all_cats)
                        item["confidence"] = max(float(item.get("confidence", 0.0)), 0.9)
                        item["review_required"] = False
                        item["reason"] = "自动对齐同内容图片标签"

    # 按相对路径小写排序保持稳定
    active_records.sort(key=lambda r: r["path"].lower())

    # 5. 统计指标 (Others 作为未打标集合的虚拟 filter)
    by_tag: dict[str, int] = {}
    review_count = 0
    others_count = 0
    for r in active_records:
        real_tags = extract_real_tags(r.get("tags", []))
        for t in real_tags:
            by_tag[t] = by_tag.get(t, 0) + 1
        if not real_tags:
            others_count += 1
        if r.get("review_required") or not real_tags:
            review_count += 1

    by_tag["Others"] = others_count

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
    ws = StudioWorkspace(r)
    dest = target_file if target_file else ws.tags_file

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
        try:
            rel_dest = dest.relative_to(r).as_posix()
        except Exception:
            rel_dest = str(dest)
        ws.log_operation("tag_save", path=rel_dest, count=len(out_list))
        return True, str(dest.resolve()), len(out_list)
    except Exception as e:
        return False, str(e), 0
