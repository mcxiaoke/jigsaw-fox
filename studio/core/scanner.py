#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.core.scanner — 目录图片扫描与元数据提取
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

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


def get_image_info(p: Path, root: Path) -> dict[str, Any] | None:
    """提取图片的路径、名称、大小和修改时间元数据。"""
    try:
        stat = p.stat()
        rel = p.relative_to(root).as_posix().replace("\\", "/")
        return {
            "path": rel,
            "file": p.name,
            "size": stat.st_size,
            "mtime": int(stat.st_mtime),
        }
    except Exception:
        return None


def find_tags_file(root: str | Path) -> Path | None:
    """在目录下寻找现存的 tags.json 文件（支持常见候选名）。"""
    r = Path(root).resolve()
    candidates = ["tags.json", "ai_tags.json", "puzzle_tags.json", ".puzzle_tags.json"]
    for name in candidates:
        target = r / name
        if target.exists() and target.is_file():
            return target
    return None
