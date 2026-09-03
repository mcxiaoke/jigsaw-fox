#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
imgcrop.py - 图片智能裁切与规格化工具（拼图素材预处理）

对输入目录中的图片执行以下处理：
  1. 自动裁切掉四周大面积、对比度极低的虚化/纯色背景（基于局部对比度的内容感知裁切）。
     原理：虚化/纯色区域局部对比度低，主体（羽毛、五官等细节）局部对比度高；
     从四边向内推进，遇到高对比度内容即停止；停止后再向外留 pad 像素余量
     （拼图碎片不能顶到裁切边）。阈值越小越保守、留得越多。
  2. 目标比例适配（默认在 2:3、1:1 中自动选择最接近原图长宽比的一项，支持横竖朝向；
     亦可通过 --ratios 自定义候选池如 2:3,1:1,4:3，或通过 --aspect 强制单一比例）。
  3. 裁切窗口定位：
     - 默认：画面中心对称居中裁切；
     - --smart：启用主体感知智能裁切，基于局部梯度边缘、色彩饱和度与主体特征计算能量分布，
       使用 2D 积分图自动滑动搜索最佳窗口，最大化保留画面主体，避免偏侧主体被裁切。
  4. 缩放使短边 <= 指定值（默认 1600），输出为 jpg 或 png。

用法示例：
  # 自动选择最接近比例 (2:3 / 1:1) + 居中裁切
  python imgcrop.py temp/daily temp/daily_out --format jpg --quality 85

  # 启用主体感知智能裁切（防止偏侧主体被裁切）
  python imgcrop.py temp/daily temp/daily_out --smart

  # 自定义候选比例池（包含 4:3）并启用智能裁切
  python imgcrop.py temp/daily temp/daily_out --smart --ratios 2:3,1:1,4:3

  # 跳过背景去虚化检测，纯原图做智能比例裁切
  python imgcrop.py temp/daily temp/daily_out --no-trim --smart --aspect 2:3
