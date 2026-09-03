#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Image Similarity Detector

Detect visually similar or duplicate images using multiple algorithms.

Algorithms (selectable via --algorithm):
  phash      - Perceptual Hash (DCT-based), Hamming distance
  dhash      - Difference Hash, Hamming distance
  ahash      - Average Hash, Hamming distance
  whash      - Wavelet Hash, Hamming distance
  ssim       - Structural Similarity Index (0-1, higher = more similar)
  mse        - Mean Squared Error on 256x256 grayscale (lower = more similar)
  orb        - ORB feature point matching (match ratio)
  histogram  - HSV color histogram correlation
  all        - Run all algorithms, aggregate via average similarity

  Note: Hash algorithms include a collision guard -- when hash distance is very
  low, an MSE verification is performed. If pixel-level RMSE is high, the
  verdict is overridden to DIFFERENT. This prevents false positives on
  near-uniform images (solid colors, displacement/normal maps, etc.).

Threshold semantics:
  Hash-based  : max Hamming distance (lower = more similar).   Default: 5
  ssim        : min similarity score (0-1, higher = similar).   Default: 0.85
  mse         : max MSE (lower = more similar).                Default: 100
  orb         : min match ratio (0-1).                          Default: 0.15
  histogram   : min correlation (-1..1).                        Default: 0.70
  all         : min aggregated similarity (0-1).               Default: 0.80

For expensive algorithms (ssim, orb, all) with >200 images, a pHash
pre-filter is automatically applied to reduce comparison count.

Environment:
  Python venv:  C:\\Home\\Develop\\venv
  Dependencies: numpy, Pillow, opencv-python, imagehash, scikit-image
  Run with:     "C:/Home/Develop/venv/Scripts/python.exe" scripts/imgsim.py <dir>

Reports:
  By default, JSON and HTML reports are auto-generated in <input_dir>/output/
  with timestamped filenames: imgsim_{algorithm}_{YYYYMMDD_HHMMSS}.json/.html
  Use --output to change the directory, --no-json/--no-html to suppress.

Usage:
  # Basic: detect duplicates with pHash (default threshold 5)
  "C:/Home/Develop/venv/Scripts/python.exe" scripts/imgsim.py C:/images

  # Recursive, dHash with custom threshold
  "C:/Home/Develop/venv/Scripts/python.exe" scripts/imgsim.py C:/images -r \
      --algorithm dhash --threshold 8

  # SSIM with 0.90 threshold, 8 parallel workers, custom output dir
  "C:/Home/Develop/venv/Scripts/python.exe" scripts/imgsim.py C:/images \
      --algorithm ssim --threshold 0.90 --workers 8 --output C:/reports

  # All algorithms aggregated, HTML only
  "C:/Home/Develop/venv/Scripts/python.exe" scripts/imgsim.py C:/images \
      --algorithm all --threshold 0.85 --no-json

  # Explicit report paths (overrides auto-naming)
  "C:/Home/Develop/venv/Scripts/python.exe" scripts/imgsim.py C:/images \
      --json my_report.json --html my_report.html
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import sys
import time
from dataclasses import asdict, dataclass, field
from itertools import combinations
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

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
from PIL import Image, ImageOps
import imagehash
from skimage.metrics import structural_similarity as compute_ssim

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

SUPPORTED_EXT = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tiff", ".tif"}

ALGORITHMS = [
    "phash",
    "dhash",
    "ahash",
    "whash",
    "ssim",
    "mse",
    "orb",
    "histogram",
    "all",
]

DEFAULT_THRESHOLDS: Dict[str, float] = {
    "phash": 5,
    "dhash": 5,
    "ahash": 5,
    "whash": 5,
    "ssim": 0.85,
    "mse": 100,  # max MSE (lower = more similar); 100 ~= RMSE 10/255
    "orb": 0.15,
    "histogram": 0.70,
    "all": 0.80,
}

HASH_ALGOS = {"phash", "dhash", "ahash", "whash"}
EXPENSIVE_ALGOS = {"ssim", "orb", "all"}
PREFILTER_THRESHOLD = 32  # max pHash Hamming distance for pre-filter candidates
SSIM_RESIZE = 256  # resize dimension for SSIM/MSE comparison
ORB_MAX_FEATURES = 500  # max ORB keypoints per image
ORB_MAX_DIM = 512  # max dimension for ORB detection

