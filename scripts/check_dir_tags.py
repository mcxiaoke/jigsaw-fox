#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_dir_tags.py — 目录 TAG 识别诊断工具

扫描命令行参数给定目录的【顶级子目录】（直接子目录），
用 studio/taxonomy.py 的 tag patterns 逐个识别每个子目录名应归属的主 Tag。
方便你检查哪些目录名没被识别（落到 Others），从而决定怎么改名。

用法:
    python scripts/check_dir_tags.py "F:/Images/JigsawData"
    python scripts/check_dir_tags.py "F:/Images/JigsawData" -v    # 显示命中的正则
    python scripts/check_dir_tags.py                                  # 打印用法

说明:
    - 只依赖 Python 标准库，无需安装任何包。
    - 自动定位项目内的 studio/taxonomy.py，识别规则与 studio 完全一致。
    - 识别依据是「目录名」本身（与 studio 处理文件路径时的逻辑相同）。
    - 路径含空格请用引号包住。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# 向上查找包含 studio/taxonomy.py 的项目根目录
def _find_project_root(start: Path) -> Path | None:
    cur = start.resolve()
    for _ in range(5):
        if (cur / "studio" / "taxonomy.py").exists():
            return cur
        parent = cur.parent
        if parent == cur:
            break
        cur = parent
    return None


def _main() -> int:
    parser = argparse.ArgumentParser(
        description="识别给定目录的顶级子目录对应的主 Tag",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("root", nargs="?", help="要扫描的根目录（其直接子目录会被识别）")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="额外显示每个目录命中的具体正则 pattern")
    args = parser.parse_args()

    if not args.root:
        parser.print_help()
        return 0

    root = Path(args.root)
    if not root.is_dir():
        print(f"错误: 不是有效目录 -> {root}", file=sys.stderr)
        return 1

    # 定位并加载 studio 分类模块
    proj = _find_project_root(Path(__file__))
    if proj is None:
        print("错误: 找不到 studio/taxonomy.py，请把脚本放在项目内再运行。",
              file=sys.stderr)
        return 1
    sys.path.insert(0, str(proj / "studio"))
    import taxonomy as tx  # noqa: E402

    subdirs = sorted([p for p in root.iterdir() if p.is_dir()])
    if not subdirs:
        print(f"{root} 下没有子目录。")
        return 0

    print(f"根目录 : {root}")
    print(f"{'子目录名':42} -> 识别 Tag")
    print("-" * 64)
    for d in subdirs:
        tag = tx.normalize_tag(d.name)
        note = "" if tag != "Others" else "   <-- 未识别(Others)"
        if args.verbose:
            # 找出命中的第一个 pattern（仅用于展示，帮助判断如何改名）
            hits = [p.pattern for p, _ in tx._COMPILED_PATTERNS.get(tag, [])
                    if p.search(d.name)] if tag != "Others" else []
            extra = f"   | {hits[0]}" if hits else ""
            print(f"{d.name:42} -> {tag:12}{note}{extra}")
        else:
            print(f"{d.name:42} -> {tag}{note}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
