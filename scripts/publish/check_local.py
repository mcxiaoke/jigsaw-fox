#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_local.py — 本地发布产物全量深度门禁（发布前体检，0 远端网络开销）

三层核验体系：
  1. 静态物理体检 (studio.verify_data)：
     - 引用文件存在性（关卡图片、封面图、ZIP 包全部存在且非空）
     - 字段完整性（各 index.json 必需字段具备）
     - 内容哈希一致性（sha256 与文件一致）
     - ZIP 完整性与条目数（zipfile.testzip() CRC32 坏块校验 + 条目数等于 totalCount）
     - Manifest 自洽性（各模块 index.json sha256 等于 manifest.modules.<m>.hash）
     - 标签合规性（main 关卡 tags 位于 data/taxonomy.json 主标签白名单）
  2. 媒体解码有效性 (PIL WebP Verify)：
     - 全量扫描发布目录下所有 WebP 图片，实测解码，排查 0 字节、坏图与解码异常
  3. 客户端模型反序列化契约 (Flutter/Dart Contract Test)：
     - 运行 test/logic/jigsawdata_local_verify_test.dart，App 真实数据模型 0 报错

用法：
  python check_local.py                          # 默认校验 channels.json 的 publishRoot
  python check_local.py --publish-root <dir>     # 自定义发布目录
  python check_local.py --skip-flutter           # 跳过 flutter test 步骤（仅跑前两项）
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(HERE))

from assetmap import load_doc  # noqa: E402
from studio.verify_data import (  # noqa: E402
    fmt,
    load_taxonomy_tags,
    verify_root,
)


def verify_webp_images(
    publish_root: Path,
) -> tuple[int, int, list[str], str | None]:
    """遍历目录下所有 .webp 图片，使用 PIL 真实解码，确保图片无损坏、可正常加载。

    返回: (通过数, 总数, 损坏问题列表, 跳过原因)
    """
    try:
        from PIL import Image
    except ImportError:
        return (
            0,
            0,
            [],
            "PIL (Pillow) 未安装，跳过图片解码测试（建议 pip install Pillow）",
        )

    webps = sorted(publish_root.rglob("*.webp"))
    if not webps:
        return 0, 0, [], None

    problems: list[str] = []
    passed = 0

    for p in webps:
        rel = p.relative_to(publish_root).as_posix()
        if p.stat().st_size == 0:
            problems.append(f"[image] 图片为空 (0 字节): {rel}")
            continue
        try:
            with Image.open(p) as img:
                img.verify()
            # verify() 后需要重新打开才能做 load() 校验像素完整性
            with Image.open(p) as img:
                img.load()
            passed += 1
        except Exception as e:
            problems.append(f"[image] 图片解码失败 ({rel}): {e}")

    return passed, len(webps), problems, None


