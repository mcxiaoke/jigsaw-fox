#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.core.image_proc — Pillow 图像处理、缩略图生成与格式转换
"""

from __future__ import annotations

import hashlib
import io
import mimetypes
import shutil
import sys
from pathlib import Path
from typing import Any

try:
    from PIL import Image, ImageOps  # type: ignore

    HAS_PIL = True
except ImportError:
    HAS_PIL = False

# 服务端缩略图磁盘缓存目录 (存放于 temp/studio_cache/thumbs/)
THUMB_CACHE_DIR = Path(__file__).resolve().parent.parent.parent / "temp" / "studio_cache" / "thumbs"


def get_thumb_cache_path(img_path: Path, size: int) -> Path | None:
    """计算缩略图唯一缓存路径 (基于绝对路径、文件修改时间戳、文件大小与目标尺寸)。"""
    try:
        st = img_path.stat()
        key_str = f"{img_path.resolve()}_{st.st_mtime_ns}_{st.st_size}_{size}"
        key_hash = hashlib.md5(key_str.encode("utf-8")).hexdigest()
        return THUMB_CACHE_DIR / key_hash[:2] / f"{key_hash}.jpg"
    except Exception:
        return None


def generate_thumbnail_bytes(img_path: Path | str, size: int = 360, quality: int = 82) -> tuple[bytes | None, str]:
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
    cache_path = get_thumb_cache_path(p, size)
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

                # 写入服务端磁盘缓存
                if cache_path:
                    try:
                        cache_path.parent.mkdir(parents=True, exist_ok=True)
                        tmp_cache = cache_path.with_suffix(".tmp")
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
