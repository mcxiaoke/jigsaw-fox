#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.core.crop_compute — 拼图素材几何/能量裁剪纯函数（无 IO，可复用）

供 `scripts/imgcrop.py`（独立 CLI 工具）与 `studio.core.image_proc.normalize_export_image`
-------- 共用同一份实现，避免双份维护。本模块只做"读入像素数组 → 计算裁窗/缩放"，
不负责文件读写与转码（那部分留在调用方）。

包含：
  - 去背景内容感知框定：compute_content_box / _windowed_std / _usm_detail
  - 比例裁窗：aspect_crop_box / smart_aspect_crop_box / compute_saliency_energy
  - 比例选择：select_aspect / build_ratio_pool / expand_ratio_family
  - 缩放：resize_short（短边≤目标）/ resize_long（长边=目标，只缩小）
"""

from __future__ import annotations

import numpy as np
from PIL import Image, ImageFilter


# 默认基础目标比例（竖屏朝向，程序会自动补充镜像朝向以支持横屏）
BASE_RATIOS = [(2, 3), (1, 1)]
# 用于内容检测与能量分析的小图最长边
ANALYSIS_LONG = 512
# 单条边最多裁掉的比例（防止误判把画面切没）
CAP_FRAC = 0.5


# ---------------------------------------------------------------------------
# 比例族与比例池
# ---------------------------------------------------------------------------

# 每个"比例族"的代表方向集合：UI 只给一个代表，横/竖朝向内部自适应
FAMILY_1X1 = [(1, 1)]
FAMILY_4X3 = [(4, 3), (3, 4)]
FAMILY_2X3 = [(2, 3), (3, 2)]

# auto 模式默认候选族（不含 2:3/3:2，手机上体验差，仅手动指定）
AUTO_FAMILIES = ("1:1", "4:3")

# 合法代表族 → 基础方向集合
FAMILY_MAP = {
    "1:1": FAMILY_1X1,
    "4:3": FAMILY_4X3,
    "2:3": FAMILY_2X3,
}


def expand_ratio_family(ratio: str) -> list[tuple[int, int]]:
    """把 UI 代表族（"1:1"/"4:3"/"2:3"）展开为完整基础方向集合（含横竖镜像）。

    非法值返回 []。
    """
    return list(FAMILY_MAP.get(str(ratio).strip(), ()))  # noqa: C410


def expand_ratio_families(ratios) -> list[tuple[int, int]]:
    """把一组代表族展开成去重后的完整基础方向集合；含 "auto" 时并入 AUTO_FAMILIES。"""
    base: list[tuple[int, int]] = []
    seen: set[tuple[int, int]] = set()
    fams = set()
    for r in ratios or ():
        r = str(r).strip()
        if r.lower() == "auto":
            fams.update(AUTO_FAMILIES)
        else:
            fams.add(r)
    for fam in fams:
        for a, b in expand_ratio_family(fam):
            if (a, b) not in seen:
                seen.add((a, b))
                base.append((a, b))
    return base


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


def select_aspect(content_aspect, ratio_pool=None):
    """从比例池中选择最接近 content_aspect 的项。"""
    pool = ratio_pool if ratio_pool else build_ratio_pool()
    best_val, best_label = min(pool, key=lambda p: abs(p[0] - content_aspect))
    return best_val, best_label


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

    tt = march(row, sh, base_top, cap_v)          # 上
    tb = march(row[::-1], sh, base_bot, cap_v)    # 下
    tl = march(col, sw, base_left, cap_h)         # 左
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


def resize_long(img, long_target):
    """仅缩小：使长边（max(w,h) = long_target，不放大。

    designed for 长边固定 2160 的导出规格化；原图长边已 ≤ long_target 时原样返回
    （只缩小不放大，不凭空造像素）。
    """
    w, h = img.size
    long_side = max(w, h)
    if long_side <= long_target:
        return img
    scale = long_target / long_side
    nw = max(1, int(round(w * scale)))
    nh = max(1, int(round(h * scale)))
    return img.resize((nw, nh), Image.LANCZOS)