"""

import argparse
import csv
import os
import sys
from datetime import datetime, timezone, timedelta

import numpy as np
from PIL import Image, ImageFilter, ImageOps

# 时区 GMT+8
TZ = timezone(timedelta(hours=8))

# 默认基础目标比例（竖屏朝向，程序会自动补充镜像朝向以支持横屏）
BASE_RATIOS = [(2, 3), (1, 1)]

# 用于内容检测与能量分析的小图最长边
ANALYSIS_LONG = 512
# 单条边最多裁掉的比例（防止误判把画面切没）
CAP_FRAC = 0.5


def now_str():
    return datetime.now(TZ).strftime("%Y-%m-%d %H:%M:%S")


def parse_ratios(s):
    """解析以逗号分隔的基础比例字符串，如 '2:3,1:1' 或 '2:3,1:1,4:3'。"""
    ratios = []
    for item in s.split(","):
        item = item.strip()
        if not item:
            continue
        try:
            a, b = item.split(":")
            a, b = int(a), int(b)
            if a <= 0 or b <= 0:
                raise ValueError
            ratios.append((a, b))
        except Exception:
            raise argparse.ArgumentTypeError(f"无效的比例定义: {item!r}（应为如 2:3,1:1）")
    if not ratios:
        raise argparse.ArgumentTypeError("候选比例列表不能为空")
    return ratios


def build_ratio_pool(base_ratios=None):
    """构建候选比例池：每个基础比例及其镜像朝向，去重。返回 [(value, label), ...]"""
    if base_ratios is None:
        base_ratios = BASE_RATIOS
    pool = []
    seen = set()
    for a, b in base_ratios:
        for (na, nb) in ((a, b), (b, a)):
            v = na / nb
            if v in seen:
                continue
            seen.add(v)
            pool.append((v, f"{na}:{nb}"))
    return pool


def parse_aspect(s):
    """解析 'a:b' 为 (value, label)。"""
    try:
        a, b = s.split(":")
        a, b = float(a), float(b)
        if a <= 0 or b <= 0:
            raise ValueError
    except Exception:
        raise argparse.ArgumentTypeError(f"无效的长宽比: {s!r}（应为如 3:4 / 16:9）")
    return a / b, f"{s}"


def load_image(path):
    """读取图片并应用 EXIF 方向修正，统一为 RGB/RGBA。"""
    im = Image.open(path)
    im = ImageOps.exif_transpose(im)
    return im.convert("RGBA") if im.mode in ("RGBA", "LA", "P") else im.convert("RGB")


def _windowed_std(g, r):
    """用积分图计算每像素 (2r+1)x(2r+1) 邻域的局部标准差（对比度）。"""
    h, w = g.shape
    if h == 0 or w == 0:
        return g
    I = np.zeros((h + 1, w + 1), np.float64)
    I[1:, 1:] = np.cumsum(np.cumsum(g, axis=0), axis=1)
    I2 = np.zeros((h + 1, w + 1), np.float64)
    I2[1:, 1:] = np.cumsum(np.cumsum(g * g, axis=0), axis=1)
    ys = np.arange(h)
    xs = np.arange(w)
    y0 = np.clip(ys - r, 0, h)
    y1 = np.clip(ys + r + 1, 0, h)
    x0 = np.clip(xs - r, 0, w)
    x1 = np.clip(xs + r + 1, 0, w)
    S = (I[y1[:, None], x1[None, :]] - I[y0[:, None], x1[None, :]]
         - I[y1[:, None], x0[None, :]] + I[y0[:, None], x0[None, :]])
    S2 = (I2[y1[:, None], x1[None, :]] - I2[y0[:, None], x1[None, :]]
          - I2[y1[:, None], x0[None, :]] + I2[y0[:, None], x0[None, :]])
    cnt = np.maximum((y1[:, None] - y0[:, None]) * (x1[None, :] - x0[None, :]), 1)
    mean = S / cnt
    mean2 = S2 / cnt
    var = np.maximum(mean2 - mean * mean, 0.0)
    return np.sqrt(var).astype(np.float32)


def _usm_detail(g, radius=2):
    """USM 细节层 D = |I - GaussianBlur(I)|，即主流锐化算法用来判断'哪里需要锐化'的度量。

    对我们的反向裁切而言，这正是它要检测的东西，但动作相反：
      锐化：D 高 -> 加强；D 低 -> 不动。
      裁切：D 高 -> 保留（这是细节/主体）；D 低 -> 删掉（虚化/纯色/平滑渐变背景）。
    相比局部标准差，USM 细节层对'平滑渐变'同样给出近 0 的响应（高斯模糊能保留线性斜坡），
    因此既能剔除纯色块，也能剔除缓慢过渡的虚化背景。
    """
    h, w = g.shape
    if h == 0 or w == 0:
        return g
    pil = Image.fromarray(np.clip(g, 0, 255).astype(np.uint8), "L")
    blurred = pil.filter(ImageFilter.GaussianBlur(radius))
    b = np.asarray(blurred, dtype=np.float32)
    return np.abs(g - b).astype(np.float32)


def compute_content_box(img, trim_tol=12.0, margin_frac=0.0, win=4, detector="std", pad=16):
    """
    基于局部对比度（细节层）的内容感知裁切框。
    每一边从外到内逐行/列检测：当某区域的细节响应明显高于该边边框的背景基线
    （基线 + trim_tol）时即停止推进。虚化/纯色/平滑渐变区域细节弱 -> 继续裁；
    主体（羽毛、五官等细节）细节强 -> 停止保留。
    detector="std": 用 (2*win+1) 邻域局部标准差作为细节度量（默认，鲁棒、已充分校准）。
    detector="usm": 用 D=|I-GaussianBlur(I)| 作为细节度量（即主流锐化的反向，对平滑渐变更敏感）。
    返回原图像素坐标系下的 (x0, y0, x1, y1)。
    """
    W, H = img.size
    long_side = max(W, H)
    scale = min(1.0, ANALYSIS_LONG / long_side)
    sw = max(1, int(round(W * scale)))
    sh = max(1, int(round(H * scale)))

    g = np.asarray(img.resize((sw, sh), Image.LANCZOS).convert("L"), dtype=np.float32)
    if detector == "usm":
        L = _usm_detail(g, radius=max(1, win))   # USM 细节层（锐化的反向）
    else:
        L = _windowed_std(g, win)                # 每像素局部对比度 (0-255)
    # 每行/列取 90 百分位对比度：既能感知该区域是否有细节，又抗单点噪点
    row = np.percentile(L, 90, axis=1)
    col = np.percentile(L, 90, axis=0)

    # 各边最外缘背景基线（中位，抗噪）。无背景（主体贴边）则基线高 -> 该边不裁
    band_v = max(1, sh // 50)
    band_h = max(1, sw // 50)
    base_top = float(np.median(L[:band_v, :]))
    base_bot = float(np.median(L[sh - band_v:, :]))
    base_left = float(np.median(L[:, :band_h]))
    base_right = float(np.median(L[:, sw - band_h:]))

    cap_v = round(CAP_FRAC * sh)
    cap_h = round(CAP_FRAC * sw)

    def march(act, n, base, cap):
        T = base + trim_tol
        t = 0
        for i in range(n):
            if act[i] <= T:
                t = i + 1
            else:
                break
        return min(t, cap)

    tt = march(row, sh, base_top, cap_v)      # 上
    tb = march(row[::-1], sh, base_bot, cap_v)  # 下
    tl = march(col, sw, base_left, cap_h)    # 左
    tr = march(col[::-1], sw, base_right, cap_h)  # 右

    sx = W / sw
    sy = H / sh
    x0 = int(round(tl * sx))
    y0 = int(round(tt * sy))
    x1 = int(round((sw - tr) * sx))
    y1 = int(round((sh - tb) * sy))

    # 向外 padding：拼图素材需在主体四周留一定背景余量，避免碎片顶到裁切边
    pad = int(round(pad))
    x0 = max(0, x0 - pad)
    y0 = max(0, y0 - pad)
    x1 = min(W, x1 + pad)
    y1 = min(H, y1 + pad)

    # 可选安全内边距（默认 0）：略微内收避免切到主体抗锯齿边缘
    mw = int(round(margin_frac * W))
    mh = int(round(margin_frac * H))
    x0 = min(W, x0 + mw)
    y0 = min(H, y0 + mh)
    x1 = max(0, x1 - mw)
    y1 = max(0, y1 - mh)

    if x1 - x0 < 1 or y1 - y0 < 1:
        return (0, 0, W, H)
    return (x0, y0, x1, y1)


def aspect_crop_box(box, target_aspect):
    """在 box 内从中心对称裁切到 target_aspect (w/h)。"""
    x0, y0, x1, y1 = box
    w = x1 - x0
    h = y1 - y0
    if w <= 0 or h <= 0:
        return box
    cur = w / h
    if cur > target_aspect:
        nw = int(round(h * target_aspect))
        nh = h
    else:
        nw = w
        nh = int(round(w / target_aspect))
    if nw <= 0 or nh <= 0:
        return box
    nx0 = x0 + (w - nw) // 2
    ny0 = y0 + (h - nh) // 2
    return (nx0, ny0, nx0 + nw, ny0 + nh)


def compute_saliency_energy(img, analysis_long=512):
    """
    计算画面的主体显著性能量图（Saliency / Energy Map）。
    结合：
      1. 边缘高频细节（Sobel 梯度幅值）：强化毛发、轮廓、五官等关键特征；
      2. 色彩饱和度（HSV S通道）：突出色彩丰富的主体；
      3. 暖色/肤色加权（Skin/Warm Tone Boost）：对人物、动物等常见主体给予温和加权；
      4. 微弱中心先验（Subtle Center Bias）：全图均质或平淡无明确主体时平滑回退居中。
    返回: (energy_map, scale_x, scale_y)
    """
    W, H = img.size
    long_side = max(W, H)
    scale = min(1.0, analysis_long / long_side)
    sw = max(1, int(round(W * scale)))
    sh = max(1, int(round(H * scale)))

    small = img.resize((sw, sh), Image.BILINEAR)
    arr = np.asarray(small.convert("RGB"), dtype=np.float32)

    # 1. 边缘梯度能量 (Sobel 梯度幅值 + 高斯模糊平滑)
    gray = np.asarray(small.convert("L"), dtype=np.float32)
    gx = np.diff(gray, axis=1, prepend=gray[:, :1])
    gy = np.diff(gray, axis=0, prepend=gray[:1, :])
    grad = np.hypot(gx, gy)
    max_g = grad.max()
    if max_g > 1e-5:
        grad_im = Image.fromarray(np.clip(grad * (255.0 / max_g), 0, 255).astype(np.uint8))
        grad_blurred = np.asarray(grad_im.filter(ImageFilter.GaussianBlur(radius=2)), dtype=np.float32)
    else:
        grad_blurred = grad

    # 2. 色彩饱和度能量
    hsv = small.convert("HSV")
    sat = np.asarray(hsv.split()[1], dtype=np.float32)

    # 3. 暖色/肤色检测加权 (R > G > B 且 R - B > 20 且 R > 50)
    r, g, b = arr[:, :, 0], arr[:, :, 1], arr[:, :, 2]
    warm_mask = (r > g) & (g > b) & ((r - b) > 20.0) & (r > 50.0)
    warm_boost = np.where(warm_mask, 1.4, 1.0).astype(np.float32)

    # 4. 微弱中心先验 (距离中心最大处衰减约 15%)
    ys = np.linspace(-1.0, 1.0, sh, dtype=np.float32)[:, None]
    xs = np.linspace(-1.0, 1.0, sw, dtype=np.float32)[None, :]
    dist = np.sqrt(xs * xs + ys * ys)
    center_prior = np.clip(1.0 - 0.15 * dist, 0.7, 1.0)

    # 组合能量
    energy = (grad_blurred * 0.7 + sat * 0.3) * warm_boost * center_prior

    # 抑制底噪（低于 30 百分位的背景截断）
    thresh = float(np.percentile(energy, 30))
    energy = np.maximum(energy - thresh, 0.0)

    sx = sw / W
    sy = sh / H
    return energy, sx, sy


def smart_aspect_crop_box(img, box, target_aspect):
    """
    在 box 区域内基于画面显著性能量分布寻找最佳裁切窗口，
    尽量保证主体完整且不被裁切。若全图均质或平淡无明确主体，则自动回退居中裁切。
    """
    x0, y0, x1, y1 = box
    w = x1 - x0
    h = y1 - y0
    if w <= 0 or h <= 0:
        return box
    cur = w / h
    if cur > target_aspect:
        nw = int(round(h * target_aspect))
        nh = h
    else:
        nw = w
        nh = int(round(w / target_aspect))
    if nw <= 0 or nh <= 0:
        return box

    # 无移动余量，直接返回
    if nw >= w and nh >= h:
        return (x0, y0, x0 + nw, y0 + nh)

    energy, sx, sy = compute_saliency_energy(img)
    if energy.max() <= 1e-5:
        return aspect_crop_box(box, target_aspect)

    sh, sw = energy.shape
    I = np.zeros((sh + 1, sw + 1), dtype=np.float64)
    I[1:, 1:] = np.cumsum(np.cumsum(energy, axis=0), axis=1)

    snw = max(1, int(round(nw * sx)))
    snh = max(1, int(round(nh * sy)))

    max_x = x1 - nw
    max_y = y1 - nh

    if max_x <= x0 and max_y <= y0:
        return (x0, y0, x0 + nw, y0 + nh)

    # 水平单轴滑动（最常见，如原图太宽需裁两侧）
    if max_x > x0 and max_y <= y0:
        ny0 = y0
        step = max(1, int(round(1.0 / sx)))
        candidates = list(range(x0, max_x + 1, step))
        if candidates[-1] != max_x:
            candidates.append(max_x)

        ry0 = max(0, min(sh, int(round(y0 * sy))))
        ry1 = max(0, min(sh, ry0 + snh))

        best_score = -1.0
        best_nx0 = x0 + (w - nw) // 2

        for cand_x in candidates:
            rx0 = max(0, min(sw, int(round(cand_x * sx))))
            rx1 = max(0, min(sw, rx0 + snw))
            score = I[ry1, rx1] - I[ry0, rx1] - I[ry1, rx0] + I[ry0, rx0]
            if score > best_score:
                best_score = score
                best_nx0 = cand_x
        return (best_nx0, ny0, best_nx0 + nw, ny0 + nh)

    # 垂直单轴滑动（如原图太高需裁上下）
    if max_y > y0 and max_x <= x0:
        nx0 = x0
        step = max(1, int(round(1.0 / sy)))
        candidates = list(range(y0, max_y + 1, step))
        if candidates[-1] != max_y:
            candidates.append(max_y)

        rx0 = max(0, min(sw, int(round(x0 * sx))))
        rx1 = max(0, min(sw, rx0 + snw))

        best_score = -1.0
        best_ny0 = y0 + (h - nh) // 2

        for cand_y in candidates:
            ry0 = max(0, min(sh, int(round(cand_y * sy))))
            ry1 = max(0, min(sh, ry0 + snh))
            score = I[ry1, rx1] - I[ry0, rx1] - I[ry1, rx0] + I[ry0, rx0]
            if score > best_score:
                best_score = score
                best_ny0 = cand_y
        return (nx0, best_ny0, nx0 + nw, best_ny0 + nh)

    # 双轴滑动
    step_x = max(1, int(round(1.0 / sx)))
    step_y = max(1, int(round(1.0 / sy)))
    cands_x = list(range(x0, max_x + 1, step_x))
    if cands_x[-1] != max_x:
        cands_x.append(max_x)
    cands_y = list(range(y0, max_y + 1, step_y))
    if cands_y[-1] != max_y:
        cands_y.append(max_y)

    best_score = -1.0
    best_nx0 = x0 + (w - nw) // 2
    best_ny0 = y0 + (h - nh) // 2
    for cand_y in cands_y:
        ry0 = max(0, min(sh, int(round(cand_y * sy))))
        ry1 = max(0, min(sh, ry0 + snh))
        for cand_x in cands_x:
            rx0 = max(0, min(sw, int(round(cand_x * sx))))
            rx1 = max(0, min(sw, rx0 + snw))
            score = I[ry1, rx1] - I[ry0, rx1] - I[ry1, rx0] + I[ry0, rx0]
            if score > best_score:
                best_score = score
                best_nx0 = cand_x
                best_ny0 = cand_y
    return (best_nx0, best_ny0, best_nx0 + nw, best_ny0 + nh)


def resize_short(img, short_target):
    """仅缩小：使短边 <= short_target，不放大。"""
    w, h = img.size
    s = min(w, h)
    if s <= short_target:
        return img
    scale = short_target / s
    nw = max(1, int(round(w * scale)))
    nh = max(1, int(round(h * scale)))
    return img.resize((nw, nh), Image.LANCZOS)


def select_aspect(content_aspect, ratio_pool=None):
    """从比例池中选择最接近 content_aspect 的项。"""
    pool = ratio_pool if ratio_pool else build_ratio_pool()
    best_val, best_label = min(pool, key=lambda p: abs(p[0] - content_aspect))
    return best_val, best_label


def safe_out_path(out_dir, rel_path, stem, ext, overwrite=False, suffix="-cropped"):
    """生成输出路径（文件名带指定后缀，如 -cropped 或 -smart-cropped）。overwrite=True 时直接覆盖同名输出。"""
    base = os.path.join(out_dir, rel_path)
    candidate = os.path.join(base, f"{stem}{suffix}{ext}")
    if overwrite:
        return candidate
    if not os.path.exists(candidate):
        return candidate
    i = 1
    while True:
        cand = os.path.join(base, f"{stem}{suffix}_{i}{ext}")
        if not os.path.exists(cand):
            return cand
        i += 1


def process_file(in_path, out_dir, fmt, quality, forced_aspect, short_target,
                 no_trim, trim_tol, margin_frac, recursive_report, overwrite=False, win=4,
                 detector="std", pad=16, smart=False, ratio_pool=None):
    im = load_image(in_path)
    W, H = im.size
    content_box = (0, 0, W, H) if no_trim else compute_content_box(
        im, trim_tol=trim_tol, margin_frac=margin_frac, win=win, detector=detector, pad=pad)
    cw = content_box[2] - content_box[0]
    ch = content_box[3] - content_box[1]
    content_aspect = (cw / ch) if ch else 1.0

    if forced_aspect:
        target, label = forced_aspect
    else:
        target, label = select_aspect(content_aspect, ratio_pool=ratio_pool)

    if smart:
        crop_box = smart_aspect_crop_box(im, content_box, target)
    else:
        crop_box = aspect_crop_box(content_box, target)

    cropped = im.crop(crop_box)
    out = resize_short(cropped, short_target)

    if fmt == "jpg":
        if out.mode in ("RGBA", "LA"):
            bg = Image.new("RGB", out.size, (255, 255, 255))
            bg.paste(out, mask=out.split()[-1])
            out = bg
        else:
            out = out.convert("RGB")
        ext = ".jpg"
        save_kwargs = {"quality": quality, "optimize": True, "subsampling": "4:2:2"}
    else:  # png
        if out.mode == "P":
            out = out.convert("RGBA")
        ext = ".png"
        save_kwargs = {"optimize": True}

    rel = recursive_report
    suffix = "-smart-cropped" if smart else "-cropped"
    out_path = safe_out_path(out_dir, rel, os.path.splitext(os.path.basename(in_path))[0], ext, overwrite, suffix=suffix)

    info = {
        "input": in_path,
        "output": out_path,
        "orig_size": f"{W}x{H}",
        "content_box": f"{content_box[0]},{content_box[1]},{content_box[2]},{content_box[3]}",
        "crop_box": f"{crop_box[0]},{crop_box[1]},{crop_box[2]},{crop_box[3]}",
        "target_ratio": label,
        "mode": "smart" if smart else "center",
        "out_size": f"{out.size[0]}x{out.size[1]}",
        "format": fmt,
    }
    return out, out_path, save_kwargs, info


def iter_images(input_dir, recursive):
    exts = (".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tif", ".tiff", ".gif")
    if recursive:
        for root, _, files in os.walk(input_dir):
            for f in files:
                if f.lower().endswith(exts):
                    yield root, f
    else:
        for f in os.listdir(input_dir):
            if f.lower().endswith(exts) and os.path.isfile(os.path.join(input_dir, f)):
                yield input_dir, f


def main():
    ap = argparse.ArgumentParser(
        description="图片智能裁切与规格化：去背景裁切 + 比例裁切 + 缩放。",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("input_dir", help="输入图片目录")
    ap.add_argument("output_dir", nargs="?", default=None,
                    help="输出目录（不指定则输出到源目录，文件名加 -cropped 或 -smart-cropped 后缀）")
    ap.add_argument("--format", choices=["jpg", "png"], default="jpg", help="输出格式 (默认 jpg)")
    ap.add_argument("--quality", type=int, default=85, help="jpg 质量 1-100 (默认 85)")
    ap.add_argument("--aspect", type=parse_aspect, default=None,
                    help="强制输出长宽比，如 3:4 / 4:3 / 16:9（不指定则自动选择）")
    ap.add_argument("--smart", action="store_true",
                    help="启用主体感知智能裁切：基于显著性能量分布自动寻找最佳窗口，避免偏侧主体被裁 (默认: 居中)")
    ap.add_argument("--ratios", type=parse_ratios, default=None,
                    help="自动选择时的基础候选比例列表，逗号分隔，如 '2:3,1:1' 或 '2:3,1:1,4:3' (默认: '2:3,1:1')")
    ap.add_argument("--short", type=int, default=1600, help="短边目标长度，<=1600 不放大 (默认 1600)")
    ap.add_argument("--no-trim", action="store_true", help="跳过背景裁切（仅做比例裁切+缩放）")
    ap.add_argument("--detector", choices=["std", "usm"], default="std",
                    help="背景检测算法：std=局部标准差(默认,鲁棒已校准); "
                         "usm=反向锐化细节层 D=|I-GaussianBlur(I)|(对平滑渐变更敏感)")
    ap.add_argument("--trim-tol", type=float, default=None,
                    help="相对背景基线的额外对比度阈值(0-255)：越小越保守、留得越多；越大裁得越多 "
                         "(默认：usm=8, std=12)")
    ap.add_argument("--win", type=int, default=4,
                    help="局部对比度/高斯模糊半径(px)，约 2*win+1 见方，默认 4(≈9x9)")
    ap.add_argument("--pad", type=int, default=16,
                    help="背景裁切后向外的留白像素(px)：拼图素材需在主体四周留余量，避免碎片顶到裁切边 (默认 16)")
    ap.add_argument("--margin", type=float, default=0.0,
                    help="背景裁切后的安全内边距比例 0-0.1，可略微内收避免切到主体抗锯齿边缘 (默认 0)")
    ap.add_argument("--no-recursive", action="store_true", help="不递归子目录")
    ap.add_argument("--dry-run", action="store_true", help="只分析并报告，不写出文件")
    args = ap.parse_args()

    # 依据检测器设定 trim-tol 默认值：usm 更敏感，默认 8；std 已校准，默认 12
    if args.trim_tol is None:
        args.trim_tol = 8.0 if args.detector == "usm" else 12.0
    if args.pad < 0:
        print("错误：--pad 必须 >= 0", file=sys.stderr)
        return 2

    if args.output_dir is None:
        args.output_dir = args.input_dir
    same_dir = os.path.abspath(args.output_dir) == os.path.abspath(args.input_dir)

    if not os.path.isdir(args.input_dir):
        print(f"错误：输入目录不存在: {args.input_dir}", file=sys.stderr)
        return 2
    if args.short < 1:
        print("错误：--short 必须 >= 1", file=sys.stderr)
        return 2
    if not (0 <= args.margin <= 0.1):
        print("错误：--margin 应在 0-0.1 之间", file=sys.stderr)
        return 2

    os.makedirs(args.output_dir, exist_ok=True)
    recursive = not args.no_recursive
    ratio_pool = build_ratio_pool(args.ratios) if args.ratios else None

    records = []
    ok = 0
    fail = 0
    ratio_labels = [label for _, label in (ratio_pool if ratio_pool else build_ratio_pool())]
    print(f"[{now_str()}] 开始处理：{args.input_dir} -> {args.output_dir}")
    print(f"  格式={args.format} 质量={args.quality} 短边<={args.short} "
          f"强制比例={args.aspect[1] if args.aspect else '自动'} "
          f"裁切模式={'主体智能感知(smart)' if args.smart else '几何居中(center)'} "
          f"候选比例={', '.join(ratio_labels)} "
          f"背景裁切={'关' if args.no_trim else '开'}(detector={args.detector}, "
          f"tol={args.trim_tol}, win={args.win}, pad={args.pad}) 递归={recursive}")
    print("-" * 70)

    for root, fname in iter_images(args.input_dir, recursive):
        in_path = os.path.join(root, fname)
        # 跳过上一轮已生成的裁切输出文件，避免重复处理 / 二次裁切
        if fname.lower().endswith((".jpg", ".jpeg", ".png", ".webp",
                                   ".bmp", ".tif", ".tiff", ".gif")):
            if os.path.splitext(fname)[0].endswith(("-cropped", "-smart-cropped")):
                continue
        rel = os.path.relpath(root, args.input_dir) if recursive else ""
        try:
            out, out_path, save_kwargs, info = process_file(
                in_path, args.output_dir, args.format, args.quality,
                args.aspect, args.short, args.no_trim, args.trim_tol, args.margin, rel,
                same_dir, args.win, args.detector, args.pad,
                smart=args.smart, ratio_pool=ratio_pool,
            )
            if not args.dry_run:
                os.makedirs(os.path.dirname(out_path), exist_ok=True)
                out.save(out_path, **save_kwargs)
            records.append(info)
            ok += 1
            print(f"  [OK] {fname}: {info['orig_size']} -> 比例{info['target_ratio']} "
                  f"({info['mode']}) -> {info['out_size']}  {'(dry)' if args.dry_run else ''}")
        except Exception as e:  # noqa
            fail += 1
            print(f"  [FAIL] {fname}: {e}", file=sys.stderr)

    print("-" * 70)
    print(f"完成：成功 {ok}，失败 {fail}，共 {ok + fail}")

    if records:
        csv_path = os.path.join(args.output_dir, "report.csv")
        if not args.dry_run:
            try:
                with open(csv_path, "w", newline="", encoding="utf-8-sig") as f:
                    w = csv.DictWriter(f, fieldnames=["input", "output", "orig_size",
                                                      "content_box", "crop_box", "mode",
                                                      "target_ratio", "out_size", "format"])
                    w.writeheader()
                    w.writerows(records)
                print(f"报告已写入: {csv_path}")
            except Exception as e:
                print(f"报告写入失败: {e}", file=sys.stderr)
        else:
            print("(dry-run) 未写出 report.csv")

    return 0


if __name__ == "__main__":
    sys.exit(main())