# Hash collision guard: when hash distance is very low, verify with MSE.
# If RMSE exceeds this, the hash result is overridden to DIFFERENT.
HASH_GUARD_RMSE = 15.0  # ~6% of 255; catches uniform/low-variance false positives

ALL_HASH_NAMES = ["phash", "dhash", "ahash", "whash"]

# Singleton BFMatcher for ORB (thread-safe for matching)
_BF_MATCHER = cv2.BFMatcher(cv2.NORM_HAMMING)


# --------------------------------------------------------------------------
# Data models
# --------------------------------------------------------------------------


@dataclass
class ImageMeta:
    """JSON-serializable image metadata."""

    path: str
    width: int = 0
    height: int = 0
    hash_value: str = ""  # primary hash (single-algo mode)
    hash_values: Dict[str, str] = field(default_factory=dict)  # all hashes (all mode)
    orb_keypoint_count: int = 0
    error: str = ""


@dataclass
class PairResult:
    """Result of comparing two images."""

    image_a: str
    image_b: str
    algorithm: str
    distance: float  # raw metric (algorithm-dependent, lower = more similar)
    similarity: float  # normalized 0-1 (1 = identical)
    verdict: str  # SIMILAR / DIFFERENT
    metrics: Dict[str, Any] = field(
        default_factory=dict
    )  # per-algo breakdown (all mode)


# --------------------------------------------------------------------------
# File discovery
# --------------------------------------------------------------------------


def find_images(root: str, recursive: bool = False) -> List[str]:
    root_path = Path(root)
    if not root_path.is_dir():
        print(f"[error] Not a directory: {root}", file=sys.stderr)
        return []
    results: List[str] = []
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
# Feature extraction
# --------------------------------------------------------------------------


def _compute_hash(img_pil: Image.Image, algo: str, hash_size: int):
    """Compute perceptual hash using the imagehash library."""
    if algo == "phash":
        return imagehash.phash(img_pil, hash_size=hash_size)
    elif algo == "dhash":
        return imagehash.dhash(img_pil, hash_size=hash_size)
    elif algo == "ahash":
        return imagehash.average_hash(img_pil, hash_size=hash_size)
    elif algo == "whash":
        return imagehash.whash(img_pil, hash_size=hash_size)
    return None


def _compute_gray_small(img_bgr: np.ndarray, dim: int = SSIM_RESIZE) -> np.ndarray:
    """Resize to small grayscale for SSIM comparison."""
    gray = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)
    return cv2.resize(gray, (dim, dim), interpolation=cv2.INTER_AREA)


def _compute_histogram(img_bgr: np.ndarray) -> np.ndarray:
    """Compute normalized HSV histogram for color comparison."""
    hsv = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2HSV)
    hist = cv2.calcHist([hsv], [0, 1], None, [50, 60], [0, 180, 0, 256])
    cv2.normalize(hist, hist, 0, 1, cv2.NORM_MINMAX)
    return hist


def _compute_orb(img_bgr: np.ndarray) -> Tuple[Optional[np.ndarray], int]:
    """Detect ORB keypoints and compute descriptors."""
    gray = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)
    h, w = gray.shape
    if max(h, w) > ORB_MAX_DIM:
        scale = ORB_MAX_DIM / max(h, w)
        gray = cv2.resize(
            gray, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA
        )
    detector = cv2.ORB_create(nfeatures=ORB_MAX_FEATURES)
    _, descriptors = detector.detectAndCompute(gray, None)
    if descriptors is None:
        return None, 0
    return descriptors, len(descriptors)


