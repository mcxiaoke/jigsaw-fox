#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.core.tags_manager — tags.json 统一读取、清洗、合并与原子保存
"""

from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path
from typing import Any
import logging

logger = logging.getLogger(__name__)

from studio.core.scanner import find_tags_file
from studio.core.workspace import StudioWorkspace
from studio.taxonomy import (
    OTHERS_TAG,
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
        logger.warning("[tags] 读取 tags.json 失败: %s (%s)", p, e)
        return None, str(e)


# tags.json 增量(Delta)格式标志，见 docs/tags-delta-store-design-20260909.md
DELTA_SCHEMA = "jigsaw-tags-delta-v1"

# merge_scanned_images 会给记录自动写入的 reason 前缀——切勿当作人工备注落盘
_AUTO_REASON_PREFIXES = ("智能推断", "未打标", "自动继承", "自动对齐")


def _is_auto_reason(reason: Any) -> bool:
    """判断 reason 是否为引擎自动生成(未打标/智能推断/继承/对齐)，而非人工备注。"""
    r = str(reason or "").strip()
    if not r:
        return True
    return any(r.startswith(p) for p in _AUTO_REASON_PREFIXES)


def _is_delta_format(raw_data: Any) -> bool:
    """判断是否为手动增量(delta)格式：顶层带 $schema 标记，或 records/items 含 manual_tags。"""
    if isinstance(raw_data, dict):
        if str(raw_data.get("$schema") or raw_data.get("_schema") or "").startswith("jigsaw-tags-delta"):
            return True
        items = raw_data.get("records") or raw_data.get("images") or []
        if isinstance(items, list) and items and isinstance(items[0], dict):
            return "manual_tags" in items[0]
        return False
    if isinstance(raw_data, list):
        return bool(raw_data) and isinstance(raw_data[0], dict) and "manual_tags" in raw_data[0]
    return False


def _records_from_delta(raw_data: Any, root: Path) -> list[dict[str, Any]]:
    """
    解析手动增量(delta)格式 tags.json。
    每条 delta 的 manual_tags 即该记录的最终有效标签（整体覆盖目录名自动基准），
    直接还原为带完整 tags 的标准记录，供 merge/消费方使用。
    """
    if isinstance(raw_data, dict):
        items = raw_data.get("records") or raw_data.get("images") or []
    elif isinstance(raw_data, list):
        items = raw_data
    else:
        items = []

    records: list[dict[str, Any]] = []
    for it in items:
        if not isinstance(it, dict):
            continue
        rel = (it.get("path") or it.get("file") or "").replace("\\", "/")
        if not rel:
            continue
        tags: list[str] = []
        for t in it.get("manual_tags") or []:
            canon = normalize_token(str(t)) or str(t).strip().lower()
            if canon and canon not in tags:
                tags.append(canon)
        tags = tags or ["Others"]
        rec = {
            "path": rel,
            "file": Path(rel).name,
            "tags": tags,
            "catalogs": get_catalogs_for_tags(tags),
            "confidence": float(it.get("confidence", 0.9) or 0.9),
            "review_required": bool(it.get("review_required", False)) or (tags == ["Others"]),
            "subject": it.get("subject", "") or "",
            "scene": it.get("scene", "") or "",
            "reason": it.get("reason", "") or "",
            "hash": it.get("hash") or "",
            "sha1": it.get("sha1") or "",
            "model": it.get("model") or "manual",
            "is_manual": True,   # 手动权威标记：下游对齐/兜底必须尊重，不得用自动标签覆盖
        }
        records.append(rec)
    records.sort(key=lambda r: r["path"].lower())
    return records


def normalize_records(raw_data: Any, root: Path) -> tuple[list[dict[str, Any]], str]:
    """
    兼容归一化各种 tags.json 格式:
      0. 手动增量(delta)格式: 返回值仅含「人工打标/复核」的记录(manual_tags 即最终标签)
      1. 列表格式: list[{path/file, tags/tag, confidence, ...}]
      2. 字典格式: {"images": [...]} 或 {"records": [...]}
    返回: (标准化 records 列表, 格式名称)
    """
    if _is_delta_format(raw_data):
        return _records_from_delta(raw_data, root), "delta"
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
        # 注意：tags 已是规范形式（"Others"），此前这里的 "others" 小写比较永远为假，
        # 导致「未分类素材」不会被自动标记待复核。
        review = bool(item.get("review_required", False)) or (conf < 0.75) or (OTHERS_TAG in tags)

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
            "is_manual": bool(item.get("is_manual")),
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
            for k in ("width", "height", "format", "size", "mtime", "aspect_ratio", "orientation",
                      "long_side", "too_small_long"):
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
                for k in ("width", "height", "format", "size", "mtime", "aspect_ratio", "orientation",
                          "long_side", "too_small_long"):
                    if k not in r or not r[k]:
                        r[k] = info.get(k)

    # 建立已有记录中有效真实标签的 Hash 映射库 (用于自动继承)
    hash_donor_map: dict[str, dict[str, Any]] = {}

    def _offer_donor(rec: dict[str, Any]) -> None:
        """登记候选捐赠者；同一 Hash 下手动记录优先于自动记录。"""
        h = (rec.get("hash") or "").strip().lower()
        if not h or not extract_real_tags(rec.get("tags")):
            return
        if h in hash_donor_map:
            cur = hash_donor_map[h]
            # 已有手动则忽略自动候选；当前自动且候选手动则升级为手动
            if cur.get("is_manual") and not rec.get("is_manual"):
                return
            if not cur.get("is_manual") and rec.get("is_manual"):
                hash_donor_map[h] = rec
            return
        hash_donor_map[h] = rec

    for r in active_records:
        _offer_donor(r)
    for o in orphan_records:
        _offer_donor(o)

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
                "is_manual": bool(donor.get("is_manual")),
                "width": info.get("width", 0),
                "height": info.get("height", 0),
                "format": info.get("format", ""),
                "size": info.get("size", 0),
                "mtime": info.get("mtime", 0),
                "aspect_ratio": info.get("aspect_ratio", 1.0),
                "orientation": info.get("orientation", "square"),
                "long_side": info.get("long_side", 0),
                "too_small_long": bool(info.get("too_small_long", False)),
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
                "is_manual": False,
                "width": info.get("width", 0),
                "height": info.get("height", 0),
                "format": info.get("format", ""),
                "size": info.get("size", 0),
                "mtime": info.get("mtime", 0),
                "aspect_ratio": info.get("aspect_ratio", 1.0),
                "orientation": info.get("orientation", "square"),
                "long_side": info.get("long_side", 0),
                "too_small_long": bool(info.get("too_small_long", False)),
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
        if len(group) < 2:
            continue
        # 手动权威：只要组内含手动记录，一律以手动标签为准，自动副本对齐到手动；手动成员永不改动
        manuals = [it for it in group if it.get("is_manual")]
        if manuals:
            manual_real: list[str] = []
            any_manual_untagged = False
            for m in manuals:
                real = extract_real_tags(m.get("tags"))
                if real:
                    for t in real:
                        if t not in manual_real:
                            manual_real.append(t)
                else:
                    any_manual_untagged = True
            target = manual_real if manual_real else [OTHERS_TAG]
            for item in group:
                if item.get("is_manual"):
                    continue  # 尊重手动选择，绝不被自动标签覆盖
                item["tags"] = list(target)
                item["catalogs"] = list(get_catalogs_for_tags(target))
                item["confidence"] = max(float(item.get("confidence", 0.0)), 0.9)
                item["review_required"] = bool(any_manual_untagged) or (target == [OTHERS_TAG])
                item["reason"] = "对齐手动标签"
            continue

        # 无手动成员：保持原有全自动 union 对齐语义
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



def save_tags_file(root: str | Path, records: list[dict[str, Any]], target_file: Path | None = None) -> tuple[bool, str, int, int]:
    """
    原子安全保存 tags.json —— 手动增量(delta)格式。
    仅持久化「人工打标/复核」的记录；目录名可自动推导出的标签(Cats->Pets 等)不落盘，
    读取时由扫描/merge 从路径重算，文件因此显著变小、可读性与 diff 更清晰。

    判定规则(应落盘即成为 delta)：
      - 已存在的 delta(一旦手动、永不自动归零)：按 hash 身份保留/更新；
      - 全新记录：最终标签 ≠ 目录名基准标签，或含人工备注(subject/scene/reason)时落盘；
      - 否则为纯自动记录，跳过(计入 auto_skipped)。
    写入 .tmp 文件校验无误后再原子替换，杜绝断电损坏。
    返回: (success, filepath_or_error, saved, auto_skipped)
    """
    r = Path(root).resolve()
    ws = StudioWorkspace(r)
    dest = target_file if target_file else ws.tags_file

    # 读取现有文件：保留 hash/sha1 映射；若为 delta 格式则记录其身份键(一旦手动永不归零)
    hash_map: dict[str, str] = {}
    sha_map: dict[str, str] = {}
    existing_delta_keys: set[str] = set()
    if dest.exists():
        try:
            old_raw = json.loads(dest.read_text(encoding="utf-8"))
            if isinstance(old_raw, dict):
                old_items = old_raw.get("records") or old_raw.get("images") or []
            elif isinstance(old_raw, list):
                old_items = old_raw
            else:
                old_items = []
            for item in old_items:
                if not isinstance(item, dict):
                    continue
                pk = item.get("path") or ""
                if item.get("hash"):
                    hash_map[pk] = item["hash"]
                if item.get("sha1"):
                    sha_map[pk] = item["sha1"]
                if "manual_tags" in item:
                    hk = str(item.get("hash") or "").strip().lower()
                    if hk:
                        existing_delta_keys.add(hk)
                    existing_delta_keys.add("path:" + pk)
        except Exception:
            pass

    now_iso = datetime.now().isoformat(timespec="seconds")
    out_list: list[dict[str, Any]] = []
    saved = 0
    auto_skipped = 0

    for item in records:
        if not isinstance(item, dict):
            auto_skipped += 1
            continue
        rel = (item.get("path") or item.get("file") or "").replace("\\", "/")
        if not rel:
            auto_skipped += 1
            continue

        tags_norm: list[str] = []
        for t in (item.get("tags") or []):
            canon = normalize_token(str(t)) or str(t).strip().lower()
            if canon and canon not in tags_norm:
                tags_norm.append(canon)
        if not tags_norm:
            tags_norm = ["Others"]

        eff_key = str(item.get("hash") or "").strip().lower()
        key = eff_key or ("path:" + rel)

        # 目录名自动基准：与最终标签一致则无需落盘
        base = guess_tags_from_path(r / rel, root=r)
        base_set = {normalize_token(t) for t in base if t}

        # 手动权威：is_manual(前端显式动作) 无条件落盘；differs/has_text 作为非前端生产者的安全网
        already_manual = key in existing_delta_keys or ("path:" + rel) in existing_delta_keys or (eff_key in existing_delta_keys)
        differs = set(tags_norm) != base_set
        manual_flag = bool(item.get("is_manual"))
        # 人工文本信号仅看 subject/scene：merge 会自动给每条记录写 reason(智能推断/继承等)，不能作为手动依据
        has_text = bool(item.get("subject") or item.get("scene"))

        if not manual_flag and not already_manual and not differs and not has_text:
            auto_skipped += 1
            continue

        # 记录级先标记持久化：对象持久化时一律落 type="manual"，自动推断被显式禁用
        delta: dict[str, Any] = {
            "type": "manual",   # 显式手动/覆盖记录；tags 为空或 [Others] 也视为人为指定，绝不 re-derive
            "path": rel,
            "hash": item.get("hash") or hash_map.get(rel, ""),
            "sha1": item.get("sha1") or sha_map.get(rel, ""),
            "manual_tags": tags_norm,
        }
        if item.get("subject"):
            delta["subject"] = item["subject"]
        if item.get("scene"):
            delta["scene"] = item["scene"]
        if item.get("reason") and not _is_auto_reason(item.get("reason")):
            delta["reason"] = item["reason"]
        # 复核为纯派生信号(未打标/低置信)，由 tags 推导，不再落盘冗余
        delta["updated_at"] = now_iso
        out_list.append(delta)
        saved += 1

    out_list.sort(key=lambda d: d["path"].lower())
    payload: dict[str, Any] = {
        "$schema": DELTA_SCHEMA,
        "key": "hash",
        "records": out_list,
    }

    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp_file = dest.with_suffix(".tmp")
        tmp_file.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp_file.replace(dest)
        try:
            rel_dest = dest.relative_to(r).as_posix()
        except Exception:
            rel_dest = str(dest)
        ws.record_audit(
            "tag_save",
            scope="tags",
            entity=rel_dest,
            after={"saved": saved, "auto_skipped": auto_skipped, "total": len(out_list)},
            result="ok",
        )
        logger.info(
            "[tags] 已保存 tags.json: %s (手动=%d, 自动跳过=%d)", dest.resolve(), saved, auto_skipped
        )
        return True, str(dest.resolve()), saved, auto_skipped
    except Exception as e:
        logger.error("[tags] 保存 tags.json 失败: %s (%s)", dest, e)
        return False, str(e), 0, 0
