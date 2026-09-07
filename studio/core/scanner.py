#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.core.scanner — 目录图片扫描与元数据提取
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import os
from pathlib import Path
from typing import Any, Callable

try:
    from PIL import Image

    HAS_PIL = True
except ImportError:
    HAS_PIL = False

from studio.core.image_proc import report_pil_warnings

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".tif", ".tiff"}
IGNORE_DIRS = {".git", ".svn", ".idea", ".vscode", "__pycache__", "node_modules", "temp", "tmp"}


def scan_images(root: str | Path) -> list[Path]:
    """
    递归扫描指定目录下的所有图片文件。
    忽略隐藏目录和开发辅助目录，按相对路径小写排序。
    """
    r = Path(root).resolve()
    if not r.exists() or not r.is_dir():
        return []

    images: list[Path] = []
    for root_dir, dirs, files in os.walk(r):
        # 过滤忽略目录
        dirs[:] = [d for d in dirs if not d.startswith(".") and d not in IGNORE_DIRS]
        for f in files:
            if f.startswith("."):
                continue
            p = Path(root_dir) / f
            if p.suffix.lower() in IMAGE_EXTS:
                images.append(p)

    return sorted(images, key=lambda p: p.relative_to(r).as_posix().lower())


def compute_file_sha256(path: Path | str, chunk_size: int = 128 * 1024) -> str:
    """计算单个文件的 SHA-256 哈希值十六进制字符串。"""
    p = Path(path)
    h = hashlib.sha256()
    with open(p, "rb") as f:
        while chunk := f.read(chunk_size):
            h.update(chunk)
    return h.hexdigest()


def get_image_info(p: Path, root: Path, file_hash: str | None = None) -> dict[str, Any] | None:
    """
    提取图片的路径、名称、大小、修改时间、分辨率 (宽x高)、格式、Hash 等完整元数据。
    Pillow 读取头信息 (Image.open) 为惰性读取，不解码像素，毫秒级快速提取。
    """
    try:
        stat = p.stat()
        rel = p.relative_to(root).as_posix().replace("\\", "/")
        width = 0
        height = 0
        fmt = p.suffix.lstrip(".").upper()
        if fmt == "JPG":
            fmt = "JPEG"
        mode = "RGB"

        if HAS_PIL:
            try:
                with report_pil_warnings(p.relative_to(root)):
                    with Image.open(p) as im:
                        width, height = im.size
                        if im.format:
                            fmt = im.format.upper()
                        mode = im.mode
            except Exception:
                pass

        aspect_ratio = round(width / height, 2) if height > 0 else 1.0
        orientation = "square"
        if width > height:
            orientation = "landscape"
        elif height > width:
            orientation = "portrait"

        # 若未显式传入 Hash，则现场计算
        if file_hash is None:
            try:
                file_hash = compute_file_sha256(p)
            except Exception:
                file_hash = ""

        return {
            "path": rel,
            "file": p.name,
            "size": stat.st_size,
            "mtime": int(stat.st_mtime),
            "hash": file_hash,
            "width": width,
            "height": height,
            "format": fmt,
            "mode": mode,
            "aspect_ratio": aspect_ratio,
            "orientation": orientation,
        }
    except Exception:
        return None


