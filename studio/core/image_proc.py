#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.core.image_proc — Pillow 图像处理、缩略图生成与格式转换
"""

from __future__ import annotations

import contextlib
import hashlib
import io
import logging
import mimetypes
import os
import shutil
import sys
import threading
import warnings
from pathlib import Path
from typing import Any, Iterator

_logger = logging.getLogger("studio.core.image_proc")


@contextlib.contextmanager
def report_pil_warnings(ref: object) -> Iterator[None]:
    """
    捕获处理某张图片期间 Pillow 抛出的警告（如 DecompressionBombWarning、
    Corrupt EXIF 等），并附加正在处理的图片标识输出到日志。

    原 Python warnings 默认只打印到 stderr 且按 (message,file,line) 去重，
    无法看出触发源是哪个图片文件；这里统一转发为带路径的日志行。
    """
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        yield
    for w in caught:
        _logger.warning(
            "[Pillow %s] %s (%s)",
            ref,
            w.message,
            w.category.__name__,
        )


try:
    from PIL import Image, ImageOps  # type: ignore

    HAS_PIL = True
except ImportError:
    HAS_PIL = False

# 导出规格化：长边目标（固定常量，改需求改这里）
DEFAULT_LONG_TARGET = 1920

# 规格化纯算法依赖 numpy（能量图/积分图）。缺失时规格化导出不可用，普通转码仍正常。
try:
    from studio.core.crop_compute import (
        aspect_crop_box,
        build_ratio_pool,
        compute_content_box,
        expand_ratio_families,
        fusion_content_box,
        resize_long,
        saliency_content_box,
        select_aspect,
        smart_aspect_crop_box,
    )

    HAS_CROP_COMPUTE = True
except Exception:  # noqa: BLE001  numpy 缺失等任何导入失败都降级
    HAS_CROP_COMPUTE = False

# 服务端缩略图磁盘缓存目录 (优先存放于源工作区 srcDir/.studio/cache/thumbs/)
DEFAULT_THUMB_CACHE_DIR = (
    Path(__file__).resolve().parent.parent.parent / "temp" / "studio_cache" / "thumbs"
)
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


def get_thumb_cache_path(
    img_path: Path, size: int, cache_dir: Path | None = None
) -> Path | None:
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
        _logger.debug("[image_proc] 缩略图缓存命中: %s (size=%d)", p, size)
        try:
            return cache_path.read_bytes(), "image/jpeg"
        except Exception:
            pass

    if HAS_PIL:
        _logger.debug("[image_proc] 生成缩略图: %s (size=%d)", p, size)
        with report_pil_warnings(p):
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
                            tmp_cache = cache_path.with_suffix(
                                f".tmp_{os.getpid()}_{threading.get_ident()}"
                            )
                            tmp_cache.write_bytes(data)
                            tmp_cache.replace(cache_path)
                        except Exception as e:
                            _logger.warning(
                                "[image_proc] 缩略图缓存写入失败: %s (%s)",
                                cache_path,
                                e,
                            )

                    return data, "image/jpeg"
            except Exception as e:
                _logger.warning("[image_proc] 生成缩略图失败: %s (%s)", p, e)

    # 兜底直接读取原图
    ctype, _ = mimetypes.guess_type(str(p))
    return p.read_bytes(), (ctype or "image/jpeg")


def convert_image(
    src_path: Path,
    dst_path: Path,
    fmt: str = "original",
    quality: int = 70,
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

    with report_pil_warnings(src_path):
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


def image_long_side(img_path: Path | str) -> int | None:
    """返回图片长边（max(宽,高)）；不可解码或 PIL 缺失时返回 None。"""
    if not HAS_PIL:
        return None
    try:
        with Image.open(img_path) as im:
            w, h = im.size
            return int(max(w, h))
    except Exception:
        return None


def normalize_export_image(
    src_path: Path,
    dst_path: Path,
    *,
    fmt: str = "webp",
    quality: int = 70,
    target_ratios: tuple[str, ...] = ("auto",),
    long_target: int = DEFAULT_LONG_TARGET,
    crop_mode: str = "smart",
    trim_background: bool = True,
    manual_box_pct: tuple[float, float, float, float] | None = None,
) -> tuple[bool, str | None, dict | None]:
    """规格化导出：打开 → EXIF 校正 → 长边阻断 → (可选)去背景框定 → 比例裁切 → 长边缩放 → 转码写盘。

    target_ratios: 比例族数组，元素为 "auto" / "1:1" / "4:3" / "2:3"；"auto" 并入默认池(1:1+4:3族)。
    crop_mode: "smart" 主体感知 / "center" 居中 / "none" 不裁切(仅缩放)。
    manual_box_pct: 用户手动裁切框百分比 (x0, y0, x1, y1) 范围 0.0~1.0。设置时直接用作 crop_box，
                    跳过 compute_content_box + select_aspect + smart_aspect_crop_box。
    返回 (ok, err, meta)。源图长边 < long_target 时阻断：ok=False、err 为阻断提示、meta=None。
    """
    if not HAS_CROP_COMPUTE:
        return (
            False,
            "规格化算法依赖 numpy 缺失（请安装 numpy），无法执行规格化导出",
            None,
        )
    with report_pil_warnings(src_path):
        try:
            dst_path.parent.mkdir(parents=True, exist_ok=True)
            with Image.open(src_path) as im:
                try:
                    im = ImageOps.exif_transpose(im)
                except Exception:
                    pass
                W, H = im.size
                if max(W, H) < long_target:
                    return (
                        False,
                        (
                            f"源图长边不足: 长边 {max(W, H)}px < 目标 {long_target}px，导出被阻断"
                            f"（官方只发布高清图，请更换更高分辨率素材）"
                        ),
                        None,
                    )

                if manual_box_pct:
                    # 用户手动裁切框: 百分比→像素，直接用作 crop_box
                    x0 = int(manual_box_pct[0] * W)
                    y0 = int(manual_box_pct[1] * H)
                    x1 = int(manual_box_pct[2] * W)
                    y1 = int(manual_box_pct[3] * H)
                    # 安全裁剪到图像边界
                    x0 = max(0, min(x0, W))
                    y0 = max(0, min(y0, H))
                    x1 = max(0, min(x1, W))
                    y1 = max(0, min(y1, H))
                    if x1 - x0 < 10 or y1 - y0 < 10:
                        return False, "手动裁切框过小，导出被阻断", None
                    crop_box = (x0, y0, x1, y1)
                    content_box = crop_box
                    mode = "manual"
                    label = "manual"
                else:
                    # 1. (可选) 去背景内容感知框定 (默认融合算法 fusion_content_box = std25∪sal90)
                    if trim_background:
                        content_box = fusion_content_box(im)
                    else:
                        content_box = (0, 0, W, H)
                    cw = max(1, content_box[2] - content_box[0])
                    ch = max(1, content_box[3] - content_box[1])
                    content_aspect = cw / ch

                    # 2. 比例自适应选档（按最小损失，content_box 口径；横竖朝向由镜像自适应）
                    pool = build_ratio_pool(expand_ratio_families(list(target_ratios)))
                    target, label = select_aspect(content_aspect, ratio_pool=pool)

                    # 3. 裁窗定位
                    if crop_mode == "smart":
                        crop_box = smart_aspect_crop_box(im, content_box, target)
                        mode = "smart"
                    elif crop_mode == "center":
                        crop_box = aspect_crop_box(content_box, target)
                        mode = "center"
                    else:  # none
                        crop_box = (0, 0, W, H)
                        mode = "none"

                # 4. 长边缩放（只缩小不放大）
                out = resize_long(im.crop(crop_box), long_target)

                # 5. 转码写盘（与 convert_image 同口径）
                target_fmt = fmt.lower()
                if target_fmt == "webp":
                    if out.mode not in ("RGB", "RGBA"):
                        out = out.convert("RGB")
                    out.save(dst_path, "WEBP", quality=quality, method=6)
                elif target_fmt in ("jpg", "jpeg"):
                    if out.mode == "RGBA":
                        bg = Image.new("RGB", out.size, (255, 255, 255))
                        bg.paste(out, mask=out.split()[3])
                        out = bg
                    elif out.mode != "RGB":
                        out = out.convert("RGB")
                    out.save(dst_path, "JPEG", quality=quality, optimize=True)
                elif target_fmt == "png":
                    out.save(dst_path, "PNG", optimize=True)
                else:
                    return False, f"不支持的规格化输出格式: {fmt}", None

                ow, oh = out.size
                meta = {
                    "ratio_family": "/".join(
                        sorted({str(r).strip() for r in (target_ratios or ())})
                    )
                    or "auto",
                    "ratio": label,
                    "mode": mode,
                    "orig_size": [W, H],
                    "content_box": list(content_box),
                    "crop_box": list(crop_box),
                    "out_size": [ow, oh],
                    "long_target": long_target,
                }
                return True, None, meta
        except Exception as e:
            return False, str(e), None


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
    target_ext = (
        f".{fmt}" if (fmt and fmt != "original") else Path(original_name).suffix
    )

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


def sha256_file(p: Path | str) -> str:
    """计算文件 SHA-256（供并行转码 worker 使用，避免额外 import scanner）"""
    h = hashlib.sha256()
    try:
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return ""


# ---------------------------------------------------------------------------
# 并行批量转码 (多进程池)
# ---------------------------------------------------------------------------
# 单张 libwebp method=6 编码是 CPU 密集且无法单张内并行，批量导出的数量级
# 加速来自「多张图片并行编码」。worker 必须为模块级函数 (Windows spawn 可 pickle)。


def _convert_one_parallel(job: dict) -> dict:
    """进程池 worker：执行单张转码（或规格化转码）并按需返回源/目标哈希。

    job: {"src": str, "dst": str, "fmt": str, "quality": int,
          "need_src_hash": bool, "need_dst_hash": bool,
          "normalize": optional {target_ratios, long_target, crop_mode, trim_background, manual_box_pct}}
    携带 "normalize" 时走规格化（比例裁切+长边缩放）；否则退化为现有 convert_image。
    normalize.manual_box_pct 为用户手动裁切框百分比 (x0, y0, x1, y1) 0.0~1.0，设置时跳过自动裁切。
    返回: {"ok": bool, "err": str | None, "src_hash": str, "dst_hash": str,
           "dst_size": int, "normalize": dict|None}
    """
    src = Path(job["src"])
    dst = Path(job["dst"])
    fmt = job.get("fmt", "original")
    quality = int(job.get("quality", 70))
    normalize = job.get("normalize") or None
    meta = None
    if normalize and fmt.lower() != "original":
        mbp = normalize.get("manual_box_pct")
        # 手动裁切框百分比转 tuple（JSON round-trip 会变 list）
        mbp_tuple = (
            tuple(mbp) if isinstance(mbp, (list, tuple)) and len(mbp) == 4 else None
        )
        ok, err, meta = normalize_export_image(
            src,
            dst,
            fmt=fmt,
            quality=quality,
            target_ratios=tuple(normalize.get("target_ratios") or ("auto",)),
            long_target=int(normalize.get("long_target") or DEFAULT_LONG_TARGET),
            crop_mode=str(normalize.get("crop_mode") or "smart"),
            trim_background=bool(normalize.get("trim_background", True)),
            manual_box_pct=mbp_tuple,
        )
    else:
        ok, err = convert_image(src, dst, fmt, quality=quality)
    res = {
        "ok": ok,
        "err": err,
        "src_hash": sha256_file(src) if job.get("need_src_hash") else "",
        "dst_hash": sha256_file(dst)
        if job.get("need_dst_hash") and dst.exists()
        else "",
        "dst_size": dst.stat().st_size if dst.exists() else 0,
        "normalize": meta,
    }
    return res


def _default_export_workers() -> int:
    """默认并行 worker 数：环境变量 STUDIO_EXPORT_WORKERS 优先，否则 min(8, CPU 核数)。"""
    env = os.environ.get("STUDIO_EXPORT_WORKERS", "").strip()
    if env.isdigit() and int(env) > 0:
        return min(int(env), 64)
    try:
        return max(1, min(8, os.cpu_count() or 1))
    except Exception:
        return 4


def convert_images_parallel(
    tasks: list[dict],
    workers: int | None = None,
    on_progress=None,
) -> list[dict]:
    """并行批量转码一批图片。

    tasks: 元素与 _convert_one_parallel 的 job 相同。
    workers: 并行进程数；None 时按 _default_export_workers()。
    on_progress: 可选进度回调 progress(done, total, current, ok)，每完成一张调用一次，
                 current 为刚完成任务的 job dict (含 src/dst/fmt)，ok 为该任务是否成功；
                 回调抛出的任何异常都会被吞掉，绝不中断转码。默认 None 无行为变化。
    返回与 tasks 顺序一一对应的结果列表；进程池不可用 (如受限环境) 时
    自动回退为串行执行，保证任何环境下行为与结果一致。
    """
    if not tasks:
        return []
    n = workers or _default_export_workers()
    n = max(1, min(n, len(tasks)))
    total = len(tasks)

    if n <= 1:
        results: list[dict] = []
        for done_i, t in enumerate(tasks, start=1):
            r = _convert_one_parallel(t)
            results.append(r)
            if on_progress:
                try:
                    on_progress(done_i, total, t, bool(r.get("ok")), r)
                except Exception:
                    pass
        return results

    try:
        import concurrent.futures as _cf

        with _cf.ProcessPoolExecutor(max_workers=n) as ex:
            future_map = {
                ex.submit(_convert_one_parallel, t): i for i, t in enumerate(tasks)
            }
            results = [None] * total
            done_count = 0
            for fut in _cf.as_completed(future_map):
                i = future_map[fut]
                try:
                    results[i] = fut.result()
                except Exception as e:
                    results[i] = {
                        "ok": False,
                        "err": str(e),
                        "src_hash": "",
                        "dst_hash": "",
                        "dst_size": 0,
                        "normalize": None,
                    }
                done_count += 1
                if on_progress:
                    try:
                        on_progress(
                            done_count,
                            total,
                            tasks[i],
                            bool(results[i].get("ok")),
                            results[i],
                        )
                    except Exception:
                        pass
            return results
    except Exception:
        # 进程池不可用 (spawn 受限/内存不足等) 时顺序兜底，绝不中断导出
        results = []
        for done_i, t in enumerate(tasks, start=1):
            r = _convert_one_parallel(t)
            results.append(r)
            if on_progress:
                try:
                    on_progress(done_i, total, t, bool(r.get("ok")), r)
                except Exception:
                    pass
        return results


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
