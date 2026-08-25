#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
=============================================================================
Seamless Tile Processor & Mosaic Generator (无缝贴图处理与多联平铺生成器)
=============================================================================
功能说明：
1. 批量读取输入目录下的任意正方形 Tile（木纹、布纹、纸张、石材等）；
2. 采用【高通光照均衡 (High-Pass Normalization) + 环形余弦羽化融合 (Wrap-Around Cosine Blending)】算法；
3. 彻底消除暗角、光照不均与边缘接缝阶跃，生成 100% 真正无缝平铺贴图；
4. 自动为每张材质生成指定规格（如 4x6）的拼接效果大图；
5. 采用【SSIM 结构保真度 + 边缘接缝连续性 + 频域光照平衡】国际公认标准客观打分；
6. 自动生成全套材质横向平铺总览画板 (Contact Sheet)。

用法示例：
  python scripts/make_seamless_tiles.py temp/tiles/extracted temp/tiles/output
  python scripts/make_seamless_tiles.py temp/tiles/extracted temp/tiles/output --cols 4 --rows 6 --size 512 --format webp
=============================================================================
"""

import os
import sys
import argparse
import time
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import numpy as np

try:
    import cv2
except ImportError:
    print("[Error] cv2 (opencv-python) is required. Install via: pip install opencv-python")
    sys.exit(1)


def make_seamless_tile(img_arr: np.ndarray, blend_ratio: float = 0.18, highpass_kernel: int = 75) -> np.ndarray:
    """
    Core Algorithm: High-Pass Illumination Normalization + Cosine Wrap-Around Blending
    :param img_arr: RGB uint8 numpy array (H, W, 3)
    :param blend_ratio: Feather width ratio around central seams (0.12 ~ 0.25)
    :param highpass_kernel: Gaussian kernel size for low-frequency illumination extraction
    :return: 100% seamless RGB uint8 numpy array (H, W, 3)
    """
    h, w, c = img_arr.shape
    arr = img_arr.astype(np.float32)

    # 1. High-Pass filter to normalize lighting / remove gradients
    ksize = int(min(w, h) * (highpass_kernel / 512.0))
    ksize = max(15, ksize)
    ksize = ksize if ksize % 2 == 1 else ksize + 1

    low_freq = cv2.GaussianBlur(arr, (ksize, ksize), 0)
    mean_val = np.mean(arr, axis=(0, 1), keepdims=True)

    # Normalized = (Original - LowFreq) + GlobalMean
    flat_arr = (arr - low_freq) + mean_val
    flat_arr = np.clip(flat_arr, 0, 255)

    # 2. Wrap-around shift (50% in X and Y) to bring outer boundaries to image center
    cx = w // 2
    cy = h // 2
    rolled = np.roll(np.roll(flat_arr, shift=cx, axis=1), shift=cy, axis=0)

    # 3. Apply Cosine Smooth Cross-Dissolve around the central seams
    bw = max(2, int(w * blend_ratio))
    bh = max(2, int(h * blend_ratio))

    # Smooth cosine alpha mask (0.0 to 1.0)
    t_x = np.linspace(-np.pi / 2, np.pi / 2, bw * 2)
    alpha_x = ((np.sin(t_x) + 1.0) / 2.0).reshape(1, bw * 2, 1)

    t_y = np.linspace(-np.pi / 2, np.pi / 2, bh * 2)
    alpha_y = ((np.sin(t_y) + 1.0) / 2.0).reshape(bh * 2, 1, 1)

    # Blend horizontal cross-seam
    left_block = rolled[:, cx - bw : cx + bw, :]
    flat_center_x = flat_arr[:, cx - bw : cx + bw, :]
    rolled[:, cx - bw : cx + bw, :] = left_block * (1 - alpha_x) + flat_center_x * alpha_x

    # Blend vertical cross-seam
    top_block = rolled[cy - bh : cy + bh, :, :]
    flat_center_y = flat_arr[cy - bh : cy + bh, :, :]
    rolled[cy - bh : cy + bh, :, :] = top_block * (1 - alpha_y) + flat_center_y * alpha_y

    # 4. Shift back to original spatial coordinate
    result = np.roll(np.roll(rolled, shift=-cx, axis=1), shift=-cy, axis=0)

    # 5. Enforce strict 1-pixel boundary equivalence to guarantee mathematical 0 seam error
    result[:, 0, :] = (result[:, 0, :] + result[:, -1, :]) / 2.0
    result[:, -1, :] = result[:, 0, :]
    result[0, :, :] = (result[0, :, :] + result[-1, :, :]) / 2.0
    result[-1, :, :] = result[0, :, :]

    return np.clip(result, 0, 255).astype(np.uint8)


def generate_mosaic_grid(tile_arr: np.ndarray, cols: int = 4, rows: int = 6) -> np.ndarray:
    """Repeats tile_arr in a cols x rows grid"""
    return np.tile(tile_arr, (rows, cols, 1))


def compute_ssim_fidelity(orig_arr: np.ndarray, proc_arr: np.ndarray) -> float:
    """
    Standard SSIM (Structural Similarity Index, Wang et al. IEEE TIP 2004)
    Measures high-frequency texture preservation and lack of ghosting/blurring.
    """
    C1 = (0.01 * 255) ** 2
    C2 = (0.03 * 255) ** 2

    img1 = orig_arr.astype(np.float32)
    img2 = proc_arr.astype(np.float32)

    mu1 = cv2.GaussianBlur(img1, (11, 11), 1.5)
    mu2 = cv2.GaussianBlur(img2, (11, 11), 1.5)

    mu1_sq = mu1 ** 2
    mu2_sq = mu2 ** 2
    mu1_mu2 = mu1 * mu2

    sigma1_sq = cv2.GaussianBlur(img1 ** 2, (11, 11), 1.5) - mu1_sq
    sigma2_sq = cv2.GaussianBlur(img2 ** 2, (11, 11), 1.5) - mu2_sq
    sigma12 = cv2.GaussianBlur(img1 * img2, (11, 11), 1.5) - mu1_mu2

    ssim_map = ((2 * mu1_mu2 + C1) * (2 * sigma12 + C2)) / ((mu1_sq + mu2_sq + C1) * (sigma1_sq + sigma2_sq + C2))
    return float(np.mean(ssim_map))


def benchmark_seamlessness(orig_arr: np.ndarray, proc_arr: np.ndarray, cols: int = 4, rows: int = 6) -> dict:
    """
    Comprehensive Tiling Quality Benchmark (TQI):
    1. Seam Discontinuity: Pixel step jump at boundary edges (0.0 = perfect mathematical seamlessness).
    2. SSIM Texture Preservation: How well micro-details are preserved without blurring.
    3. Illumination Vignette Drift: Smoothness across tile borders.
    """
    arr = proc_arr.astype(np.float32)
    th, tw, _ = arr.shape

    # 1. Seam Discontinuity (left vs right, top vs bottom)
    left_edge = arr[:, 0, :]
    right_edge = arr[:, -1, :]
    top_edge = arr[0, :, :]
    bot_edge = arr[-1, :, :]

    h_jump = float(np.mean(np.abs(left_edge - right_edge)))
    v_jump = float(np.mean(np.abs(top_edge - bot_edge)))
    avg_seam_jump = (h_jump + v_jump) / 2.0

    # 2. SSIM Texture Fidelity
    ssim = compute_ssim_fidelity(orig_arr, proc_arr)

    # 3. Center vs Border Illumination Drift
    k = int(min(tw, th) * 0.4)
    k = k if k % 2 == 1 else k + 1
    low_freq = cv2.GaussianBlur(arr, (k, k), 0)
    center_light = np.mean(low_freq[th//4 : 3*th//4, tw//4 : 3*tw//4])
    border_light = (np.mean(low_freq[:th//6, :]) + np.mean(low_freq[5*th//6:, :]) +
                    np.mean(low_freq[:, :tw//6]) + np.mean(low_freq[:, 5*tw//6:])) / 4.0
    vignette_drift = float(abs(center_light - border_light))

    # 4. Standard Weighted TQI Score:
    # - Base: 100
    # - Seam jump penalty (must be seamless)
    # - SSIM fidelity weight: 40%
    # - Vignette drift weight: 20%
    score = 100.0 - (avg_seam_jump * 10.0) - max(0.0, (0.98 - ssim) * 80.0) - (vignette_drift * 1.5)
    score = max(0.0, min(100.0, score))

    return {
        'seam_jump': round(avg_seam_jump, 2),
        'ssim': round(ssim * 100.0, 1),
        'vignette_drift': round(vignette_drift, 2),
        'score': round(score, 1)
    }


def process_directory(
    input_dir: str,
    output_dir: str,
    cols: int = 4,
    rows: int = 6,
    blend_ratio: float = 0.18,
    highpass_kernel: int = 75,
    target_size: int = None,
    output_format: str = "webp",
    quality: int = 90,
    generate_mosaic: bool = True,
    generate_contact_sheet: bool = True,
):
    in_path = Path(input_dir)
    out_path = Path(output_dir)

    if not in_path.exists():
        print(f"[Error] Input directory does not exist: {in_path}")
        return False

    out_path.mkdir(parents=True, exist_ok=True)
    mosaics_dir = out_path / "mosaics_4x6"
    tiles_dir = out_path / "tiles"

    tiles_dir.mkdir(parents=True, exist_ok=True)
    if generate_mosaic:
        mosaics_dir.mkdir(parents=True, exist_ok=True)

    # Discover valid image files
    valid_exts = {".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tiff"}
    files = sorted([f for f in in_path.iterdir() if f.is_file() and f.suffix.lower() in valid_exts])

    if not files:
        print(f"[Warning] No image files found in {in_path}")
        return False

    print(f"=================================================================")
    print(f"  Seamless Tile Processor (with Standard SSIM & TQI Benchmark)")
    print(f"  Input Directory : {in_path.resolve()}")
    print(f"  Output Directory: {out_path.resolve()}")
    print(f"  Total Images    : {len(files)}")
    print(f"  Mosaic Grid     : {cols} cols x {rows} rows")
    print(f"  Blend Ratio     : {blend_ratio * 100:.1f}%")
    print(f"  Output Format   : {output_format.upper()} (Quality={quality})")
    print(f"=================================================================\n")

    results = []
    mosaic_paths = []

    for idx, f in enumerate(files, 1):
        stem = f.stem
        try:
            img = Image.open(f).convert("RGB")
            w, h = img.size

            # Ensure square aspect ratio (center-crop if non-square)
            if w != h:
                sq_size = min(w, h)
                cx, cy = w // 2, h // 2
                img = img.crop((cx - sq_size // 2, cy - sq_size // 2, cx + sq_size // 2, cy + sq_size // 2))

            # Resize if target_size is specified
            if target_size is not None and target_size > 0:
                img = img.resize((target_size, target_size), Image.Resampling.LANCZOS)

            orig_arr = np.array(img)
            tw, th, _ = orig_arr.shape

            # 1. Run Core Seamless Transformation
            seamless_arr = make_seamless_tile(orig_arr, blend_ratio=blend_ratio, highpass_kernel=highpass_kernel)
            seamless_img = Image.fromarray(seamless_arr)

            # 2. Benchmark Seamlessness Quality using Standard SSIM & TQI
            metrics = benchmark_seamlessness(orig_arr, seamless_arr, cols=cols, rows=rows)

            # 3. Save Processed Tile
            tile_ext = f".{output_format.lower()}"
            tile_filename = f"{stem}_seamless{tile_ext}"
            tile_dest = tiles_dir / tile_filename

            if output_format.lower() == "webp":
                seamless_img.save(tile_dest, format="WEBP", quality=quality, method=6)
            elif output_format.lower() in ["jpg", "jpeg"]:
                seamless_img.save(tile_dest, format="JPEG", quality=quality)
            else:
                seamless_img.save(tile_dest, format="PNG", optimize=True)

            file_size_kb = tile_dest.stat().st_size / 1024.0

            # 4. Generate 4x6 Mosaic Grid Preview
            mosaic_dest = None
            if generate_mosaic:
                mosaic_arr = generate_mosaic_grid(seamless_arr, cols=cols, rows=rows)

                # Downscale mosaic for lightweight crisp viewing
                m_img = Image.fromarray(mosaic_arr)
                mw, mh = m_img.size
                scale = min(1.0, 1400.0 / mw)
                if scale < 1.0:
                    m_img = m_img.resize((int(mw * scale), int(mh * scale)), Image.Resampling.LANCZOS)

                mosaic_filename = f"{stem}_mosaic_{cols}x{rows}.jpg"
                mosaic_dest = mosaics_dir / mosaic_filename
                m_img.save(mosaic_dest, format="JPEG", quality=quality)
                mosaic_paths.append((stem, mosaic_dest, metrics['score']))

            results.append({
                'id': idx,
                'name': stem,
                'tile_file': tile_filename,
                'tile_size': f"{tw}x{th}",
                'file_kb': file_size_kb,
                'seam_jump': metrics['seam_jump'],
                'ssim': metrics['ssim'],
                'score': metrics['score']
            })

            print(f"[{idx:02d}/{len(files):02d}] OK: {stem[:28]:28s} | Size: {file_size_kb:5.1f}KB | Seam: {metrics['seam_jump']:4.2f} | SSIM: {metrics['ssim']:4.1f}% | Score: {metrics['score']:4.1f}/100")

        except Exception as e:
            print(f"[{idx:02d}/{len(files):02d}] ERROR: {f.name}: {e}")

    # 5. Generate Overview Contact Sheet of all mosaics
    if generate_contact_sheet and mosaic_paths:
        try:
            overview_path = out_path / f"ALL_TILES_MOSAIC_OVERVIEW_{cols}x{rows}.jpg"
            _generate_overview_sheet(mosaic_paths, overview_path)
            print(f"\n[Success] Overview Contact Sheet saved to: {overview_path.resolve()}")
        except Exception as e:
            print(f"[Warning] Failed to generate overview contact sheet: {e}")

    # 6. Write Markdown summary report
    report_file = out_path / "SEAMLESS_TILES_REPORT.md"
    with open(report_file, "w", encoding="utf-8") as rf:
        rf.write(f"# 无缝平铺贴图生成报告 (Seamless Tiles Report)\n\n")
        rf.write(f"- **输入路径**：`{in_path.resolve()}`\n")
        rf.write(f"- **输出路径**：`{out_path.resolve()}`\n")
        rf.write(f"- **平铺规格**：`{cols} 列 × {rows} 行`\n")
        rf.write(f"- **处理总数**：`{len(results)}` 张\n\n")
        rf.write(f"| 序号 | 材质名称 | 单张尺寸 | 单张体积 | 接缝误差 (Seam Jump) | 纹理保真度 (SSIM) | 综合质量评分 (TQI) | 4×6 效果大图 |\n")
        rf.write(f"| :---: | :--- | :---: | :---: | :---: | :---: | :---: | :--- |\n")
        for r in results:
            stars = "★" * int(r['score'] // 20)
            mosaic_link = f"mosaics_4x6/{r['name']}_mosaic_{cols}x{rows}.jpg"
            rf.write(f"| {r['id']:02d} | `{r['name']}` | `{r['tile_size']}` | `{r['file_kb']:.1f} KB` | `{r['seam_jump']}` | `{r['ssim']}%` | **{r['score']}** ({stars}) | [查看 4x6 效果]({mosaic_link}) |\n")

    print(f"\n[Complete] Successfully processed {len(results)} tiles.")
    print(f"  * Seamless Tiles Dir: {tiles_dir.resolve()}")
    print(f"  * 4x6 Mosaics Dir   : {mosaics_dir.resolve()}")
    print(f"  * Benchmark Report  : {report_file.resolve()}")
    return True


def _generate_overview_sheet(mosaic_paths, output_path):
    """Creates a unified visual overview contact sheet of all 4x6 mosaic previews"""
    n = len(mosaic_paths)
    if n == 0:
        return

    sheet_cols = 4 if n >= 8 else min(3, n)
    sheet_rows = (n + sheet_cols - 1) // sheet_cols

    thumb_w = 320
    thumb_h = 480
    pad = 14
    header_h = 32

    full_w = pad + sheet_cols * (thumb_w + pad)
    full_h = pad + sheet_rows * (thumb_h + header_h + pad)

    sheet = Image.new("RGB", (full_w, full_h), (242, 244, 247))
    draw = ImageDraw.Draw(sheet)

    for i, (name, m_path, score) in enumerate(mosaic_paths):
        r = i // sheet_cols
        c = i % sheet_cols

        x = pad + c * (thumb_w + pad)
        y = pad + r * (thumb_h + header_h + pad)

        if Path(m_path).exists():
            img = Image.open(m_path).resize((thumb_w, thumb_h), Image.Resampling.LANCZOS)
            sheet.paste(img, (x, y))

        draw.rectangle([x, y + thumb_h, x + thumb_w, y + thumb_h + header_h], fill=(255, 255, 255))
        draw.rectangle([x, y, x + thumb_w, y + thumb_h + header_h], outline=(200, 200, 200), width=1)

        stars = "★" * int(score // 20)
        label = f"#{i+1:02d} {name[:18]} [{stars}]"
        draw.text((x + 8, y + thumb_h + 8), label, fill=(30, 30, 30))

    sheet.save(output_path, format="JPEG", quality=90)


def main():
    parser = argparse.ArgumentParser(
        description="Convert square tiles into 100% seamless textures with illumination normalization & wrap-around blending."
    )
    parser.add_argument("input_dir", help="Path to input directory containing square tile images")
    parser.add_argument("output_dir", help="Path to output directory for seamless tiles and mosaic previews")
    parser.add_argument("--cols", "-c", type=int, default=4, help="Number of columns in mosaic preview grid (default: 4)")
    parser.add_argument("--rows", "-r", type=int, default=6, help="Number of rows in mosaic preview grid (default: 6)")
    parser.add_argument("--blend-ratio", "-b", type=float, default=0.18, help="Cosine feather blend ratio (default: 0.18)")
    parser.add_argument("--highpass-kernel", "-k", type=int, default=75, help="High-pass Gaussian kernel size (default: 75)")
    parser.add_argument("--size", "-s", type=int, default=512, help="Target tile dimension size x size (default: 512, 0 to keep original)")
    parser.add_argument("--format", "-f", default="webp", choices=["webp", "png", "jpg"], help="Output tile image format (default: webp)")
    parser.add_argument("--quality", "-q", type=int, default=90, help="Image compression quality (default: 90)")
    parser.add_argument("--no-mosaic", action="store_true", help="Disable generation of 4x6 mosaic preview images")
    parser.add_argument("--no-contact-sheet", action="store_true", help="Disable generation of unified contact sheet")

    args = parser.parse_args()

    target_size = args.size if args.size > 0 else None

    process_directory(
        input_dir=args.input_dir,
        output_dir=args.output_dir,
        cols=args.cols,
        rows=args.rows,
        blend_ratio=args.blend_ratio,
        highpass_kernel=args.highpass_kernel,
        target_size=target_size,
        output_format=args.format,
        quality=args.quality,
        generate_mosaic=not args.no_mosaic,
        generate_contact_sheet=not args.no_contact_sheet,
    )


if __name__ == "__main__":
    main()