def extract_features(
    path: str,
    algorithm: str,
    hash_size: int,
    max_dim: int,
) -> Tuple[ImageMeta, Dict[str, Any]]:
    """Extract features for a single image.

    Returns (metadata, feature_dict) where feature_dict holds non-serializable
    objects (ImageHash, numpy arrays) keyed by algorithm name.
    """
    meta = ImageMeta(path=path)
    feats: Dict[str, Any] = {}

    try:
        # Load with PIL (handles EXIF orientation)
        img_pil = Image.open(path)
        img_pil.load()
        img_pil = ImageOps.exif_transpose(img_pil)

        meta.width, meta.height = img_pil.size

        if img_pil.mode != "RGB":
            img_pil = img_pil.convert("RGB")

        # Convert to OpenCV BGR
        img_np = np.array(img_pil)
        img_bgr = cv2.cvtColor(img_np, cv2.COLOR_RGB2BGR)

        # Downscale large images for analysis speed
        h, w = img_bgr.shape[:2]
        if max(h, w) > max_dim:
            scale = max_dim / max(h, w)
            img_bgr = cv2.resize(
                img_bgr, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA
            )

        # Determine which features are needed
        # gray_small is ALWAYS computed: needed for MSE, SSIM, and hash guard
        need_hashes = algorithm in HASH_ALGOS or algorithm == "all"
        need_hist = algorithm == "histogram" or algorithm == "all"
        need_orb = algorithm == "orb" or algorithm == "all"

        # Hash features
        if need_hashes:
            hash_names = ALL_HASH_NAMES if algorithm == "all" else [algorithm]
            for algo in hash_names:
                h = _compute_hash(img_pil, algo, hash_size)
                feats[algo] = h
                meta.hash_values[algo] = str(h)
            if algorithm in HASH_ALGOS:
                meta.hash_value = str(feats[algorithm])
            elif algorithm == "all":
                meta.hash_value = str(feats.get("phash", ""))

        # Grayscale 256x256 (always computed: for SSIM, MSE, and hash guard)
        feats["gray"] = _compute_gray_small(img_bgr)

        # Histogram feature
        if need_hist:
            feats["hist"] = _compute_histogram(img_bgr)

        # ORB feature
        if need_orb:
            desc, kp_count = _compute_orb(img_bgr)
            feats["orb_desc"] = desc
            feats["orb_kp"] = kp_count
            meta.orb_keypoint_count = kp_count

    except Exception as e:
        meta.error = str(e)

    return meta, feats


# --------------------------------------------------------------------------
# Pairwise comparison
# --------------------------------------------------------------------------


def _hamming_to_similarity(distance: int, hash_size: int) -> float:
    bits = hash_size * hash_size
    return max(0.0, 1.0 - distance / bits)


