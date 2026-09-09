#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
质检可视化脚本 — 对输入目录的图片执行与 Studio 质检算法完全一致的分析，
将评级、分数、死区、裁切框等标注绘制在原图上，输出到指定目录。

支持多参数预设对比: 对每张图片输出多个不同参数档次的标注图，
方便观察 trim_tol / win / detector / pad / ratio 参数对 content_box 和 crop_box 的影响。

用法:
    # 单预设模式 (与质检算法默认参数一致)
    python scripts/quality_visualize.py <输入目录> <输出目录> [--limit N] [--workers W]

    # 多预设对比模式: 对每张图输出 5 个参数档次的标注图
    python scripts/quality_visualize.py <输入目录> <输出目录> --compare [--limit N]

    # content box 算法对比模式: 显式传入 --cbox-algs, 每张图只输出 _cbox.jpg 对比图 (不输出 _qc)
    python scripts/quality_visualize.py <输入目录> <输出目录> --cbox-algs usm12,std25,sal90 [--limit N]

示例:
    python scripts/quality_visualize.py F:/Images/JigsawData temp/quality_viz --compare --limit 10
    python scripts/quality_visualize.py F:/Images/JigsawData temp/quality_viz_cbox --cbox-algs usm12,std25,sal90 --limit 10

预设档次:
    default  — trim_tol=12, win=4,  detector=std, pad=16  (当前质检默认)
    loose    — trim_tol=6,  win=3,  detector=std, pad=24  (宽松,保留更多边缘)
    strict   — trim_tol=20, win=6,  detector=std, pad=8   (严格,裁掉更多背景)
    usm      — trim_tol=12, win=4,  detector=usm, pad=16  (USM检测器,对渐变更敏感)
    tight    — trim_tol=25, win=8,  detector=std, pad=4, margin_frac=0.02 (极严格+安全内收)

标注内容:
    - 绿色实线框: content_box (主体内容边界)
    - 红色虚线框: crop_box (smart crop 裁切框)
    - 8x8 网格: 死区格子标记 (灰色=死区, 橙色=平坦区)
    - 左上角面板: 评级/分数/死区/裁切信息/参数名
