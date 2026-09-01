#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Detect images with "too few colors" or "large flat / blur-gradient regions".

Detects two failure modes common in AI-generated puzzle source images:
  1. Color poverty      - unique color count far below normal photographic range.
  2. Flat / blur region - large contiguous areas of solid color or smooth gradient,
                          which make poor puzzle pieces (all pieces look identical).

Metrics:
  - unique_colors       : quantized distinct color count (per 8-level channel).
  - top_color_ratio     : fraction of pixels covered by the single most common color.
  - top10_color_ratio   : fraction covered by top-10 most common colors.
  - low_var_ratio       : fraction of 32x32 blocks with stddev < threshold (flat/blur).
  - edge_density        : fraction of pixels that are edges (Canny).
  - flat_region_ratio   : largest connected flat region as fraction of image.
  - verdict             : PASS / WARN / FAIL with reason(s).

Environment:
  Python venv:  C:\\Home\\Develop\\venv
  Dependencies: numpy, Pillow, opencv-python  (all pre-installed in the venv)
  Run with:     "C:/Home/Develop/venv/Scripts/python.exe" scripts/diagnose_images.py <dir>

Usage:
  # Scan a single directory
  "C:/Home/Develop/venv/Scripts/python.exe" scripts/diagnose_images.py C:/Home/Temp/JigsawDiag5

  # Scan recursively, output JSON + HTML report
  "C:/Home/Develop/venv/Scripts/python.exe" scripts/diagnose_images.py C:/Home/Temp/JigsawDiag5 --recursive --json report.json --html report.html

  # Adjust thresholds
  "C:/Home/Develop/venv/Scripts/python.exe" scripts/diagnose_images.py C:/Home/Temp/JigsawDiag5 \
      --min-colors 4096 --max-top1 0.15 --max-top10 0.55 --max-low-var 0.35 --min-edge 0.02
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import List, Optional

# --------------------------------------------------------------------------
# Encoding fix for Windows console
# --------------------------------------------------------------------------
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

import cv2
import numpy as np
from PIL import Image

# --------------------------------------------------------------------------
# Thresholds (defaults; overridable via CLI)
# --------------------------------------------------------------------------
DEFAULTS = {
    "min_colors": 1500,  # below this → color poverty (quant_levels=16 → 4096 max)
    "max_top1": 0.15,  # single color covers >15% → flat region likely
    "max_top10": 0.50,  # top-10 colors cover >50% → low diversity
    "max_low_var": 0.35,  # >35% blocks are low-variance → blur/flat
    "min_edge": 0.015,  # edge density <1.5% → likely blurry
    "quant_levels": 16,  # per-channel quantization (16 → 4096 colors max)
    "block_size": 32,  # block size for local variance analysis
    "flat_std_thresh": 3.0,  # stddev below this (0-255 scale) = flat block
}

SUPPORTED_EXT = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tiff", ".tif"}


# --------------------------------------------------------------------------
# Data model
# --------------------------------------------------------------------------
@dataclass
class ImageReport:
    path: str
    width: int = 0
    height: int = 0
    channels: int = 0

    unique_colors: int = 0
    top1_ratio: float = 0.0
    top10_ratio: float = 0.0

    low_var_ratio: float = 0.0
    edge_density: float = 0.0
    flat_region_ratio: float = 0.0

    verdict: str = "PASS"
    reasons: List[str] = field(default_factory=list)


# --------------------------------------------------------------------------
# Core analysis
# --------------------------------------------------------------------------


