#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.core.image_proc — Pillow 图像处理、缩略图生成与格式转换
"""

from __future__ import annotations

import hashlib
import io
import mimetypes
import os
import shutil
import sys
import threading
from pathlib import Path
from typing import Any

try:
    from PIL import Image, ImageOps  # type: ignore

    HAS_PIL = True
except ImportError:
    HAS_PIL = False

# 服务端缩略图磁盘缓存目录 (优先存放于源工作区 srcDir/.studio/cache/thumbs/)
DEFAULT_THUMB_CACHE_DIR = Path(__file__).resolve().parent.parent.parent / "temp" / "studio_cache" / "thumbs"
THUMB_CACHE_DIR = DEFAULT_THUMB_CACHE_DIR


def _find_studio_cache_dir(p: Path) -> Path | None:
    """自底向上查找素材源工作区的 .studio/cache/thumbs 目录。"""
    try:
        curr = p.resolve().parent
        for _ in range(12):
            if (curr / ".studio").is_dir():
                return curr / ".studio" / "cache" / "thumbs"
            if curr.parent == curr:
                break
            curr = curr.parent
    except Exception:
        pass
    return None


def get_thumb_cache_path(img_path: Path, size: int, cache_dir: Path | None = None) -> Path | None:
    """计算缩略图唯一缓存路径 (优先存放于素材源目录的 .studio/cache/thumbs，保障自包含时光机)。"""
    try:
        st = img_path.stat()
        key_str = f"{img_path.resolve()}_{st.st_mtime_ns}_{st.st_size}_{size}"
        key_hash = hashlib.md5(key_str.encode("utf-8")).hexdigest()
        target_dir = cache_dir or _find_studio_cache_dir(img_path) or THUMB_CACHE_DIR
        return target_dir / key_hash[:2] / f"{key_hash}.jpg"
    except Exception:
        return None


def generate_thumbnail_bytes(
    img_path: Path | str,
    size: int = 360,
    quality: int = 82,
    cache_dir: Path | None = None,
) -> tuple[bytes | None, str]:
    """
    生成指定尺寸的缩略图字节数据 (默认 JPEG 格式)。
    内置服务端多级磁盘缓存：相同文件在未被修改前直接秒级命中缓存返回，避免重复 LANCZOS 重绘计算。
    如果 Pillow 可用，执行等比缩放、EXIF 矫正、透明底白底合成；
    如果 Pillow 不可用，直接回退读取原图字节。
    返回: (data_bytes, mime_type)
    """
    p = Path(img_path)
    if not p.exists() or not p.is_file():
        return None, "application/octet-stream"

    size = max(64, min(size, 1200))

    # 1. 优先命中服务端磁盘缓存 (避免重复解压缩与缩放)
    cache_path = get_thumb_cache_path(p, size, cache_dir=cache_dir)
    if cache_path and cache_path.exists():
        try:
            return cache_path.read_bytes(), "image/jpeg"
        except Exception:
            pass

    if HAS_PIL:
        try:
            with Image.open(p) as im:
                try:
                    im = ImageOps.exif_transpose(im)
                except Exception:
                    pass

                # 缩放至最大边不超 size
                im.thumbnail((size, size), Image.Resampling.LANCZOS)

                # 透明通道处理 (合成到纯白背景上)
                if im.mode == "RGBA":
                    bg = Image.new("RGB", im.size, (255, 255, 255))
                    bg.paste(im, mask=im.split()[3])
                    im = bg
                elif im.mode != "RGB":
                    im = im.convert("RGB")

                buf = io.BytesIO()
                im.save(buf, format="JPEG", quality=quality, optimize=True)
                data = buf.getvalue()

                # 写入服务端磁盘缓存 (使用带线程标识的临时文件，防止并发写入冲突)
                if cache_path:
                    try:
                        cache_path.parent.mkdir(parents=True, exist_ok=True)
                        tmp_cache = cache_path.with_suffix(f".tmp_{os.getpid()}_{threading.get_ident()}")
                        tmp_cache.write_bytes(data)
                        tmp_cache.replace(cache_path)
                    except Exception:
                        pass

                return data, "image/jpeg"
        except Exception as e:
            sys.stderr.write(f"[image_proc] thumbnail error for {p}: {e}\n")

    # 兜底直接读取原图
    ctype, _ = mimetypes.guess_type(str(p))
    return p.read_bytes(), (ctype or "image/jpeg")


def convert_image(
    src_path: Path,
    dst_path: Path,
    fmt: str = "original",
    quality: int = 85,
) -> tuple[bool, str | None]:
    """
    批量导出格式转换。
    支持: 'original' (原格式直接复制), 'webp', 'jpg'/'jpeg', 'png'。
    返回: (success: bool, error_message: str | None)
    """
    if fmt == "original" or not HAS_PIL:
        try:
            if src_path.resolve() != dst_path.resolve():
                dst_path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src_path, dst_path)
            return True, None
        except Exception as e:
            return False, str(e)

    try:
        dst_path.parent.mkdir(parents=True, exist_ok=True)
        with Image.open(src_path) as im:
            try:
                im = ImageOps.exif_transpose(im)
            except Exception:
                pass

            target_fmt = fmt.lower()
            if target_fmt == "webp":
                if im.mode not in ("RGB", "RGBA"):
                    im = im.convert("RGB")
                im.save(dst_path, "WEBP", quality=quality, method=6)
            elif target_fmt in ("jpg", "jpeg"):
                if im.mode == "RGBA":
                    bg = Image.new("RGB", im.size, (255, 255, 255))
                    bg.paste(im, mask=im.split()[3])
                    im = bg
                elif im.mode != "RGB":
                    im = im.convert("RGB")
                im.save(dst_path, "JPEG", quality=quality, optimize=True)
            elif target_fmt == "png":
                im.save(dst_path, "PNG", optimize=True)
            else:
                shutil.copy2(src_path, dst_path)
            return True, None
    except Exception as e:
        return False, str(e)


def make_rename(
    original_name: str,
    idx: int,
    rule: str,
    fmt: str,
    month: str = "",
) -> str:
    """
    根据重命名规则生成输出文件名。
    rule:
      - 'none': 保持原文件名 (若转格式则换后缀)
      - 'sequence': 三位数字序号，如 001.webp, 101.webp
      - 'date': 结合月份或当前日期，如 20260901.webp 或 20260904_001.webp
    """
    target_ext = f".{fmt}" if (fmt and fmt != "original") else Path(original_name).suffix

    if rule == "sequence":
        return f"{idx:03d}{target_ext}"

    if rule == "date":
        if month:
            dd = f"{idx:02d}"
            return f"{month}{dd}{target_ext}"
        import datetime as dt

        today = dt.datetime.now().strftime("%Y%m%d")
        return f"{today}_{idx:03d}{target_ext}"

    # rule == 'none'
    if fmt and fmt != "original":
        return f"{Path(original_name).stem}{target_ext}"
    return original_name


def validate_image(img_path: Path | str) -> tuple[bool, str | None]:
    """
    深度校验图片文件的物理存在性、非空以及是否损坏或不可解码。
    返回: (is_valid: bool, error_msg: str | None)
    """
    p = Path(img_path)
    if not p.exists() or not p.is_file():
        return False, f"文件不存在或无法访问: {p}"
    try:
        size = p.stat().st_size
        if size <= 0:
            return False, f"文件大小为 0 字节: {p.name}"
    except Exception as e:
        return False, f"无法读取文件属性: {e}"

    if HAS_PIL:
        try:
            with Image.open(p) as im:
                im.verify()
            with Image.open(p) as im:
                im.draft(None, (32, 32))
                im.load()
        except Exception as e:
            return False, f"图片数据损坏或格式不可识别 ({p.name}): {e}"

    return True, None