def compare_pair(
    meta_a: ImageMeta,
    feats_a: Dict[str, Any],
    meta_b: ImageMeta,
    feats_b: Dict[str, Any],
    algorithm: str,
    hash_size: int,
    threshold: float,
) -> Optional[PairResult]:
    """Compare two images and return a PairResult, or None if skipped."""

    if meta_a.error or meta_b.error:
        return None

    hash_bits = hash_size * hash_size

    # Helper: compute MSE on gray_small (used by hash guard and standalone MSE)
    def _compute_mse(g1: np.ndarray, g2: np.ndarray) -> float:
        diff = g1.astype(np.float64) - g2.astype(np.float64)
        return float(np.mean(diff * diff))

    # --- Single hash algorithm ---
    if algorithm in HASH_ALGOS:
        h_a = feats_a.get(algorithm)
        h_b = feats_b.get(algorithm)
        if h_a is None or h_b is None:
            return None
        distance = int(h_a - h_b)
        similarity = _hamming_to_similarity(distance, hash_size)
        verdict = "SIMILAR" if distance <= threshold else "DIFFERENT"

        # Hash collision guard: verify with MSE when hash distance is low.
        # Prevents false positives on near-uniform / low-variance images
        # (e.g. solid-color displacement/normal maps that hash identically).
        if verdict == "SIMILAR" and distance <= 2:
            g_a = feats_a.get("gray")
            g_b = feats_b.get("gray")
            if g_a is not None and g_b is not None:
                mse = _compute_mse(g_a, g_b)
                rmse = mse**0.5
                if rmse > HASH_GUARD_RMSE:
                    # Hash says similar but pixels say different
                    similarity = max(0.0, 1.0 - rmse / 128.0)
                    return PairResult(
                        image_a=meta_a.path,
                        image_b=meta_b.path,
                        algorithm=algorithm,
                        distance=distance,
                        similarity=round(similarity, 4),
                        verdict="DIFFERENT",
                        metrics={
                            "hash_distance": distance,
                            "mse_guard": round(mse, 2),
                            "rmse_guard": round(rmse, 2),
                        },
                    )

        return PairResult(
            image_a=meta_a.path,
            image_b=meta_b.path,
            algorithm=algorithm,
            distance=distance,
            similarity=round(similarity, 4),
            verdict=verdict,
        )

    # --- SSIM ---
    if algorithm == "ssim":
        g_a = feats_a.get("gray")
        g_b = feats_b.get("gray")
        if g_a is None or g_b is None:
            return None
        score = float(compute_ssim(g_a, g_b))
        verdict = "SIMILAR" if score >= threshold else "DIFFERENT"
        return PairResult(
            image_a=meta_a.path,
            image_b=meta_b.path,
            algorithm="ssim",
            distance=round(1.0 - score, 4),
            similarity=round(score, 4),
            verdict=verdict,
        )

    # --- MSE ---
    if algorithm == "mse":
        g_a = feats_a.get("gray")
        g_b = feats_b.get("gray")
        if g_a is None or g_b is None:
            return None
        mse = _compute_mse(g_a, g_b)
        rmse = mse**0.5
        similarity = max(0.0, 1.0 - rmse / 128.0)
        verdict = "SIMILAR" if mse <= threshold else "DIFFERENT"
        return PairResult(
            image_a=meta_a.path,
            image_b=meta_b.path,
            algorithm="mse",
            distance=round(mse, 2),
            similarity=round(similarity, 4),
            verdict=verdict,
        )

    # --- ORB ---
    if algorithm == "orb":
        d_a = feats_a.get("orb_desc")
        d_b = feats_b.get("orb_desc")
        kp_a = feats_a.get("orb_kp", 0)
        kp_b = feats_b.get("orb_kp", 0)
        if d_a is None or d_b is None or len(d_a) < 2 or len(d_b) < 2:
            return None
        matches = _BF_MATCHER.knnMatch(d_a, d_b, k=2)
        good = sum(1 for m, n in matches if m.distance < 0.75 * n.distance)
        min_kp = min(kp_a, kp_b)
        ratio = good / min_kp if min_kp > 0 else 0.0
        verdict = "SIMILAR" if ratio >= threshold else "DIFFERENT"
        return PairResult(
            image_a=meta_a.path,
            image_b=meta_b.path,
            algorithm="orb",
            distance=round(1.0 - ratio, 4),
            similarity=round(ratio, 4),
            verdict=verdict,
        )

    # --- Histogram ---
    if algorithm == "histogram":
        h_a = feats_a.get("hist")
        h_b = feats_b.get("hist")
        if h_a is None or h_b is None:
            return None
        corr = float(cv2.compareHist(h_a, h_b, cv2.HISTCMP_CORREL))
        similarity = (corr + 1.0) / 2.0
        verdict = "SIMILAR" if corr >= threshold else "DIFFERENT"
        return PairResult(
            image_a=meta_a.path,
            image_b=meta_b.path,
            algorithm="histogram",
            distance=round(1.0 - similarity, 4),
            similarity=round(similarity, 4),
            verdict=verdict,
        )

    # --- All algorithms aggregated ---
    if algorithm == "all":
        metrics: Dict[str, Any] = {}
        similarities: List[float] = []

        # Hash comparisons
        for algo in ALL_HASH_NAMES:
            h_a = feats_a.get(algo)
            h_b = feats_b.get(algo)
            if h_a is not None and h_b is not None:
                dist = int(h_a - h_b)
                sim = _hamming_to_similarity(dist, hash_size)
                metrics[algo] = {"distance": dist, "similarity": round(sim, 4)}
                similarities.append(sim)

        # SSIM + MSE (both use gray_small)
        g_a = feats_a.get("gray")
        g_b = feats_b.get("gray")
        if g_a is not None and g_b is not None:
            score = float(compute_ssim(g_a, g_b))
            metrics["ssim"] = {"score": round(score, 4)}
            similarities.append(score)

            mse = float(np.mean((g_a.astype(np.float64) - g_b.astype(np.float64)) ** 2))
            rmse = mse**0.5
            mse_sim = max(0.0, 1.0 - rmse / 128.0)
            metrics["mse"] = {
                "mse": round(mse, 2),
                "rmse": round(rmse, 2),
                "similarity": round(mse_sim, 4),
            }
            similarities.append(mse_sim)

        # Histogram
        h_a = feats_a.get("hist")
        h_b = feats_b.get("hist")
        if h_a is not None and h_b is not None:
            corr = float(cv2.compareHist(h_a, h_b, cv2.HISTCMP_CORREL))
            sim = (corr + 1.0) / 2.0
            metrics["histogram"] = {
                "correlation": round(corr, 4),
                "similarity": round(sim, 4),
            }
            similarities.append(sim)

        # ORB
        d_a = feats_a.get("orb_desc")
        d_b = feats_b.get("orb_desc")
        kp_a = feats_a.get("orb_kp", 0)
        kp_b = feats_b.get("orb_kp", 0)
        if d_a is not None and d_b is not None and len(d_a) >= 2 and len(d_b) >= 2:
            matches = _BF_MATCHER.knnMatch(d_a, d_b, k=2)
            good = sum(1 for m, n in matches if m.distance < 0.75 * n.distance)
            min_kp = min(kp_a, kp_b)
            ratio = good / min_kp if min_kp > 0 else 0.0
            metrics["orb"] = {"match_ratio": round(ratio, 4), "good_matches": good}
            similarities.append(ratio)

        if not similarities:
            return None

        agg_sim = sum(similarities) / len(similarities)
        verdict = "SIMILAR" if agg_sim >= threshold else "DIFFERENT"
        return PairResult(
            image_a=meta_a.path,
            image_b=meta_b.path,
            algorithm="all",
            distance=round(1.0 - agg_sim, 4),
            similarity=round(agg_sim, 4),
            verdict=verdict,
            metrics=metrics,
        )

    return None