def _quantize(img_bgr: np.ndarray, levels: int = 8) -> np.ndarray:
    """Quantize to `levels` per channel, return as int32 packed for unique counting."""
    step = 256 // levels
    q = (img_bgr // step).astype(np.int32)
    # pack BGR into single int32
    packed = q[:, :, 0] + q[:, :, 1] * levels + q[:, :, 2] * levels * levels
    return packed


def _color_stats(img_bgr: np.ndarray, levels: int) -> tuple[int, float, float]:
    """Return (unique_colors, top1_ratio, top10_ratio)."""
    packed = _quantize(img_bgr, levels)
    flat = packed.ravel()
    counts = np.bincount(flat)
    total = flat.size
    sorted_counts = np.sort(counts)[::-1]
    unique = int(np.count_nonzero(counts))
    top1 = float(sorted_counts[0] / total) if total > 0 else 0.0
    top10 = float(sorted_counts[:10].sum() / total) if total > 0 else 0.0
    return unique, top1, top10


def _local_variance_ratio(img_gray: np.ndarray, block: int, thresh: float) -> float:
    """Fraction of non-overlapping blocks with stddev below `thresh`."""
    h, w = img_gray.shape
    bh, bw = h // block, w // block
    if bh == 0 or bw == 0:
        return 1.0
    crop = img_gray[: bh * block, : bw * block].astype(np.float32)
    reshaped = crop.reshape(bh, block, bw, block)
    # std per block
    block_std = reshaped.std(axis=(1, 3))
    low_mask = block_std < thresh
    return float(low_mask.sum() / low_mask.size)


def _edge_density(img_gray: np.ndarray) -> float:
    """Fraction of pixels that are edges (Canny auto thresholds)."""
    median = float(np.median(img_gray))
    low = max(0, int(median * 0.7))
    high = min(255, int(median * 1.3))
    if high <= low:
        high = low + 1
    edges = cv2.Canny(img_gray, low, high)
    return float(np.count_nonzero(edges) / edges.size)


def _largest_flat_region(img_bgr: np.ndarray, levels: int) -> float:
    """Largest connected component of near-uniform color, as fraction of image."""
    step = 256 // levels
    q = (img_bgr // step).astype(np.uint8)
    # Merge channels: use BGR quantized as label
    label = (
        q[:, :, 0].astype(np.uint32) * 64
        + q[:, :, 1].astype(np.uint32) * 8
        + q[:, :, 2].astype(np.uint32)
    )
    label_8u = (label % 256).astype(np.uint8)

    # connected components on label image
    num_labels, labels_map, stats, _ = cv2.connectedComponentsWithStats(
        label_8u, connectivity=8
    )
    if num_labels <= 1:
        return 1.0
    # find largest non-background (skip label 0 which is background of CC, but actually label 0 in CC is the first connected region)
    areas = stats[1:, cv2.CC_STAT_AREA]  # skip the first (background)
    largest = int(areas.max()) if len(areas) > 0 else 0
    return float(largest / (img_bgr.shape[0] * img_bgr.shape[1]))


def analyze_image(filepath: str, thresholds: dict) -> ImageReport:
    """Analyze a single image and return its report."""
    report = ImageReport(path=filepath)

    try:
        img_pil = Image.open(filepath)
        img_pil.load()
    except Exception as e:
        report.verdict = "ERROR"
        report.reasons.append(f"Cannot open: {e}")
        return report

    # Convert to BGR (OpenCV format)
    if img_pil.mode == "RGBA":
        img_pil = img_pil.convert("RGB")
    elif img_pil.mode not in ("RGB", "L"):
        img_pil = img_pil.convert("RGB")

    img_np = np.array(img_pil)
    if img_np.ndim == 2:
        img_bgr = cv2.cvtColor(img_np, cv2.COLOR_GRAY2BGR)
    else:
        img_bgr = cv2.cvtColor(img_np, cv2.COLOR_RGB2BGR)

    h, w, c = img_bgr.shape
    report.width = w
    report.height = h
    report.channels = c

    # Downscale very large images for speed
    max_dim = 1536
    if max(h, w) > max_dim:
        scale = max_dim / max(h, w)
        img_bgr = cv2.resize(
            img_bgr, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA
        )
        h, w = img_bgr.shape[:2]

    img_gray = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)

    # --- Metric 1: Color diversity ---
    levels = thresholds["quant_levels"]
    unique, top1, top10 = _color_stats(img_bgr, levels)
    report.unique_colors = unique
    report.top1_ratio = top1
    report.top10_ratio = top10

    # --- Metric 2: Local variance (flat / blur blocks) ---
    report.low_var_ratio = _local_variance_ratio(
        img_gray, thresholds["block_size"], thresholds["flat_std_thresh"]
    )

    # --- Metric 3: Edge density ---
    report.edge_density = _edge_density(img_gray)

    # --- Metric 4: Largest flat region ---
    report.flat_region_ratio = _largest_flat_region(img_bgr, levels)

    # --- Verdict ---
    reasons: List[str] = []

    if unique < thresholds["min_colors"]:
        reasons.append(f"low unique colors ({unique} < {thresholds['min_colors']})")
    if top1 > thresholds["max_top1"]:
        reasons.append(
            f"single color dominates ({top1:.1%} > {thresholds['max_top1']:.0%})"
        )
    if top10 > thresholds["max_top10"]:
        reasons.append(
            f"top-10 colors cover {top10:.1%} (> {thresholds['max_top10']:.0%})"
        )
    if report.low_var_ratio > thresholds["max_low_var"]:
        reasons.append(
            f"flat/blur blocks {report.low_var_ratio:.1%} (> {thresholds['max_low_var']:.0%})"
        )
    if report.edge_density < thresholds["min_edge"]:
        reasons.append(
            f"edge density {report.edge_density:.3f} (< {thresholds['min_edge']:.3f})"
        )

    if reasons:
        # FAIL if 2+ issues, WARN if exactly 1
        report.verdict = "FAIL" if len(reasons) >= 2 else "WARN"
        report.reasons = reasons
    else:
        report.verdict = "PASS"

    return report


# --------------------------------------------------------------------------
# File discovery
# --------------------------------------------------------------------------


def find_images(root: str, recursive: bool = False) -> List[str]:
    root_path = Path(root)
    if not root_path.is_dir():
        print(f"[error] Not a directory: {root}", file=sys.stderr)
        return []
    results = []
    if recursive:
        for p in root_path.rglob("*"):
            if p.suffix.lower() in SUPPORTED_EXT:
                results.append(str(p))
    else:
        for p in root_path.iterdir():
            if p.is_file() and p.suffix.lower() in SUPPORTED_EXT:
                results.append(str(p))
    results.sort()
    return results


# --------------------------------------------------------------------------
# Report output
# --------------------------------------------------------------------------


def print_console(reports: List[ImageReport], verbose: bool = False):
    """Print a summary table to console."""
    total = len(reports)
    if total == 0:
        print("[info] No images found.")
        return

    passed = sum(1 for r in reports if r.verdict == "PASS")
    warned = sum(1 for r in reports if r.verdict == "WARN")
    failed = sum(1 for r in reports if r.verdict == "FAIL")
    errors = sum(1 for r in reports if r.verdict == "ERROR")

    print()
    print("=" * 80)
    print(
        f"  Total: {total}   PASS: {passed}   WARN: {warned}   FAIL: {failed}   ERROR: {errors}"
    )
    print("=" * 80)

    # Print non-PASS items
    issues = [r for r in reports if r.verdict != "PASS"]
    if not issues:
        print("\n  All images passed. No issues detected.\n")
        return

    print(
        f"\n  {'Verdict':6s}  {'Colors':>7s}  {'Top1%':>6s}  {'Top10%':>6s}  {'LowVar%':>7s}  {'Edge%':>6s}  {'FlatR%':>6s}  Path"
    )
    print("  " + "-" * 100)

    for r in issues:
        name = os.path.basename(r.path)
        parent = os.path.basename(os.path.dirname(r.path))
        short = f"{parent}/{name}" if parent else name
        print(
            f"  {r.verdict:6s}  {r.unique_colors:7d}  {r.top1_ratio:5.1%}  {r.top10_ratio:5.1%}  "
            f"{r.low_var_ratio:6.1%}  {r.edge_density:5.2%}  {r.flat_region_ratio:5.1%}  {short}"
        )
        if verbose:
            for reason in r.reasons:
                print(f"         -> {reason}")

    print()

    # List FAIL reasons
    fails = [r for r in reports if r.verdict == "FAIL"]
    if fails:
        print(f"  FAIL images ({len(fails)}):")
        for r in fails:
            print(f"    {r.path}")
            for reason in r.reasons:
                print(f"      -> {reason}")
        print()


def write_json(reports: List[ImageReport], filepath: str):
    data = {
        "summary": {
            "total": len(reports),
            "pass": sum(1 for r in reports if r.verdict == "PASS"),
            "warn": sum(1 for r in reports if r.verdict == "WARN"),
            "fail": sum(1 for r in reports if r.verdict == "FAIL"),
            "error": sum(1 for r in reports if r.verdict == "ERROR"),
        },
        "reports": [asdict(r) for r in reports],
    }
    with open(filepath, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print(f"[json] Report saved to {filepath}")


def write_html(reports: List[ImageReport], filepath: str):
    """Generate a simple HTML report with thumbnails for failed/warned images."""
    issues = [r for r in reports if r.verdict != "PASS"]

    style = """
    <style>
      body { font-family: 'Segoe UI', sans-serif; margin: 20px; background: #1a1a2e; color: #eee; }
      h1 { color: #e94560; }
      .summary { font-size: 1.2em; margin: 20px 0; padding: 15px; background: #16213e; border-radius: 8px; }
      .summary span { margin-right: 20px; }
      .pass { color: #4ecca3; }
      .warn { color: #f0a500; }
      .fail { color: #e94560; }
      .error { color: #888; }
      .card { display: inline-block; margin: 10px; padding: 10px; background: #16213e; border-radius: 8px; vertical-align: top; width: 320px; }
      .card img { width: 300px; border-radius: 4px; }
      .card .meta { font-size: 0.8em; margin-top: 5px; }
      .card .reasons { color: #e94560; font-size: 0.85em; }
      .verdict { font-weight: bold; font-size: 1.1em; }
    </style>
    """

    cards = []
    for r in issues:
        # Use file:// path for local images
        abs_path = os.path.abspath(r.path)
        file_url = f"file:///{abs_path.replace(os.sep, '/')}"
        verdict_class = r.verdict.lower()
        reasons_html = "<br>".join(r.reasons)
        cards.append(f"""
        <div class="card">
          <img src="{file_url}" alt="{r.path}" onerror="this.style.display='none'">
          <div class="meta">
            <span class="verdict {verdict_class}">{r.verdict}</span>
            {os.path.basename(os.path.dirname(r.path))}/{os.path.basename(r.path)}
          </div>
          <div class="meta">
            colors={r.unique_colors} | top1={r.top1_ratio:.1%} | top10={r.top10_ratio:.1%}<br>
            lowVar={r.low_var_ratio:.1%} | edge={r.edge_density:.2%} | flatR={r.flat_region_ratio:.1%}
          </div>
          <div class="reasons">{reasons_html}</div>
        </div>""")

    html = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head><meta charset="utf-8">{style}<title>Image Diagnosis Report</title></head>
<body>
<h1>Image Diagnosis Report</h1>
<div class="summary">
  <span>Total: {len(reports)}</span>
  <span class="pass">PASS: {sum(1 for r in reports if r.verdict == "PASS")}</span>
  <span class="warn">WARN: {sum(1 for r in reports if r.verdict == "WARN")}</span>
  <span class="fail">FAIL: {sum(1 for r in reports if r.verdict == "FAIL")}</span>
  <span class="error">ERROR: {sum(1 for r in reports if r.verdict == "ERROR")}</span>
</div>
{"".join(cards) if cards else '<p style="font-size:1.3em;color:#4ecca3;">All images passed. No issues detected.</p>'}
</body>
</html>"""

    with open(filepath, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"[html] Report saved to {filepath}")


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(
        description="Detect images with color poverty or large flat/blur-gradient regions."
    )
    ap.add_argument("directory", help="Directory containing images to analyze.")
    ap.add_argument(
        "-r",
        "--recursive",
        action="store_true",
        help="Scan subdirectories recursively.",
    )
    ap.add_argument("--json", metavar="PATH", help="Save JSON report to this path.")
    ap.add_argument(
        "--html", metavar="PATH", help="Save HTML report with thumbnails to this path."
    )
    ap.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Print per-image reasons in console.",
    )

    ap.add_argument("--min-colors", type=int, default=DEFAULTS["min_colors"])
    ap.add_argument("--max-top1", type=float, default=DEFAULTS["max_top1"])
    ap.add_argument("--max-top10", type=float, default=DEFAULTS["max_top10"])
    ap.add_argument("--max-low-var", type=float, default=DEFAULTS["max_low_var"])
    ap.add_argument("--min-edge", type=float, default=DEFAULTS["min_edge"])
    ap.add_argument("--quant-levels", type=int, default=DEFAULTS["quant_levels"])
    ap.add_argument("--block-size", type=int, default=DEFAULTS["block_size"])
    ap.add_argument("--flat-std", type=float, default=DEFAULTS["flat_std_thresh"])

    args = ap.parse_args()

    thresholds = {
        "min_colors": args.min_colors,
        "max_top1": args.max_top1,
        "max_top10": args.max_top10,
        "max_low_var": args.max_low_var,
        "min_edge": args.min_edge,
        "quant_levels": args.quant_levels,
        "block_size": args.block_size,
        "flat_std_thresh": args.flat_std,
    }

    print(f"[scan] {args.directory} (recursive={args.recursive})")
    images = find_images(args.directory, args.recursive)
    print(f"[scan] Found {len(images)} images")

    if not images:
        return

    reports: List[ImageReport] = []
    t0 = time.time()

    for i, img_path in enumerate(images, 1):
        r = analyze_image(img_path, thresholds)
        reports.append(r)
        elapsed = time.time() - t0
        rate = i / elapsed if elapsed > 0 else 0
        eta = (len(images) - i) / rate if rate > 0 else 0
        status_icon = {"PASS": ".", "WARN": "?", "FAIL": "!", "ERROR": "X"}[r.verdict]
        print(
            f"  [{i}/{len(images)}] {status_icon} {r.verdict:5s}  "
            f"colors={r.unique_colors:6d}  top1={r.top1_ratio:5.1%}  "
            f"lowVar={r.low_var_ratio:5.1%}  edge={r.edge_density:.3f}  "
            f"{os.path.basename(r.path)}  "
            f"({rate:.1f} img/s, ETA {eta:.0f}s)",
            file=sys.stderr if r.verdict == "ERROR" else sys.stdout,
        )

    elapsed = time.time() - t0
    print(
        f"\n[done] {len(images)} images in {elapsed:.1f}s ({len(images) / elapsed:.1f} img/s)"
    )

    print_console(reports, verbose=args.verbose)

    if args.json:
        write_json(reports, args.json)
    if args.html:
        write_html(reports, args.html)


if __name__ == "__main__":
    main()
