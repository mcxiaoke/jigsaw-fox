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

本 CLI 只负责 参数解析 / 文件遍历 / 落盘 / CSV 报告；几何与能量裁剪纯算法
-------- 已抽取到 `studio/core/crop_compute.py`，与 studio export 规格化共用同一份实现。

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

from PIL import Image, ImageOps

# 保证从任意 CWD 运行都能 import repo 根的 studio 包（本脚本位于 scripts/）
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from studio.core.crop_compute import (  # noqa: E402
    build_ratio_pool,
    compute_content_box,
    aspect_crop_box,
    compute_saliency_energy,
    smart_aspect_crop_box,
    resize_short,
    select_aspect,
)

# 时区 GMT+8
TZ = timezone(timedelta(hours=8))


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
    ratio_pool = build_ratio_pool(args.ratios) if args.ratios else build_ratio_pool()

    records = []
    ok = 0
    fail = 0
    ratio_labels = [label for _, label in ratio_pool]
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