# --------------------------------------------------------------------------
# Pre-filter: compute pHash for candidates when using expensive algorithms
# --------------------------------------------------------------------------


def _ensure_phash(
    metas: List[ImageMeta],
    store: Dict[str, Dict[str, Any]],
    hash_size: int,
    max_dim: int,
    workers: int,
) -> None:
    """Ensure pHash is available for all images (for pre-filtering)."""
    missing = [m for m in metas if "phash" not in store.get(m.path, {})]
    if not missing:
        return

    print(f"[prefilter] Computing pHash for {len(missing)} images...")

    def _add_phash(meta: ImageMeta) -> None:
        try:
            img_pil = Image.open(meta.path)
            img_pil.load()
            img_pil = ImageOps.exif_transpose(img_pil)
            if img_pil.mode != "RGB":
                img_pil = img_pil.convert("RGB")
            h = imagehash.phash(img_pil, hash_size=hash_size)
            store.setdefault(meta.path, {})["phash"] = h
            meta.hash_values["phash"] = str(h)
        except Exception:
            pass

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        list(executor.map(_add_phash, missing))


# --------------------------------------------------------------------------
# Console output
# --------------------------------------------------------------------------


def print_console(
    results: List[PairResult],
    metas: List[ImageMeta],
    algorithm: str,
    threshold: float,
    verbose: bool = False,
) -> None:
    total = len(metas)
    errors = sum(1 for m in metas if m.error)
    similar = len(results)

    print()
    print("=" * 80)
    print(
        f"  Algorithm: {algorithm}   Threshold: {threshold}   "
        f"Images: {total}   Errors: {errors}   Similar pairs: {similar}"
    )
    print("=" * 80)

    if not results:
        print("\n  No similar pairs found.\n")
        return

    print(f"\n  {'#':>3s}  {'Sim':>6s}  {'Dist':>6s}  Image A  ->  Image B")
    print("  " + "-" * 100)

    for i, r in enumerate(results, 1):
        name_a = os.path.basename(r.image_a)
        name_b = os.path.basename(r.image_b)
        parent_a = os.path.basename(os.path.dirname(r.image_a))
        short_a = f"{parent_a}/{name_a}" if parent_a else name_a
        short_b = os.path.basename(os.path.dirname(r.image_b)) + "/" + name_b
        print(
            f"  {i:3d}  {r.similarity:6.4f}  {r.distance:6.2f}  {short_a}  ->  {short_b}"
        )

        if verbose and r.metrics:
            for algo, vals in r.metrics.items():
                print(f"         {algo}: {vals}")

    print()


