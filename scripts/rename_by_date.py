#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按日期后缀/替换重命名图片。

用法示例:
  # 仅给当前目录下图片追加日期后缀（保留原名）
  python rename_by_date.py "C:/path/to/imgs" --bydate 20260801

  # 递归处理，并用日期整体替换文件名（不保留原名）
  python rename_by_date.py "C:/path/to/imgs" --bydate 20260801 --recursive --replace

  # 先演习，不真正改文件名
  python rename_by_date.py "C:/path/to/imgs" --bydate 20260801 --dry-run
"""

import argparse
import os
import sys
from datetime import datetime, timedelta

# 仅处理常见图片扩展名（小写）
IMAGE_EXTS = {
    ".jpg", ".jpeg", ".png", ".gif", ".bmp",
    ".webp", ".tiff", ".tif", ".heic", ".avif",
}


def collect_images(folder: str, recursive: bool) -> list:
    """收集图片文件，返回按文件名升序排列的 (abspath) 列表。"""
    found = []
    if recursive:
        for root, _dirs, files in os.walk(folder):
            for name in files:
                if os.path.splitext(name)[1].lower() in IMAGE_EXTS:
                    found.append(os.path.join(root, name))
    else:
        for name in os.listdir(folder):
            full = os.path.join(folder, name)
            if os.path.isfile(full) and os.path.splitext(name)[1].lower() in IMAGE_EXTS:
                found.append(full)
    # 按完整路径排序（目录 + 文件名），保证顺序确定可复现
    found.sort()
    return found


def parse_date(s: str) -> datetime:
    try:
        return datetime.strptime(s, "%Y%m%d")
    except ValueError:
        raise SystemExit(f"[错误] --bydate 必须是 YYYYMMDD 格式，收到: {s!r}")


def build_target(base: datetime, idx: int, old_path: str, replace: bool) -> str:
    """根据序号生成目标文件名（不含目录）。"""
    day = base + timedelta(days=idx)
    date_str = day.strftime("%Y%m%d")
    root, ext = os.path.splitext(old_path)
    if replace:
        return date_str + ext.lower()
    old_name = os.path.basename(root)
    return f"{old_name}_{date_str}{ext.lower()}"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="按日期重命名图片：加后缀或整体替换文件名。",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("folder", help="目标文件夹路径")
    parser.add_argument("--bydate", required=True,
                        help="起始日期，格式 YYYYMMDD，如 20260801")
    parser.add_argument("--recursive", action="store_true",
                        help="递归遍历子目录（默认不递归）")
    parser.add_argument("--replace", action="store_true",
                        help="整体替换文件名（不含扩展名），默认仅加后缀")
    parser.add_argument("--dry-run", action="store_true",
                        help="只打印将要执行的重命名，不真正改文件")
    args = parser.parse_args()

    if not os.path.isdir(args.folder):
        print(f"[错误] 文件夹不存在: {args.folder}", file=sys.stderr)
        return 2

    base = parse_date(args.bydate)
    files = collect_images(args.folder, args.recursive)
    if not files:
        print("没有找到图片文件。")
        return 0

    mode = "替换" if args.replace else "加后缀"
    scope = "递归" if args.recursive else "当前目录"
    print(f"共找到 {len(files)} 个图片（{scope}，模式：{mode}）")
    print(f"起始日期: {base.strftime('%Y-%m-%d')}，按天递增\n")

    # 计算目标路径
    plans = []  # (old, new)
    for idx, old in enumerate(files):
        new_name = build_target(base, idx, old, args.replace)
        new = os.path.join(os.path.dirname(old), new_name)
        plans.append((old, new))

    # 冲突检测：同一批次内或外部已存在同名
    new_set = {}
    for old, new in plans:
        if new in new_set:
            print(f"[错误] 目标文件名冲突: {new}", file=sys.stderr)
            return 3
        new_set[new] = old
    for old, new in plans:
        if os.path.exists(new) and new != old:
            print(f"[错误] 目标已存在且不在处理列表: {new}", file=sys.stderr)
            return 3

    if args.dry_run:
        for old, new in plans:
            print(f"  {os.path.basename(old)}  ->  {os.path.basename(new)}")
        print("\n[dry-run] 未做实际修改。")
        return 0

    # 两阶段重命名，避免过程中相互覆盖
    tmp = []
    try:
        for i, (old, new) in enumerate(plans):
            staging = old + f".__rename_tmp_{i}__"
            os.rename(old, staging)
            tmp.append((staging, new))
        for staging, new in tmp:
            os.rename(staging, new)
    except OSError as e:
        print(f"[错误] 重命名失败: {e}", file=sys.stderr)
        return 1

    print("完成。重命名结果：")
    for old, new in plans:
        print(f"  {os.path.basename(old)}  ->  {os.path.basename(new)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
