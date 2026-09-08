#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.core.quality_evaluator — Content Studio 拼图物理质检与智能裁剪评估引擎
支持 8x8 切片死区、边框/核心加权、清晰度/色彩熵、四周裁切建议及优雅降级。
"""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any
import logging

logger = logging.getLogger(__name__)

# 解决 Windows 控制台与管道中文字符编码
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception as e:
        logger.debug("无法重配置标准流编码 (win32): %s", e)

# 备用 Python 虚拟环境解释器（预装 opencv-python / numpy）
VENV_PYTHON = Path(r"C:\Home\Develop\venv\Scripts\python.exe")

# 检查当前进程是否已具备 cv2 和 numpy
try:
    import cv2
    import numpy as np
    from PIL import Image, ImageOps

    from studio.core.crop_compute import (
        AUTO_FAMILIES,
        build_ratio_pool,
        compute_content_box,
        expand_ratio_families,
        select_aspect,
        smart_aspect_crop_box,
    )

    # 质检候选比例池: 与导出侧 AUTO_FAMILIES 一致 (1:1 + 4:3, 含横竖镜像)
    QUALITY_EVAL_RATIO_POOL = build_ratio_pool(
        expand_ratio_families(list(AUTO_FAMILIES))
    )

    HAS_CV2 = True
except ImportError:
    HAS_CV2 = False
    try:
        from PIL import Image, ImageOps, ImageStat

        HAS_PIL = True
    except ImportError:
        HAS_PIL = False


# ==============================================================================
# OpenCV 核心物理质检评估器 (In-Process)
# ==============================================================================


class PhysicalEvaluator:
    """基于 OpenCV 的物理特征与死区切片评估器"""

    def __init__(
        self, grid_rows: int = 8, grid_cols: int = 8, eval_max_dim: int = 640
    ) -> None:
        self.grid_rows = grid_rows
        self.grid_cols = grid_cols
        self.eval_max_dim = eval_max_dim

    def evaluate_path(self, img_path: Path | str) -> dict[str, Any]:
        p = Path(img_path)
        if not p.is_file():
            return self._empty_result(f"文件不存在: {p.name}")

        try:
            # 安全读取并校正 EXIF 旋转
            with open(p, "rb") as f:
                raw_bytes = f.read()

            pil_img = Image.open(io.BytesIO(raw_bytes))
            pil_img = ImageOps.exif_transpose(pil_img)
            if pil_img.mode != "RGB":
                pil_img = pil_img.convert("RGB")

            orig_w, orig_h = pil_img.size
            if orig_w < 64 or orig_h < 64:
                return self._empty_result("分辨率过小，无法进行拼图质检")

            # Smart crop: 模拟导出管线, 按 1:1+2:3 ratio 计算裁切框
            smart_crop_info = self._compute_smart_crop(pil_img)

            rgb_arr = np.array(pil_img)
            bgr_arr = cv2.cvtColor(rgb_arr, cv2.COLOR_RGB2BGR)

            return self.evaluate_image_bgr(
                bgr_arr,
                orig_w=orig_w,
                orig_h=orig_h,
                smart_crop_info=smart_crop_info,
            )
        except Exception as e:
            return self._empty_result(f"图像评估异常: {e}")

    def evaluate_image_bgr(
        self,
        bgr_arr: np.ndarray,
        orig_w: int,
        orig_h: int,
        smart_crop_info: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        h, w = bgr_arr.shape[:2]
        # 降采样加速
        if max(h, w) > self.eval_max_dim:
            scale = self.eval_max_dim / max(h, w)
            new_w, new_h = max(int(w * scale), 1), max(int(h * scale), 1)
            eval_img = cv2.resize(bgr_arr, (new_w, new_h), interpolation=cv2.INTER_AREA)
        else:
            eval_img = bgr_arr

        eval_h, eval_w = eval_img.shape[:2]
        gray = cv2.cvtColor(eval_img, cv2.COLOR_BGR2GRAY)
        hsv = cv2.cvtColor(eval_img, cv2.COLOR_BGR2HSV)

        # 梯度与清晰度
        laplacian_var = float(cv2.Laplacian(gray, cv2.CV_64F).var())
        sobel_x = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3)
        sobel_y = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)
        grad_mag = cv2.magnitude(sobel_x, sobel_y)

        # 8x8 网格分析
        (
            grid_matrix,
            total_dead_ratio,
            core_dead_ratio,
            border_dead_ratio,
            flat_ratio,
            spatial_balance,
        ) = self._analyze_grid(gray, grad_mag, eval_h, eval_w)

        # 色彩熵与调色板
        color_entropy, color_spread = self._analyze_color(hsv)
        palette_hex = self._extract_palette(eval_img, num_colors=5)

        # 裁剪建议与提分潜力
        crop_suggestion, can_upgrade, potential_score = self._evaluate_crop(
            grid_matrix,
            total_dead_ratio,
            core_dead_ratio,
            border_dead_ratio,
            orig_w,
            orig_h,
        )

        # 最大推荐切片档位
        max_grid_tier = self._recommend_max_grid(
            orig_w, orig_h, laplacian_var, core_dead_ratio
        )

        # 综合打分
        score, grade, status, diagnostics, score_boosted = self._compute_score(
            laplacian_var=laplacian_var,
            core_dead_ratio=core_dead_ratio,
            border_dead_ratio=border_dead_ratio,
            color_entropy=color_entropy,
            spatial_balance=spatial_balance,
            smart_crop_info=smart_crop_info,
        )

        # 若 smart crop 提分, 更新裁切建议为精确描述
        if smart_crop_info:
            cw_val = smart_crop_info.get("crop_w", 0)
            ch_val = smart_crop_info.get("crop_h", 0)
            ratio_label = smart_crop_info.get("crop_ratio", "")
            ss_val = smart_crop_info.get("subject_short_side", 0)
            crop_suggestion = (
                f"\u2702\ufe0f \u5efa\u8bae {ratio_label} \u88c1\u5207 \u2192 "
                f"{cw_val}\u00d7{ch_val}px (\u4e3b\u4f53\u77ed\u8fb9{ss_val}px)"
            )
            if score_boosted:
                can_upgrade = True

        return {
            "score": score,
            "grade": grade,
            "status": status,
            "dead_zone_ratio": round(total_dead_ratio, 3),
            "core_dead_ratio": round(core_dead_ratio, 3),
            "border_dead_ratio": round(border_dead_ratio, 3),
            "flat_zone_ratio": round(flat_ratio, 3),
            "crop_suggestion": crop_suggestion,
            "can_upgrade": can_upgrade,
            "potential_score": potential_score,
            "max_grid": max_grid_tier,
            "details": {
                "laplacian_var": round(laplacian_var, 1),
                "color_entropy": round(color_entropy, 2),
                "color_spread": round(color_spread, 2),
                "spatial_balance": round(spatial_balance, 1),
                "palette_hex": palette_hex,
                "diagnostics": diagnostics,
                "grid_rows": self.grid_rows,
                "grid_cols": self.grid_cols,
                "grid_matrix": grid_matrix,
                # Smart crop 字段 (旧缓存为空, 前端兼容)
                "crop_box": smart_crop_info.get("crop_box")
                if smart_crop_info
                else None,
                "content_box": smart_crop_info.get("content_box")
                if smart_crop_info
                else None,
                "crop_ratio": smart_crop_info.get("crop_ratio")
                if smart_crop_info
                else None,
                "subject_short_side": smart_crop_info.get("subject_short_side")
                if smart_crop_info
                else None,
                "crop_w": smart_crop_info.get("crop_w") if smart_crop_info else None,
                "crop_h": smart_crop_info.get("crop_h") if smart_crop_info else None,
                "score_boosted": score_boosted,
            },
        }

    def _analyze_grid(
        self, gray: np.ndarray, grad_mag: np.ndarray, h: int, w: int
    ) -> tuple[list[list[dict[str, Any]]], float, float, float, float, float]:
        cell_h = h // self.grid_rows
        cell_w = w // self.grid_cols
        matrix: list[list[dict[str, Any]]] = []
        cell_variances: list[float] = []

        total_dead_count = 0
        core_dead_count = 0
        border_dead_count = 0
        flat_count = 0

        total_cells = self.grid_rows * self.grid_cols
        core_cells = (self.grid_rows - 2) * (self.grid_cols - 2)
        border_cells = total_cells - core_cells

        for r in range(self.grid_rows):
            row_list = []
            for c in range(self.grid_cols):
                y1, y2 = r * cell_h, (r + 1) * cell_h if r < self.grid_rows - 1 else h
                x1, x2 = c * cell_w, (c + 1) * cell_w if c < self.grid_cols - 1 else w

                cell_gray = gray[y1:y2, x1:x2]
                cell_grad = grad_mag[y1:y2, x1:x2]

                var = float(np.var(cell_gray))
                edge_energy = float(np.mean(cell_grad))
                cell_variances.append(var)

                is_dead = var < 18.0 and edge_energy < 4.5
                is_flat = var < 45.0 and edge_energy < 8.0
                is_border = (
                    r == 0
                    or r == self.grid_rows - 1
                    or c == 0
                    or c == self.grid_cols - 1
                )

                if is_dead:
                    total_dead_count += 1
                    if is_border:
                        border_dead_count += 1
                    else:
                        core_dead_count += 1
                if is_flat:
                    flat_count += 1

                row_list.append(
                    {
                        "r": r,
                        "c": c,
                        "is_border": is_border,
                        "var": round(var, 1),
                        "edge": round(edge_energy, 1),
                        "is_dead": is_dead,
                        "is_flat": is_flat,
                    }
                )
            matrix.append(row_list)

        total_dead_ratio = total_dead_count / total_cells
        core_dead_ratio = core_dead_count / max(core_cells, 1)
        border_dead_ratio = border_dead_count / max(border_cells, 1)
        flat_ratio = flat_count / total_cells

        mean_var = float(np.mean(cell_variances) + 1e-5)
        cv_val = float(np.std(cell_variances) / mean_var)
        spatial_balance = float(np.clip(100 - cv_val * 35, 10, 100))

        return (
            matrix,
            total_dead_ratio,
            core_dead_ratio,
            border_dead_ratio,
            flat_ratio,
            spatial_balance,
        )

    def _analyze_color(self, hsv: np.ndarray) -> tuple[float, float]:
        h_channel = hsv[:, :, 0]
        s_channel = hsv[:, :, 1]
        valid_mask = s_channel > 25
        if np.count_nonzero(valid_mask) < 100:
            return 0.8, 15.0

        valid_hues = h_channel[valid_mask]
        hist, _ = np.histogram(valid_hues, bins=30, range=(0, 180))
        prob = hist / (hist.sum() + 1e-7)
        prob = prob[prob > 0]
        entropy = float(-np.sum(prob * np.log2(prob + 1e-7)))
        color_spread = float(np.mean(s_channel))
        return entropy, color_spread

    def _extract_palette(self, img_bgr: np.ndarray, num_colors: int = 5) -> list[str]:
        try:
            small = cv2.resize(img_bgr, (64, 64), interpolation=cv2.INTER_AREA)
            rgb_pixels = (
                cv2.cvtColor(small, cv2.COLOR_BGR2RGB).reshape(-1, 3).astype(np.float32)
            )
            criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 10, 1.0)
            flags = cv2.KMEANS_RANDOM_CENTERS
            _, _, centers = cv2.kmeans(rgb_pixels, num_colors, None, criteria, 3, flags)
            hex_colors = []
            for center in centers:
                r, g, b = np.clip(center.astype(int), 0, 255)
                hex_colors.append(f"#{r:02x}{g:02x}{b:02x}")
            return hex_colors
        except Exception:
            return ["#3b82f6", "#10b981", "#f59e0b", "#ef4444", "#6366f1"]

    def _compute_smart_crop(self, pil_img: Any) -> dict[str, Any] | None:
        """模拟导出管线的 smart crop, 按 1:1+2:3 ratio 计算裁切框.

        复用 crop_compute 的 compute_content_box -> select_aspect -> smart_aspect_crop_box,
        与导出侧算法完全一致, 保证质检评分与最终导出结果口径统一.

        Returns:
            dict with content_box, crop_box, crop_ratio, subject_short_side, crop_w, crop_h
            None if computation fails or modules unavailable.
        """
        try:
            W, H = pil_img.size
            content_box = compute_content_box(pil_img, detector="usm")
            if not content_box or len(content_box) != 4:
                return None
            cx0, cy0, cx1, cy1 = content_box
            cw, ch = cx1 - cx0, cy1 - cy0
            if cw <= 0 or ch <= 0:
                return None
            content_aspect = cw / ch
            target_val, target_label = select_aspect(
                content_aspect, QUALITY_EVAL_RATIO_POOL
            )
            crop_box = smart_aspect_crop_box(pil_img, content_box, target_val)
            bx0, by0, bx1, by1 = crop_box
            crop_w = int(bx1 - bx0)
            crop_h = int(by1 - by0)
            subject_short_side = min(crop_w, crop_h)
            return {
                "content_box": [int(cx0), int(cy0), int(cx1), int(cy1)],
                "crop_box": [int(bx0), int(by0), int(bx1), int(by1)],
                "crop_ratio": target_label,
                "subject_short_side": subject_short_side,
                "crop_w": crop_w,
                "crop_h": crop_h,
            }
        except Exception as e:
            logger.debug("[quality] smart crop compute failed: %s", e)
            return None

    def _evaluate_crop(
        self,
        grid_matrix: list[list[dict[str, Any]]],
        total_dead_ratio: float,
        core_dead_ratio: float,
        border_dead_ratio: float,
        orig_w: int,
        orig_h: int,
    ) -> tuple[str, bool, int]:
        if total_dead_ratio < 0.04:
            return "原图构图饱满，无需裁切", False, 0

        rows = len(grid_matrix)
        cols = len(grid_matrix[0]) if rows > 0 else 0
        if rows < 4 or cols < 4:
            return "尺寸适中", False, 0

        top_dead = sum(1 for c in range(cols) if grid_matrix[0][c]["is_dead"])
        bottom_dead = sum(1 for c in range(cols) if grid_matrix[rows - 1][c]["is_dead"])
        left_dead = sum(1 for r in range(rows) if grid_matrix[r][0]["is_dead"])
        right_dead = sum(1 for r in range(rows) if grid_matrix[r][cols - 1]["is_dead"])

        suggestions = []
        can_upgrade = False
        has_margin = max(orig_w, orig_h) >= 1600

        if top_dead >= cols * 0.6:
            suggestions.append("顶部裁切 10%~15% (纯色天空)")
            can_upgrade = True
        if bottom_dead >= cols * 0.6:
            suggestions.append("底部裁切 10% (死黑暗部)")
            can_upgrade = True
        if left_dead >= rows * 0.6 or right_dead >= rows * 0.6:
            suggestions.append("两侧微裁 (居中主体)")
            can_upgrade = True

        if can_upgrade and has_margin:
            potential = int(min(95, 75 + (1.0 - core_dead_ratio) * 20))
            return (
                f"建议{' + '.join(suggestions)}，适玩度可升至 ~{potential}分",
                True,
                potential,
            )
        elif core_dead_ratio > 0.15:
            return "内部核心存在大面积纯色死区，无法通过边缘裁剪消除", False, 0
        else:
            return "四周有少量平坦区，核心区域良好", False, 0

    def _recommend_max_grid(
        self, w: int, h: int, laplacian_var: float, core_dead_ratio: float
    ) -> str:
        max_dim = max(w, h)
        if max_dim >= 2500 and laplacian_var > 600 and core_dead_ratio <= 0.03:
            return "300 块 (20x15) / 225 块 (15x15) 宗师级"
        elif max_dim >= 1800 and laplacian_var > 300 and core_dead_ratio <= 0.08:
            return "100 块 (10x10) / 144 块 (12x12) 大师级"
        elif max_dim >= 1000 and core_dead_ratio <= 0.15:
            return "36 块 (6x6) / 64 块 (8x8) 标准进阶"
        else:
            return "16 块 (4x4) / 25 块 (5x5) 新手入门"

    def _compute_score(
        self,
        laplacian_var: float,
        core_dead_ratio: float,
        border_dead_ratio: float,
        color_entropy: float,
        spatial_balance: float,
        smart_crop_info: dict[str, Any] | None = None,
    ) -> tuple[int, str, str, list[str], bool]:
        diagnostics = []
        texture_score = np.clip(np.log10(laplacian_var + 1.0) / 3.5 * 35.0, 0, 35)
        color_score = np.clip((color_entropy / 4.0) * 30.0, 0, 30)
        balance_score = np.clip(spatial_balance * 0.35, 0, 35)
        base_score = texture_score + color_score + balance_score

        penalties = 0.0
        if core_dead_ratio > 0.02:
            penalties += (core_dead_ratio - 0.02) * 160.0
            if core_dead_ratio > 0.12:
                diagnostics.append(f"内部核心死区较多 ({core_dead_ratio * 100:.1f}%)")

        if border_dead_ratio > 0.10:
            penalties += (border_dead_ratio - 0.10) * 40.0
            if border_dead_ratio > 0.25:
                diagnostics.append(
                    f"四周边框存在单色区 ({border_dead_ratio * 100:.1f}%)"
                )

        if laplacian_var < 50.0:
            penalties += (50.0 - laplacian_var) * 0.5
            diagnostics.append(f"画面清晰度偏低/虚化 (Laplacian: {laplacian_var:.1f})")

        final_score = int(np.clip(base_score - penalties, 0, 100))
        score_boosted = False

        # Smart crop 提分: 边框死区高但裁切后主体完整且短边>=1200px
        if smart_crop_info:
            subject_ss = smart_crop_info.get("subject_short_side", 0)
            if (
                subject_ss >= 1200
                and border_dead_ratio >= 0.15
                and core_dead_ratio < 0.08
            ):
                boost = min(penalties * 0.6, 20)
                final_score = int(np.clip(final_score + boost, 0, 100))
                score_boosted = True
                ratio_label = smart_crop_info.get("crop_ratio", "")
                diagnostics.append(
                    f"Smart crop 提分: {ratio_label} 裁切后主体短边 {subject_ss}px, +{int(boost)}分"
                )

        if core_dead_ratio >= 0.22 or final_score < 45 or laplacian_var < 25.0:
            grade, status = "F", "FAIL"
        elif final_score >= 80 and core_dead_ratio <= 0.04:
            grade, status = "S", "PASS"
        elif final_score >= 68 and core_dead_ratio <= 0.08:
            grade, status = "A", "PASS"
        elif final_score >= 55 and core_dead_ratio <= 0.15:
            grade, status = "B", "WARN"
        else:
            grade, status = "C", "WARN"

        return final_score, grade, status, diagnostics, score_boosted

    def _empty_result(self, msg: str) -> dict[str, Any]:
        return {
            "score": 0,
            "grade": "F",
            "status": "FAIL",
            "dead_zone_ratio": 1.0,
            "core_dead_ratio": 1.0,
            "border_dead_ratio": 1.0,
            "flat_zone_ratio": 1.0,
            "crop_suggestion": msg,
            "can_upgrade": False,
            "potential_score": 0,
            "max_grid": "不支持",
            "details": {"diagnostics": [msg]},
        }


# ==============================================================================
# Pillow 优雅降级评估器 (No-OpenCV Fallback)
# ==============================================================================


def _evaluate_with_pillow(img_path: Path | str) -> dict[str, Any]:
    """若无法使用 OpenCV，使用 Pillow 纯 Python 计算网格方差与死区估算"""
    p = Path(img_path)
    if not p.is_file() or not HAS_PIL:
        return {
            "score": 50,
            "grade": "C",
            "status": "WARN",
            "dead_zone_ratio": 0.0,
            "core_dead_ratio": 0.0,
            "border_dead_ratio": 0.0,
            "flat_zone_ratio": 0.0,
            "crop_suggestion": "缺少图像质检引擎",
            "can_upgrade": False,
            "potential_score": 0,
            "max_grid": "未评估",
            "details": {"diagnostics": ["未安装 opencv-python，使用基础模式"]},
        }

    try:
        with open(p, "rb") as f:
            raw = f.read()
        im = Image.open(io.BytesIO(raw))
        im = ImageOps.exif_transpose(im)
        im = im.convert("RGB")
        w, h = im.size

        # 缩放到 640px
        max_dim = max(w, h)
        if max_dim > 640:
            scale = 640 / max_dim
            im = im.resize(
                (max(int(w * scale), 1), max(int(h * scale), 1)), Image.Resampling.BOX
            )
        rw, rh = im.size

        gray = im.convert("L")
        cell_w, cell_h = rw // 8, rh // 8
        dead_cells = 0
        core_dead = 0
        border_dead = 0

        matrix = []
        for r in range(8):
            row_list = []
            for c in range(8):
                x1, y1 = c * cell_w, r * cell_h
                x2 = (c + 1) * cell_w if c < 7 else rw
                y2 = (r + 1) * cell_h if r < 7 else rh
                cell = gray.crop((x1, y1, x2, y2))
                st = ImageStat.Stat(cell)
                var = st.var[0] if st.var else 0.0
                is_dead = var < 25.0
                is_border = r == 0 or r == 7 or c == 0 or c == 7
                if is_dead:
                    dead_cells += 1
                    if is_border:
                        border_dead += 1
                    else:
                        core_dead += 1
                row_list.append(
                    {"r": r, "c": c, "is_dead": is_dead, "var": round(var, 1)}
                )
            matrix.append(row_list)

        total_ratio = dead_cells / 64.0
        core_ratio = core_dead / 36.0
        border_ratio = border_dead / 28.0

        score = int(max(0, min(100, 85 - core_ratio * 120 - border_ratio * 30)))
        if core_ratio > 0.25 or score < 45:
            grade, status = "F", "FAIL"
        elif score >= 80 and core_ratio <= 0.05:
            grade, status = "S", "PASS"
        elif score >= 68:
            grade, status = "A", "PASS"
        else:
            grade, status = "B", "WARN"

        return {
            "score": score,
            "grade": grade,
            "status": status,
            "dead_zone_ratio": round(total_ratio, 3),
            "core_dead_ratio": round(core_ratio, 3),
            "border_dead_ratio": round(border_ratio, 3),
            "flat_zone_ratio": round(total_ratio, 3),
            "crop_suggestion": "边缘死区较少" if border_ratio < 0.2 else "建议四周裁切",
            "can_upgrade": border_ratio >= 0.25,
            "potential_score": min(90, score + 15) if border_ratio >= 0.25 else 0,
            "max_grid": "标准切片",
            "details": {
                "diagnostics": ["Pillow 基础模式估算"],
                "grid_rows": 8,
                "grid_cols": 8,
                "grid_matrix": matrix,
            },
        }
    except Exception as e:
        return {
            "score": 50,
            "grade": "C",
            "status": "WARN",
            "dead_zone_ratio": 0.0,
            "core_dead_ratio": 0.0,
            "border_dead_ratio": 0.0,
            "flat_zone_ratio": 0.0,
            "crop_suggestion": "",
            "can_upgrade": False,
            "potential_score": 0,
            "max_grid": "未评估",
            "details": {"diagnostics": [f"Pillow 评估异常: {e}"]},
        }


# ==============================================================================
# 环境感知统一评估入口 (Unified API)
# ==============================================================================


def evaluate_image(img_path: Path | str, eval_max_dim: int = 640) -> dict[str, Any]:
    """
    统一图像质检入口：
    1. 进程具备 cv2: 直接在进程内高效计算 (~15ms)
    2. 进程无 cv2 但检测到 venv Python: 唤起 venv 子进程使用完整 OpenCV 计算
    3. 均无: 使用 Pillow 计算降级指标，绝不崩溃
    """
    logger.debug("[quality] 评估单张: %s (HAS_CV2=%s)", img_path, HAS_CV2)
    if HAS_CV2:
        return PhysicalEvaluator(eval_max_dim=eval_max_dim).evaluate_path(img_path)

    # 尝试使用外部配置了 opencv 的 venv
    if VENV_PYTHON.is_file():
        try:
            cmd = [
                str(VENV_PYTHON),
                "-m",
                "studio.core.quality_evaluator",
                "--single",
                str(Path(img_path).resolve()),
            ]
            env = os.environ.copy()
            env["PYTHONIOENCODING"] = "utf-8"
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                env=env,
                timeout=10,
            )
            if proc.returncode == 0 and proc.stdout.strip():
                return json.loads(proc.stdout.strip())
        except Exception:
            pass

    # 降级至 Pillow
    return _evaluate_with_pillow(img_path)


def evaluate_images_batch(
    paths: list[Path | str],
    eval_max_dim: int = 640,
    max_workers: int | None = None,
) -> list[dict[str, Any]]:
    """
    批量评估列表，子批内并行。

    - HAS_CV2=True:  ThreadPool 并行 (OpenCV C 层释放 GIL，有真实并行收益)
    - HAS_CV2=False: 并行多个 venv 子进程 (subprocess.run 释放 GIL，ThreadPool 可并行等待)
    - 均无:          Pillow 串行降级
    """
    if not paths:
        return []

    logger.info("[quality] 批量质检开始: 共 %d 张", len(paths))

    workers = max_workers or max(4, (os.cpu_count() or 8) - 4)

    if HAS_CV2:
        evaluator = PhysicalEvaluator(eval_max_dim=eval_max_dim)
        with ThreadPoolExecutor(max_workers=workers) as pool:
            results = list(pool.map(evaluator.evaluate_path, paths))
        logger.info(
            "[quality] 批量质检完成: %d 张 (cv2 ThreadPool x%d)", len(results), workers
        )
        return results

    if VENV_PYTHON.is_file():
        return _evaluate_batch_parallel_subprocess(paths, eval_max_dim, workers)

    results = [_evaluate_with_pillow(p) for p in paths]
    logger.info("[quality] 批量质检完成: %d 张 (降级 Pillow 模式)", len(results))
    return results


def _evaluate_batch_parallel_subprocess(
    paths: list[Path | str],
    eval_max_dim: int,
    workers: int,
) -> list[dict[str, Any]]:
    """并行多个 venv 子进程，每个子进程处理一个 chunk"""
    chunk_size = max(1, len(paths) // workers)
    chunks = [paths[i : i + chunk_size] for i in range(0, len(paths), chunk_size)]

    def run_chunk(chunk: list[Path | str]) -> list[dict[str, Any]]:
        cmd = [
            str(VENV_PYTHON),
            "-m",
            "studio.core.quality_evaluator",
            "--batch",
        ]
        input_json = json.dumps(
            [str(Path(p).resolve()) for p in chunk], ensure_ascii=False
        )
        env = os.environ.copy()
        env["PYTHONIOENCODING"] = "utf-8"
        timeout = max(60, len(chunk) * 2)
        try:
            proc = subprocess.run(
                cmd,
                input=input_json,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                env=env,
                timeout=timeout,
            )
            if proc.returncode == 0 and proc.stdout.strip():
                return json.loads(proc.stdout.strip())
            logger.warning(
                "[quality] 子进程 chunk 失败 (rc=%d): %s",
                proc.returncode,
                proc.stderr[:200],
            )
        except subprocess.TimeoutExpired:
            logger.warning(
                "[quality] 子进程 chunk 超时 (%d 张, timeout=%ds)", len(chunk), timeout
            )
        except Exception as e:
            logger.warning("[quality] 子进程 chunk 异常: %s", e)
        return []

    with ThreadPoolExecutor(max_workers=len(chunks)) as pool:
        chunk_results = list(pool.map(run_chunk, chunks))

    results = [item for chunk in chunk_results for item in chunk]
    logger.info(
        "[quality] 批量质检完成: %d 张 (venv 子进程 x%d)", len(results), len(chunks)
    )
    return results


# ==============================================================================
# CLI Worker 模式 (供跨解释器或批处理调用)
# ==============================================================================

if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--single":
        target = sys.argv[2]
        evaluator = PhysicalEvaluator()
        res = evaluator.evaluate_path(target)
        print(json.dumps(res, ensure_ascii=False))
        sys.exit(0)
    elif len(sys.argv) >= 2 and sys.argv[1] == "--batch":
        try:
            input_data = sys.stdin.read()
            target_paths = json.loads(input_data)
            evaluator = PhysicalEvaluator()
            results = [evaluator.evaluate_path(p) for p in target_paths]
            print(json.dumps(results, ensure_ascii=False))
            sys.exit(0)
        except Exception as e:
            sys.stderr.write(f"Batch worker error: {e}\n")
            sys.exit(1)
    elif len(sys.argv) >= 2:
        target = sys.argv[1]
        evaluator = PhysicalEvaluator()
        res = evaluator.evaluate_path(target)
        print(json.dumps(res, ensure_ascii=False, indent=2))