def run_flutter_local_test(
    publish_root: Path, repo_root: Path = REPO_ROOT
) -> tuple[bool, str]:
    """调用 flutter test 运行本地数据契约测试。"""
    test_file = (
        repo_root / "test" / "logic" / "jigsawdata_local_verify_test.dart"
    )
    if not test_file.exists():
        return False, f"未找到客户端契约测试文件: {test_file}"

    import shutil

    flutter_exe = (
        shutil.which("flutter")
        or shutil.which("flutter.bat")
        or (
            "flutter.bat"
            if sys.platform.startswith("win")
            else "flutter"
        )
    )

    cmd = [
        flutter_exe,
        "test",
        str(test_file),
        f"--dart-define=LOCAL_DATA_DIR={publish_root.as_posix()}",
    ]
    try:
        res = subprocess.run(
            cmd,
            cwd=str(repo_root),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        output = (res.stdout or "") + ("\n" + res.stderr if res.stderr else "")
        return res.returncode == 0, output
    except FileNotFoundError:
        return False, "未找到 flutter 命令，请确认 flutter 已加入 PATH"
    except Exception as e:
        return False, f"执行 flutter test 失败: {e}"


def run_all_local_checks(
    publish_root: Path,
    repo_root: Path = REPO_ROOT,
    skip_flutter: bool = False,
    verbose: bool = False,
) -> int:
    publish_root = Path(publish_root).resolve()
    print(f"\n===== [check-local] 本地全量深度体检: {publish_root} =====")
    if not publish_root.exists():
        print(
            f"[check-local][FATAL] 目录不存在: {publish_root}", file=sys.stderr
        )
        return 2

    # ---------------- 1. studio.verify_data 静态体检
    print("--> 1/3 静态完整性与字段自洽体检 (studio.verify_data)...")
    taxonomy_p = repo_root / "data" / "taxonomy.json"
    tags_whitelist = None
    if taxonomy_p.is_file():
        try:
            tags_whitelist = load_taxonomy_tags(taxonomy_p)
        except Exception as e:
            print(f"[check-local][warn] 读取 taxonomy.json 失败: {e}")

    report = verify_root(
        publish_root, name="PublishLocalGate", tag_whitelist=tags_whitelist
    )
    print(fmt(report))
    if report.failed > 0:
        shown = report.problems if verbose else report.problems[:20]
        for p in shown:
            print("     " + p, file=sys.stderr)
        if not verbose and report.failed > len(shown):
            print(
                f"     ... 另有 {report.failed - len(shown)} 项问题已省略（使用 -v 查看完整列表）",
                file=sys.stderr,
            )
        print(
            f"\n[check-local][FATAL] 静态体检未通过，发现 {report.failed} 项不一致！已中断流水线。",
            file=sys.stderr,
        )
        return 1

    # ---------------- 2. WebP 解码深度体检
    print("\n--> 2/3 WebP 媒体解码有效性核验...")
    img_ok, img_total, img_problems, skip_reason = verify_webp_images(publish_root)
    if skip_reason:
        print(f"  ⚠️ {skip_reason}")
    elif img_problems:
        print(
            f"  ❌ WebP 图片解码检查失败: {img_ok}/{img_total} 通过",
            file=sys.stderr,
        )
        for prob in img_problems[:20]:
            print("     " + prob, file=sys.stderr)
        print(
            f"\n[check-local][FATAL] 存在 {len(img_problems)} 张损坏/异常图片！已中断流水线。",
            file=sys.stderr,
        )
        return 1
    else:
        print(f"  ✅ WebP 图片全部可正常解码: {img_ok}/{img_total}")

    # ---------------- 3. Flutter 客户端反序列化契约
    if skip_flutter:
        print("\n--> 3/3 客户端反序列化契约: 已跳过 (--skip-flutter)")
    else:
        print("\n--> 3/3 客户端模型反序列化契约测试 (Flutter)...")
        ok, out = run_flutter_local_test(publish_root, repo_root)
        if not ok:
            print(
                "  ❌ Flutter 客户端模型契约测试失败！", file=sys.stderr
            )
            print(out, file=sys.stderr)
            print(
                "\n[check-local][FATAL] 客户端数据模型解析失败！已中断流水线，严禁推送到远端。",
                file=sys.stderr,
            )
            return 1
        print("  ✅ Flutter 客户端模型契约测试全绿通过！")

    print("\n🎉 [check-local] 本地全量门禁 100% 通过！数据已证明合法且完备。")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="check_local.py", description="发布前本地数据全量体检门禁")
    ap.add_argument(
        "--publish-root",
        default=None,
        help="待体检发布根目录（默认取 channels.json 中的 publishRoot）",
    )
    ap.add_argument(
        "--skip-flutter",
        action="store_true",
        help="跳过 flutter test 客户端模型契约测试",
    )
    ap.add_argument(
        "-v", "--verbose", action="store_true", help="打印详细问题清单"
    )
    args = ap.parse_args(argv)

    doc = load_doc()
    pub_root = Path(args.publish_root or doc["dist"]["publishRoot"])
    return run_all_local_checks(
        pub_root,
        repo_root=REPO_ROOT,
        skip_flutter=args.skip_flutter,
        verbose=args.verbose,
    )


if __name__ == "__main__":
    sys.exit(main())