"""

from __future__ import annotations

import argparse
import io
import sys
import os
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

# 确保项目根目录在 sys.path 中
_project_root = Path(__file__).resolve().parent.parent
if str(_project_root) not in sys.path:
    sys.path.insert(0, str(_project_root))

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageOps

from studio.core.quality_evaluator import PhysicalEvaluator
from studio.core.crop_compute import (
    AUTO_FAMILIES,
    build_ratio_pool,
    compute_content_box,
    expand_ratio_families,
    fusion_content_box,
    saliency_content_box,
    select_aspect,
    smart_aspect_crop_box,
)

# 质检候选比例池: 与导出侧 AUTO_FAMILIES 一致
_RATIO_POOL = build_ratio_pool(expand_ratio_families(list(AUTO_FAMILIES)))

# ---------------------------------------------------------------------------
# 参数预设定义
# ---------------------------------------------------------------------------

PRESETS = {
    "default": {
        "desc": "trim_tol=12 win=4 usm pad=16",
        "params": dict(trim_tol=12.0, margin_frac=0.0, win=4, detector="usm", pad=16),
    },
    "loose": {
        "desc": "trim_tol=6 win=3 usm pad=24 (宽松)",
        "params": dict(trim_tol=6.0, margin_frac=0.0, win=3, detector="usm", pad=24),
    },
    "strict": {
        "desc": "trim_tol=20 win=6 usm pad=8 (严格)",
        "params": dict(trim_tol=20.0, margin_frac=0.0, win=6, detector="usm", pad=8),
    },
    "std": {
        "desc": "trim_tol=12 win=4 std pad=16 (旧默认)",
        "params": dict(trim_tol=12.0, margin_frac=0.0, win=4, detector="std", pad=16),
    },
    "tight": {
        "desc": "trim_tol=25 win=8 usm pad=4 margin=0.02 (极紧)",
        "params": dict(trim_tol=25.0, margin_frac=0.02, win=8, detector="usm", pad=4),
    },
}


# ---------------------------------------------------------------------------
# content box 算法集合 (用于 --cbox-algs 对比模式)
# ---------------------------------------------------------------------------

CONTENT_ALG_MAP = {
    "usm12": {
        "desc": "细节阈值 usm tol=12 pad=16 (现网)",
        "color": (59, 130, 246, 235),
        "fn": lambda img: compute_content_box(
            img, trim_tol=12.0, margin_frac=0.0, win=4, detector="usm", pad=16
        ),
    },
    "std25": {
        "desc": "细节阈值 std tol=25 win=8 pad=16",
        "color": (249, 115, 22, 235),
        "fn": lambda img: compute_content_box(
            img, trim_tol=25.0, margin_frac=0.0, win=8, detector="std", pad=16
        ),
    },
    "sal90": {
        "desc": "显著性能量 q=90 pad=24 (新算法)",
        "color": (16, 185, 129, 235),
        "fn": lambda img: saliency_content_box(img, q=90.0, pad=24),
    },
    "fusion": {
        "desc": "融合 std25∪sal90 逐边并集 (现网默认: 质检+导出)",
        "color": (168, 85, 247, 235),
        "fn": lambda img: fusion_content_box(img),
    },
}


def _get_font(size: int):
    """获取中文字体, 优先使用微软雅黑"""
    font_paths = [
        "C:/Windows/Fonts/msyh.ttc",
        "C:/Windows/Fonts/msyhbd.ttc",
        "C:/Windows/Fonts/simhei.ttf",
        "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
    ]
    for fp in font_paths:
        if Path(fp).exists():
            try:
                return ImageFont.truetype(fp, size)
            except Exception:
                continue
    return ImageFont.load_default()


def _compute_smart_crop_with_params(
    pil_img: Image.Image,
    preset_params: dict,
) -> dict | None:
    """用指定参数计算 smart crop, 返回与质检一致的 dict 结构"""
    try:
        W, H = pil_img.size
        content_box = compute_content_box(pil_img, **preset_params)
        if not content_box or len(content_box) != 4:
            return None
        cx0, cy0, cx1, cy1 = content_box
        cw, ch = cx1 - cx0, cy1 - cy0
        if cw <= 0 or ch <= 0:
            return None
        content_aspect = cw / ch
        target_val, target_label = select_aspect(content_aspect, _RATIO_POOL)
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
            "score_boosted": False,  # 由调用方填充
        }
    except Exception as e:
        print(f"  [smart crop error] {e}")
        return None


def _draw_dashed_rect(
    draw: ImageDraw.ImageDraw,
    box: tuple[int, int, int, int],
    color: tuple,
    width: int = 4,
    dash: int = 0,
) -> None:
    """画虚线矩形; dash=0 画实线"""
    x0, y0, x1, y1 = box
    if dash <= 0:
        draw.rectangle([x0, y0, x1, y1], outline=color, width=width)
        return
    gap = dash // 2
    for edge in ("top", "bottom", "left", "right"):
        if edge == "top":
            xs, y = x0, y0
            while xs < x1:
                xs2 = min(xs + dash, x1)
                draw.line([(xs, y), (xs2, y)], fill=color, width=width)
                xs += dash + gap
        elif edge == "bottom":
            xs, y = x0, y1
            while xs < x1:
                xs2 = min(xs + dash, x1)
                draw.line([(xs, y), (xs2, y)], fill=color, width=width)
                xs += dash + gap
        elif edge == "left":
            ys, x = y0, x0
            while ys < y1:
                ys2 = min(ys + dash, y1)
                draw.line([(x, ys), (x, ys2)], fill=color, width=width)
                ys += dash + gap
        elif edge == "right":
            ys, x = y0, x1
            while ys < y1:
                ys2 = min(ys + dash, y1)
                draw.line([(x, ys), (x, ys2)], fill=color, width=width)
                ys += dash + gap


def _draw_annotations(
    pil_img: Image.Image,
    result: dict,
    smart_crop_info: dict | None,
    preset_name: str,
    preset_desc: str,
) -> Image.Image:
    """在原图上绘制质检标注"""
    draw_img = pil_img.copy()
    draw = ImageDraw.Draw(draw_img, "RGBA")

    orig_w, orig_h = pil_img.size
    details = result.get("details", {})
    grid_matrix = details.get("grid_matrix", [])
    grid_rows = details.get("grid_rows", 8)
    grid_cols = details.get("grid_cols", 8)

    # --- 1. 绘制 8x8 网格死区标记 ---
    if (
        grid_matrix
        and len(grid_matrix) == grid_rows
        and len(grid_matrix[0]) == grid_cols
    ):
        cell_w = orig_w / grid_cols
        cell_h = orig_h / grid_rows
        for r in range(grid_rows):
            for c in range(grid_cols):
                cell = grid_matrix[r][c]
                x1 = int(c * cell_w)
                y1 = int(r * cell_h)
                x2 = int((c + 1) * cell_w)
                y2 = int((r + 1) * cell_h)
                if cell.get("is_dead"):
                    draw.rectangle([x1, y1, x2, y2], fill=(128, 128, 128, 40))
                elif cell.get("is_flat"):
                    draw.rectangle([x1, y1, x2, y2], fill=(255, 165, 0, 20))

        grid_color = (100, 100, 100, 30)
        for r in range(grid_rows + 1):
            y = int(r * cell_h)
            draw.line([(0, y), (orig_w, y)], fill=grid_color, width=1)
        for c in range(grid_cols + 1):
            x = int(c * cell_w)
            draw.line([(x, 0), (x, orig_h)], fill=grid_color, width=1)

    # --- 2. 绘制 content_box (绿色实线框) ---
    if smart_crop_info:
        content_box = smart_crop_info.get("content_box")
        if content_box and len(content_box) == 4:
            cx0, cy0, cx1, cy1 = content_box
            draw.rectangle([cx0, cy0, cx1, cy1], outline=(0, 255, 0, 200), width=3)
            font_cb = _get_font(max(14, orig_w // 80))
            draw.text(
                (cx0, max(0, cy0 - 22)),
                "content_box",
                fill=(0, 255, 0, 220),
                font=font_cb,
            )

    # --- 3. 绘制 crop_box (红色虚线框) ---
    if smart_crop_info:
        crop_box = smart_crop_info.get("crop_box")
        if crop_box and len(crop_box) == 4:
            bx0, by0, bx1, by1 = crop_box
            dash_len = max(8, orig_w // 200)
            _draw_dashed_rect(
                draw,
                (bx0, by0, bx1, by1),
                color=(255, 50, 50, 220),
                width=4,
                dash=dash_len,
            )

            crop_ratio = smart_crop_info.get("crop_ratio", "")
            crop_w_val = smart_crop_info.get("crop_w", 0)
            crop_h_val = smart_crop_info.get("crop_h", 0)
            ss_val = smart_crop_info.get("subject_short_side", 0)
            boosted = smart_crop_info.get("score_boosted", False)
            label_text = f"{crop_ratio} | {crop_w_val}x{crop_h_val}px | SS:{ss_val}"
            if boosted:
                label_text += " | BOOSTED"

            label_font = _get_font(max(16, orig_w // 60))
            bbox = draw.textbbox((0, 0), label_text, font=label_font)
            lw = bbox[2] - bbox[0] + 12
            lh = bbox[3] - bbox[1] + 8
            ly = max(0, by0 - lh - 4)
            draw.rectangle([bx0, ly, bx0 + lw, ly + lh], fill=(255, 50, 50, 220))
            draw.text(
                (bx0 + 6, ly + 2),
                label_text,
                fill=(255, 255, 255, 255),
                font=label_font,
            )

    # --- 4. 左上角信息面板 ---
    score = result.get("score", 0)
    grade = result.get("grade", "?")
    status = result.get("status", "")
    dead_zone = result.get("dead_zone_ratio", 0)
    core_dead = result.get("core_dead_ratio", 0)
    border_dead = result.get("border_dead_ratio", 0)
    flat_zone = result.get("flat_zone_ratio", 0)
    max_grid = result.get("max_grid", "")
    can_upgrade = result.get("can_upgrade", False)
    laplacian = details.get("laplacian_var", 0)
    color_entropy = details.get("color_entropy", 0)
    spatial_balance = details.get("spatial_balance", 0)
    diagnostics_list = details.get("diagnostics", [])

    info_lines = [
        f"[{preset_name}] {preset_desc}",
        f"Grade: {grade}  Score: {score}/100  [{status}]",
        f"Dead: {dead_zone * 100:.1f}%  Core: {core_dead * 100:.1f}%  Border: {border_dead * 100:.1f}%  Flat: {flat_zone * 100:.1f}%",
        f"Laplacian: {laplacian:.1f}  ColorEntropy: {color_entropy:.2f}  Balance: {spatial_balance:.1f}",
        f"Grid: {max_grid}",
    ]
    if can_upgrade:
        info_lines.append(
            f"CanUpgrade: YES (potential: {result.get('potential_score', 0)})"
        )
    for d in diagnostics_list:
        info_lines.append(f"  - {d}")

    info_font = _get_font(max(18, orig_w // 50))
    line_h = max(18, orig_w // 50) + 6
    panel_x = 10
    panel_y = 10

    max_text_w = 0
    for line in info_lines:
        bbox = draw.textbbox((0, 0), line, font=info_font)
        max_text_w = max(max_text_w, bbox[2] - bbox[0])

    panel_w = max_text_w + 20
    panel_h = len(info_lines) * line_h + 16

    grade_color_map = {
        "S": (20, 80, 20, 200),
        "A": (20, 60, 100, 200),
        "B": (60, 50, 20, 200),
        "C": (80, 40, 20, 200),
        "F": (100, 20, 20, 200),
    }
    panel_bg = grade_color_map.get(grade, (40, 40, 40, 200))
    draw.rectangle(
        [panel_x, panel_y, panel_x + panel_w, panel_y + panel_h], fill=panel_bg
    )

    for i, line in enumerate(info_lines):
        draw.text(
            (panel_x + 10, panel_y + 8 + i * line_h),
            line,
            fill=(255, 255, 255, 255),
            font=info_font,
        )

    return draw_img


def _draw_content_box_compare(
    pil_img: Image.Image,
    result: dict,
    alg_names: list[str],
) -> Image.Image:
    """同一张原图上叠加多个 content_box 算法框: 仅三色实线框 + 算法名标签。

    供 --cbox-algs 使用: 每个算法用不同颜色实线绘制 content_box, 框边带
    半透明底的算法名小标签; 无图例面板/描述/尺寸文字/参考线, 不遮挡内容。
    """
    draw_img = pil_img.copy()
    draw = ImageDraw.Draw(draw_img, "RGBA")
    orig_w, orig_h = pil_img.size

    # 各算法 content_box: 实线 + 框边算法名标签 (半透明底)
    box_font = _get_font(max(13, orig_w // 110))
    label_bg = (0, 0, 0, 105)
    for name in alg_names:
        alg = CONTENT_ALG_MAP[name]
        try:
            box = tuple(int(v) for v in alg["fn"](pil_img))
        except Exception:
            continue
        if len(box) != 4 or box[2] - box[0] < 8 or box[3] - box[1] < 8:
            continue
        x0, y0, x1, y1 = box
        draw.rectangle([x0, y0, x1, y1], outline=alg["color"], width=4)
        bbox = draw.textbbox((0, 0), name, font=box_font)
        lw = bbox[2] - bbox[0] + 8
        lh = bbox[3] - bbox[1] + 3
        if y0 - lh - 2 >= 0:
            ly = y0 - lh - 2
        else:
            ly = y0 + 2
        draw.rectangle([x0, ly, x0 + lw, ly + lh], fill=label_bg)
        draw.text((x0 + 4, ly), name, fill=alg["color"], font=box_font)

    return draw_img


def _process_one(
    img_path: Path,
    out_dir: Path,
    evaluator: PhysicalEvaluator,
    compare_mode: bool,
    cbox_algs: list[str] | None = None,
) -> str | None:
    """处理单张图片"""
    try:
        # 质检评分只算一次 (不依赖 crop 参数)
        result = evaluator.evaluate_path(img_path)
        if result.get("status") == "ERROR":
            return f"  [SKIP] {img_path.name}: {result.get('error', 'unknown')}"

        pil_img = Image.open(img_path)
        pil_img = ImageOps.exif_transpose(pil_img)
        if pil_img.mode != "RGB":
            pil_img = pil_img.convert("RGB")

        presets_to_run = list(PRESETS.keys()) if compare_mode else ["default"]

        # cbox 对比模式: 只输出 _cbox.jpg, 跳过 _qc 普通标注图
        if cbox_algs:
            compare_img = _draw_content_box_compare(pil_img, result, cbox_algs)
            cbox_out = out_dir / (img_path.stem + "_cbox" + img_path.suffix)
            compare_img.save(str(cbox_out), quality=92)
            return None

        for pname in presets_to_run:
            preset = PRESETS[pname]
            if pname == "default":
                # 用质检算法内部已算好的 smart_crop_info (保证一致性)
                smart_info = result.get("details", {}).get("crop_box")
                if smart_info:
                    # 从 details 重建 smart_crop_info dict
                    d = result["details"]
                    smart_crop_info = {
                        "content_box": d.get("content_box"),
                        "crop_box": d.get("crop_box"),
                        "crop_ratio": d.get("crop_ratio"),
                        "subject_short_side": d.get("subject_short_side"),
                        "crop_w": d.get("crop_w"),
                        "crop_h": d.get("crop_h"),
                        "score_boosted": d.get("score_boosted", False),
                    }
                else:
                    smart_crop_info = None
            else:
                # 用自定义参数重新计算
                smart_crop_info = _compute_smart_crop_with_params(
                    pil_img, preset["params"]
                )
                if smart_crop_info and result.get("details", {}).get("score_boosted"):
                    smart_crop_info["score_boosted"] = True

            annotated = _draw_annotations(
                pil_img, result, smart_crop_info, pname, preset["desc"]
            )
            suffix = f"_{pname}" if compare_mode else ""
            out_path = out_dir / (img_path.stem + f"_qc{suffix}" + img_path.suffix)
            annotated.save(str(out_path), quality=92)

        return None
    except Exception as e:
        return f"  [ERROR] {img_path.name}: {e}"


def main():
    parser = argparse.ArgumentParser(
        description="质检可视化: 对图片执行质检算法并绘制标注到原图, 支持多参数对比"
    )
    parser.add_argument("input_dir", help="输入图片目录")
    parser.add_argument("output_dir", help="输出标注图目录")
    parser.add_argument(
        "--limit", type=int, default=0, help="最多处理图片数量 (0=全部)"
    )
    parser.add_argument("--workers", type=int, default=4, help="并行线程数 (默认 4)")
    parser.add_argument(
        "--compare",
        action="store_true",
        help="多预设对比模式: 对每张图输出 5 个参数档次的标注图",
    )
    parser.add_argument(
        "--cbox-algs",
        default=None,
        help=(
            "content box 算法对比: 逗号分隔算法名, 显式传入才启用 — 每张图只输出 "
            "一张 _cbox.jpg 叠加对比图, 跳过 _qc 普通标注图 (空字符串=关闭; "
            "可选: usm12,std25,sal90)。不传此参数则保持普通 _qc 输出"
        ),
    )
    args = parser.parse_args()

    # 未显式传入 --cbox-algs 时关闭 cbox 模式 (仅保留普通 _qc 输出)
    cbox_names = [s.strip() for s in (args.cbox_algs or "").split(",") if s.strip()]
    unknown = [n for n in cbox_names if n not in CONTENT_ALG_MAP]
    if unknown:
        print(f"Error: unknown content box algorithm(s): {unknown}")
        sys.exit(1)

    in_dir = Path(args.input_dir)
    out_dir = Path(args.output_dir)

    if not in_dir.is_dir():
        print(f"Error: input directory not found: {in_dir}")
        sys.exit(1)

    out_dir.mkdir(parents=True, exist_ok=True)

    exts = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tiff"}
    images = sorted(
        [p for p in in_dir.rglob("*") if p.suffix.lower() in exts and p.is_file()]
    )

    if args.limit > 0:
        images = images[: args.limit]

    if not images:
        print(f"No images found in {in_dir}")
        sys.exit(0)

    mode_desc = "多预设对比 (5档)" if args.compare else "单预设 (默认参数)"
    print(f"Found {len(images)} images in {in_dir}")
    for p in images:
        print(f"  source: {p}")
    print(f"Output directory: {out_dir}")
    print(f"Mode: {mode_desc}")
    print(f"Workers: {args.workers}")
    print()

    evaluator = PhysicalEvaluator()

    done = 0
    errors = 0
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {
            pool.submit(
                _process_one, img, out_dir, evaluator, args.compare, cbox_names
            ): img
            for img in images
        }
        for fut in as_completed(futures):
            done += 1
            err = fut.result()
            if err:
                print(err)
                errors += 1
            if done % 5 == 0 or done == len(images):
                print(f"  [{done}/{len(images)}] processed: {futures[fut]}")

    print(f"\nDone: {done - errors}/{done} success, {errors} errors")
    print(f"Output: {out_dir}")


if __name__ == "__main__":
    main()