def scan_image_infos(
    images: list[Path],
    root: Path,
    hash_cache: dict[str, tuple[int, int, str]] | None = None,
    progress_callback: Callable[[int, int, int, int], None] | None = None,
    max_workers: int = 16,
    stats_out: dict[str, Any] | None = None,
) -> dict[str, dict[str, Any]]:
    """
    并发批量提取图片元数据，返回以相对路径为 key 的字典。
    支持智能增量 Hash 缓存 (hash_cache: rel_path -> (mtime, size, sha256)):
    未变动的文件命中缓存直接复用，耗时 0ms；仅对新增或变动文件计算 SHA-256。
    支持 progress_callback(completed, total, cache_hits, new_hashes) 实时进度回调。
    支持 stats_out 传出详细统计信息 (total, cache_hits, new_hashes, errors)。
    """
    infos: dict[str, dict[str, Any]] = {}
    if not images:
        if stats_out is not None:
            stats_out.update({"total": 0, "cache_hits": 0, "new_hashes": 0, "errors": 0})
        return infos

    total = len(images)
    cache_hits = 0
    new_hashes = 0
    errors = 0
    completed = 0

    def _worker(p: Path) -> tuple[dict[str, Any] | None, bool]:
        file_hash = ""
        is_hit = False
        c_width = 0
        c_height = 0
        c_format = ""
        try:
            stat = p.stat()
            rel = p.relative_to(root).as_posix().replace("\\", "/")
            mtime = int(stat.st_mtime)
            size = stat.st_size

            # 增量哈希与元数据缓存命中判断
            if hash_cache and rel in hash_cache:
                entry = hash_cache[rel]
                c_mtime = entry[0]
                c_size = entry[1]
                c_hash = entry[2]
                if len(entry) >= 6:
                    c_width = int(entry[3])
                    c_height = int(entry[4])
                    c_format = str(entry[5])

                if c_hash and c_mtime == mtime and c_size == size:
                    file_hash = c_hash
                    is_hit = True

            # 若完全命中且已有宽高等基础元数据，直接 0ms 组装返回，避免磁盘读取与 PIL 解析
            if is_hit and c_width > 0 and c_height > 0:
                aspect_ratio = round(c_width / c_height, 2)
                orientation = "square"
                if c_width > c_height:
                    orientation = "landscape"
                elif c_height > c_width:
                    orientation = "portrait"
                return {
                    "path": rel,
                    "file": p.name,
                    "size": size,
                    "mtime": mtime,
                    "hash": file_hash,
                    "width": c_width,
                    "height": c_height,
                    "format": c_format or p.suffix.lstrip(".").upper(),
                    "mode": "RGB",
                    "aspect_ratio": aspect_ratio,
                    "orientation": orientation,
                }, True

            if not file_hash:
                file_hash = compute_file_sha256(p)
        except Exception:
            file_hash = ""

        info = get_image_info(p, root, file_hash=file_hash)
        return info, is_hit

    workers = min(max_workers, total)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(_worker, p) for p in images]
        for fut in as_completed(futures):
            completed += 1
            info, is_hit = fut.result()
            if is_hit:
                cache_hits += 1
            else:
                new_hashes += 1

            if info:
                infos[info["path"]] = info
            else:
                errors += 1

            if progress_callback:
                progress_callback(completed, total, cache_hits, new_hashes)

    if stats_out is not None:
        stats_out.update({
            "total": total,
            "cache_hits": cache_hits,
            "new_hashes": new_hashes,
            "errors": errors,
        })

    return infos


def find_tags_file(root: str | Path) -> Path | None:
    """在目录下寻找现存的 tags.json 文件（优先新版 .studio/tags.json，兼顾历史候选名）。"""
    r = Path(root).resolve()
    studio_tags = r / ".studio" / "tags.json"
    if studio_tags.exists() and studio_tags.is_file():
        return studio_tags

    candidates = ["tags.json", "ai_tags.json", "puzzle_tags.json", ".puzzle_tags.json"]
    for name in candidates:
        target = r / name
        if target.exists() and target.is_file():
            return target
    return None


def find_duplicate_groups(
    records_or_infos: list[dict[str, Any]] | dict[str, dict[str, Any]],
) -> dict[str, list[dict[str, Any]]]:
    """
    按 SHA-256 Hash 聚合并提取所有内容重复的图片组。
    返回: { hash: [record_or_info, ...] }，仅包含 >= 2 个不同路径文件的重复组。
    """
    if isinstance(records_or_infos, dict):
        items = list(records_or_infos.values())
    elif isinstance(records_or_infos, list):
        items = records_or_infos
    else:
        return {}

    by_hash: dict[str, list[dict[str, Any]]] = {}
    for it in items:
        h = (it.get("hash") or it.get("sha256") or "").strip().lower()
        if not h:
            continue
        by_hash.setdefault(h, []).append(it)

    dup_groups: dict[str, list[dict[str, Any]]] = {}
    for h, group in by_hash.items():
        seen_paths: set[str] = set()
        unique_group: list[dict[str, Any]] = []
        for it in group:
            p = (it.get("path") or it.get("file") or "").replace("\\", "/")
            if p not in seen_paths:
                seen_paths.add(p)
                unique_group.append(it)
        if len(unique_group) >= 2:
            dup_groups[h] = unique_group

    return dup_groups