# --------------------------------------------------------------------------
# JSON report
# --------------------------------------------------------------------------


def write_json(
    results: List[PairResult],
    metas: List[ImageMeta],
    filepath: str,
    algorithm: str,
    threshold: float,
    hash_size: int,
    elapsed: float,
    total_pairs: int,
) -> None:
    data = {
        "summary": {
            "algorithm": algorithm,
            "threshold": threshold,
            "hash_size": hash_size,
            "total_images": len(metas),
            "total_pairs_compared": total_pairs,
            "similar_pairs": len(results),
            "errors": sum(1 for m in metas if m.error),
            "elapsed_seconds": round(elapsed, 2),
        },
        "similar_pairs": [asdict(r) for r in results],
        "images": [
            {
                "path": m.path,
                "width": m.width,
                "height": m.height,
                "hash_value": m.hash_value,
                "hash_values": m.hash_values,
                "orb_keypoint_count": m.orb_keypoint_count,
                "error": m.error,
            }
            for m in metas
        ],
    }
    with open(filepath, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print(f"[json] Report saved to {filepath}")


# --------------------------------------------------------------------------
# HTML report
# --------------------------------------------------------------------------


def write_html(
    results: List[PairResult],
    metas: List[ImageMeta],
    filepath: str,
    algorithm: str,
    threshold: float,
) -> None:
    style = """
    <style>
      body { font-family: 'Segoe UI', sans-serif; margin: 20px; background: #1a1a2e; color: #eee; }
      h1 { color: #e94560; }
      .summary { font-size: 1.2em; margin: 20px 0; padding: 15px; background: #16213e; border-radius: 8px; }
      .summary span { margin-right: 20px; }
      .pair { display: flex; gap: 15px; margin: 15px 0; padding: 15px; background: #16213e; border-radius: 8px; }
      .pair img { width: 300px; border-radius: 4px; }
      .pair .info { flex: 1; }
      .pair .sim { color: #4ecca3; font-size: 1.3em; font-weight: bold; }
      .pair .metrics { font-size: 0.85em; margin-top: 8px; color: #aaa; }
      .pair .path { font-size: 0.8em; color: #888; word-break: break-all; }
    </style>
    """

    cards: List[str] = []
    for i, r in enumerate(results, 1):
        ua = os.path.abspath(r.image_a).replace(os.sep, "/")
        ub = os.path.abspath(r.image_b).replace(os.sep, "/")
        metrics_html = ""
        if r.metrics:
            parts = [f"{k}: {v}" for k, v in r.metrics.items()]
            metrics_html = "<br>".join(parts)

        cards.append(f"""
        <div class="pair">
          <div>
            <img src="file:///{ua}" alt="A" onerror="this.style.display='none'">
          </div>
          <div>
            <img src="file:///{ub}" alt="B" onerror="this.style.display='none'">
          </div>
          <div class="info">
            <div class="sim">#{i}  Similarity: {r.similarity:.4f}  Distance: {r.distance:.4f}</div>
            <div class="path">{r.image_a}</div>
            <div class="path">{r.image_b}</div>
            <div class="metrics">{metrics_html}</div>
          </div>
        </div>""")

    html = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head><meta charset="utf-8">{style}<title>Image Similarity Report</title></head>
<body>
<h1>Image Similarity Report</h1>
<div class="summary">
  <span>Algorithm: {algorithm}</span>
  <span>Threshold: {threshold}</span>
  <span>Images: {len(metas)}</span>
  <span>Similar pairs: {len(results)}</span>
</div>
{"".join(cards) if cards else '<p style="font-size:1.3em;color:#4ecca3;">No similar pairs found.</p>'}
</body>
</html>"""

    with open(filepath, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"[html] Report saved to {filepath}")


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Detect visually similar or duplicate images using multiple algorithms."
    )
    ap.add_argument("directory", help="Directory containing images to analyze.")
    ap.add_argument(
        "-r",
        "--recursive",
        action="store_true",
        help="Scan subdirectories recursively.",
    )
    ap.add_argument(
        "--algorithm",
        choices=ALGORITHMS,
        default="phash",
        help=f"Similarity algorithm (default: phash). Choices: {', '.join(ALGORITHMS)}",
    )
    ap.add_argument(
        "--threshold",
        type=float,
        default=None,
        help="Similarity threshold. Semantics depend on algorithm "
        "(hash: max Hamming dist; ssim/orb: min score; "
        "histogram: min correlation; all: min aggregated similarity). "
        "Default: algorithm-specific.",
    )
    ap.add_argument(
        "--hash-size",
        type=int,
        default=8,
        help="Hash size for perceptual hashes (default: 8 = 64-bit).",
    )
    ap.add_argument(
        "--max-dim",
        type=int,
        default=1024,
        help="Max dimension for image resize before feature extraction (default: 1024).",
    )
    ap.add_argument(
        "--workers",
        type=int,
        default=None,
        help="Number of parallel worker threads (default: cpu_count).",
    )
    ap.add_argument(
        "--output",
        metavar="DIR",
        default=None,
        help="Output directory for reports (default: <input_dir>/output).",
    )
    ap.add_argument(
        "--json",
        metavar="PATH",
        default=None,
        help="Explicit JSON report path (overrides auto-naming).",
    )
    ap.add_argument(
        "--html",
        metavar="PATH",
        default=None,
        help="Explicit HTML report path (overrides auto-naming).",
    )
    ap.add_argument("--no-json", action="store_true", help="Skip JSON report output.")
    ap.add_argument("--no-html", action="store_true", help="Skip HTML report output.")
    ap.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Print per-pair metric details in console.",
    )

    args = ap.parse_args()

    algorithm = args.algorithm
    hash_size = args.hash_size
    threshold = (
        args.threshold if args.threshold is not None else DEFAULT_THRESHOLDS[algorithm]
    )
    workers = args.workers or min(os.cpu_count() or 4, 16)

    print(
        f"[config] Algorithm={algorithm}  Threshold={threshold}  "
        f"HashSize={hash_size}  Workers={workers}"
    )

    # --- Find images ---
    print(f"[scan] {args.directory} (recursive={args.recursive})")
    images = find_images(args.directory, args.recursive)
    print(f"[scan] Found {len(images)} images")

    if len(images) < 2:
        print("[info] Need at least 2 images to compare.")
        return 0

    n_pairs = len(images) * (len(images) - 1) // 2
    print(f"[scan] Total pairs: {n_pairs}")

    # --- Pre-filter decision ---
    need_prefilter = (algorithm in EXPENSIVE_ALGOS) and len(images) > 200
    if need_prefilter:
        print(
            f"[prefilter] {len(images)} images > 200, "
            f"enabling pHash pre-filter (max distance={PREFILTER_THRESHOLD})"
        )

    # --- Phase 1: Extract features ---
    print(f"\n[extract] Extracting features ({algorithm})...")
    t0 = time.time()

    metas: List[ImageMeta] = []
    feature_store: Dict[str, Dict[str, Any]] = {}

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        future_map = {
            executor.submit(
                extract_features, path, algorithm, hash_size, args.max_dim
            ): path
            for path in images
        }
        for i, future in enumerate(concurrent.futures.as_completed(future_map), 1):
            path = future_map[future]
            try:
                meta, feats = future.result()
                metas.append(meta)
                if not meta.error:
                    feature_store[path] = feats
            except Exception as e:
                metas.append(ImageMeta(path=path, error=str(e)))

            if i % 50 == 0 or i == len(images):
                elapsed = time.time() - t0
                rate = i / elapsed if elapsed > 0 else 0
                eta = (len(images) - i) / rate if rate > 0 else 0
                print(
                    f"\r  [{i}/{len(images)}] {rate:.1f} img/s, ETA {eta:.0f}s",
                    end="",
                    file=sys.stderr,
                    flush=True,
                )

    elapsed_extract = time.time() - t0
    errors = sum(1 for m in metas if m.error)
    print(
        f"\n[extract] Done in {elapsed_extract:.1f}s "
        f"({len(metas)} images, {errors} errors)"
    )

    metas.sort(key=lambda m: m.path)

    # --- Ensure pHash for pre-filter ---
    if need_prefilter:
        _ensure_phash(metas, feature_store, hash_size, args.max_dim, workers)

    # --- Phase 2: Compare all pairs ---
    valid_metas = [m for m in metas if not m.error]
    pairs = list(combinations(range(len(valid_metas)), 2))

    if need_prefilter:
        filtered = []
        for i, j in pairs:
            fi = feature_store.get(valid_metas[i].path, {})
            fj = feature_store.get(valid_metas[j].path, {})
            hi, hj = fi.get("phash"), fj.get("phash")
            if hi is not None and hj is not None and (hi - hj) <= PREFILTER_THRESHOLD:
                filtered.append((i, j))
        print(f"[prefilter] {len(filtered)}/{len(pairs)} pairs passed pHash filter")
        pairs = filtered

    print(f"\n[compare] Comparing {len(pairs)} pairs...")
    t1 = time.time()
    results: List[PairResult] = []

    # Fast algorithms: serial comparison
    if algorithm in HASH_ALGOS or algorithm in ("histogram", "mse"):
        for idx, (i, j) in enumerate(pairs, 1):
            r = compare_pair(
                valid_metas[i],
                feature_store.get(valid_metas[i].path, {}),
                valid_metas[j],
                feature_store.get(valid_metas[j].path, {}),
                algorithm,
                hash_size,
                threshold,
            )
            if r and r.verdict == "SIMILAR":
                results.append(r)

            if idx % 5000 == 0 or idx == len(pairs):
                elapsed = time.time() - t1
                rate = idx / elapsed if elapsed > 0 else 0
                eta = (len(pairs) - idx) / rate if rate > 0 else 0
                print(
                    f"\r  [{idx}/{len(pairs)}] {rate:.0f} pairs/s, "
                    f"ETA {eta:.0f}s, found {len(results)} similar",
                    end="",
                    file=sys.stderr,
                    flush=True,
                )

    # Expensive algorithms: parallel comparison
    else:

        def _task(pair):
            i, j = pair
            return compare_pair(
                valid_metas[i],
                feature_store.get(valid_metas[i].path, {}),
                valid_metas[j],
                feature_store.get(valid_metas[j].path, {}),
                algorithm,
                hash_size,
                threshold,
            )

        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
            futures = {executor.submit(_task, p): p for p in pairs}
            for idx, future in enumerate(concurrent.futures.as_completed(futures), 1):
                r = future.result()
                if r and r.verdict == "SIMILAR":
                    results.append(r)

                if idx % 100 == 0 or idx == len(pairs):
                    elapsed = time.time() - t1
                    rate = idx / elapsed if elapsed > 0 else 0
                    eta = (len(pairs) - idx) / rate if rate > 0 else 0
                    print(
                        f"\r  [{idx}/{len(pairs)}] {rate:.1f} pairs/s, "
                        f"ETA {eta:.0f}s, found {len(results)} similar",
                        end="",
                        file=sys.stderr,
                        flush=True,
                    )

    elapsed_compare = time.time() - t1
    print(
        f"\n[compare] Done in {elapsed_compare:.1f}s "
        f"({len(pairs)} pairs, {len(results)} similar)"
    )

    # Sort by similarity descending
    results.sort(key=lambda r: r.similarity, reverse=True)

    # --- Resolve report paths ---
    # Default: <input_dir>/output/imgsim_{algorithm}_{timestamp}.json/.html
    # Override: --output DIR changes directory; --json/--html sets explicit path
    out_dir = args.output or os.path.join(args.directory, "output")
    os.makedirs(out_dir, exist_ok=True)

    from datetime import datetime

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    base_name = f"imgsim_{algorithm}_{timestamp}"

    json_path = args.json or os.path.join(out_dir, base_name + ".json")
    html_path = args.html or os.path.join(out_dir, base_name + ".html")

    # --- Output ---
    print_console(results, metas, algorithm, threshold, verbose=args.verbose)

    if not args.no_json:
        write_json(
            results,
            metas,
            json_path,
            algorithm,
            threshold,
            hash_size,
            elapsed_extract + elapsed_compare,
            len(pairs),
        )

    if not args.no_html:
        write_html(results, metas, html_path, algorithm, threshold)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
