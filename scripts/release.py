#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
release.py — JigsawFox 多平台发布与打包脚本

功能：
1. 自动从 pubspec.yaml 解析当前版本号
2. 支持构建 Windows Desktop Release，排除调试符号与临时文件并打包成 zip
3. 支持构建 Android APK（分 ABI 包与通用 fat 包）及打包 zip
4. 为全部构建产物自动生成 SHA256SUMS.txt 校验清单
5. 统一输出到 releases/<version>/github/ 目录，方便 gh release 上传

用法示例：
  python scripts/release.py                     # 默认构建全部平台（Windows + Android）
  python scripts/release.py --platform windows  # 仅构建并打包 Windows
  python scripts/release.py --platform android  # 仅构建并打包 Android
  python scripts/release.py --clean             # 构建前先执行 flutter clean && flutter pub get
  python scripts/release.py --dry-run           # 仅打印将要执行的命令
"""

from __future__ import annotations

import argparse
import hashlib
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

# 确保 Windows 下控制台编码正确
if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

APP_NAME = "JigsawFox"
ROOT = Path(__file__).resolve().parent.parent
APK_RELEASE_DIR = ROOT / "build" / "app" / "outputs" / "apk" / "release"
EXCLUDED_WIN_EXTS = {".pdb", ".exp", ".lib", ".obj", ".iobj", ".ipdb"}


def run(cmd: str, *, check: bool = True, dry_run: bool = False) -> int:
    """在项目根目录执行 shell 命令（路径均用 ROOT 锚定）。"""
    print(f"-> {cmd}")
    if dry_run:
        return 0
    ret = subprocess.run(cmd, shell=True, cwd=str(ROOT), check=False).returncode
    if check and ret != 0:
        raise SystemExit(f"命令执行失败（exit {ret}）：{cmd}")
    return ret


def find_windows_release_dir() -> Path:
    """查找 Windows Release 构建产物目录。"""
    candidates = [
        ROOT / "build" / "windows" / "x64" / "runner" / "Release",
        ROOT / "build" / "windows" / "runner" / "Release",
        ROOT / "build" / "windows" / "arm64" / "runner" / "Release",
    ]
    for c in candidates:
        if (c / f"{APP_NAME}.exe").exists():
            return c
    return candidates[0]


def get_destination() -> tuple[Path, str]:
    """
    解析 pubspec.yaml 版本号并创建 releases/<version>/github 产物目录。

    Returns:
        github (Path): GitHub Release 产物目录。
        version (str): 语义化版本号，如 "1.0.0"。
    """
    pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
    m = re.search(r"version:\s*([0-9][0-9.]*)\+(\d+)", pubspec)
    if m is None:
        raise SystemExit("无法从 pubspec.yaml 解析 version（需形如 'version: x.y.z+<build>'）")
    version = m.group(1)

    github = (ROOT / "releases" / version / "github").resolve()
    github.mkdir(parents=True, exist_ok=True)
    return github, version


def generate_build_info(dry_run: bool = False) -> None:
    """如果存在 build_info 脚本则执行，否则跳过。"""
    info_script = ROOT / "scripts" / "generate_build_info.dart"
    if info_script.exists():
        print("-> 生成构建信息（git hash + 构建时间）")
        run(f"dart run {info_script.relative_to(ROOT).as_posix()}", dry_run=dry_run)
    else:
        print("-> 跳过生成构建信息（未配置 scripts/generate_build_info.dart）")


def copy_file(source: Path, target: Path, dry_run: bool = False) -> None:
    """复制文件到目标路径。"""
    if dry_run:
        print(f"-> [dry-run] 复制 {source} -> {target}")
        return
    if not source.exists():
        raise SystemExit(f"产物缺失：{source}")
    shutil.copy2(src=str(source), dst=str(target))
    print(f"-> {target}")


def zip_windows(github: Path, version: str, dry_run: bool = False) -> None:
    """
    把整个 Windows Release 目录（JigsawFox.exe + 各插件 DLL + data/）打包成 zip。
    排除运行时生成的 logs/ 目录以及 *.pdb 等调试符号。
    """
    dst = github / f"{APP_NAME}-{version}-windows-x64.zip"
    if dry_run:
        print(f"-> [dry-run] 打包 Windows 产物到 {dst}")
        return

    src = find_windows_release_dir()
    exe_path = src / f"{APP_NAME}.exe"
    if not exe_path.exists():
        raise SystemExit(f"Windows 构建产物缺失：{exe_path}")

    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in sorted(src.rglob("*")):
            if f.is_dir():
                continue
            rel = f.relative_to(src).as_posix()
            if rel.startswith("logs/"):
                continue
            if f.suffix.lower() in EXCLUDED_WIN_EXTS:
                continue
            zf.write(f, rel)
    size_mb = dst.stat().st_size / 1024 / 1024
    print(f"-> Windows 打包完成：{dst.name}（{size_mb:.1f} MB）")


def zip_android(github: Path, version: str, dry_run: bool = False) -> None:
    """把全部 Android APK + metadata 汇总打成一个 android zip。"""
    dst = github / f"{APP_NAME}-{version}-android.zip"
    if dry_run:
        print(f"-> [dry-run] 打包 Android zip 到 {dst}")
        return

    apks = sorted(github.glob(f"{APP_NAME}-{version}-*.apk"))
    jsons = sorted(github.glob(f"metadata-{version}-*.json"))
    if not apks:
        print("-> 未发现 APK 产物，跳过 Android zip 打包")
        return

    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in apks:
            zf.write(f, f.name)
        for f in jsons:
            zf.write(f, f.name)
    size_mb = dst.stat().st_size / 1024 / 1024
    print(f"-> Android zip 打包完成：{dst.name}（{size_mb:.1f} MB）")


def write_sha256(github: Path, dry_run: bool = False) -> None:
    """为 Release 目录内所有产物生成 SHA256 校验清单，供下载后核验完整性。"""
    dst = github / "SHA256SUMS.txt"
    if dry_run:
        print(f"-> [dry-run] 生成校验清单 {dst}")
        return

    with open(dst, "w", encoding="utf-8") as out:
        for f in sorted(github.iterdir()):
            if not f.is_file() or f.name == "SHA256SUMS.txt":
                continue
            if f.suffix.lower() not in (".zip", ".apk", ".json"):
                continue
            digest = hashlib.sha256(f.read_bytes()).hexdigest()
            out.write(f"{digest}  {f.name}\n")
    print(f"-> 校验清单就绪：{dst.name}")


def find_apk_file(filename: str) -> Path:
    """在 Gradle/Flutter APK 输出路径中查找指定文件。"""
    candidates = [
        ROOT / "build" / "app" / "outputs" / "apk" / "release" / filename,
        ROOT / "build" / "app" / "outputs" / "flutter-apk" / filename,
    ]
    for c in candidates:
        if c.exists():
            return c
    return candidates[0]


def build_android(
    github: Path,
    version: str,
    *,
    split_abi: bool = True,
    dry_run: bool = False,
) -> None:
    """执行 Android 构建与收集。"""
    if split_abi:
        print("\n--- [Android] 构建分 ABI APK（arm / arm64 / x64）---")
        run(
            "flutter build apk --release --split-per-abi "
            "--target-platform android-arm,android-arm64,android-x64",
            dry_run=dry_run,
        )
        copy_file(find_apk_file("app-x86_64-release.apk"), github / f"{APP_NAME}-{version}-x86_64.apk", dry_run=dry_run)
        copy_file(find_apk_file("app-arm64-v8a-release.apk"), github / f"{APP_NAME}-{version}-arm64-v8a.apk", dry_run=dry_run)
        copy_file(find_apk_file("app-armeabi-v7a-release.apk"), github / f"{APP_NAME}-{version}-armeabi-v7a.apk", dry_run=dry_run)
        meta_split = find_apk_file("output-metadata.json")
        if meta_split.exists() or dry_run:
            copy_file(meta_split, github / f"metadata-{version}-split-per-abi.json", dry_run=dry_run)

    print("\n--- [Android] 构建全 ABI 通用 fat APK ---")
    run("flutter build apk --release", dry_run=dry_run)
    copy_file(find_apk_file("app-release.apk"), github / f"{APP_NAME}-{version}-all.apk", dry_run=dry_run)
    meta_all = find_apk_file("output-metadata.json")
    if meta_all.exists() or dry_run:
        copy_file(meta_all, github / f"metadata-{version}-all.json", dry_run=dry_run)

    zip_android(github, version, dry_run=dry_run)


def build_windows(github: Path, version: str, *, dry_run: bool = False) -> None:
    """执行 Windows 构建与打包。"""
    print("\n--- [Windows] 构建 Release 桌面程序 ---")
    run("flutter build windows --release", dry_run=dry_run)
    zip_windows(github, version, dry_run=dry_run)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=f"{APP_NAME} Release 打包脚本")
    parser.add_argument(
        "-p",
        "--platform",
        choices=["all", "windows", "android"],
        default="all",
        help="指定构建平台：all（全部）、windows（仅 Windows）、android（仅 Android），默认为 all",
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        help="构建前执行 flutter clean && flutter pub get（清理缓存，构建耗时增加）",
    )
    parser.add_argument(
        "--no-split-abi",
        action="store_true",
        help="跳过 Android 分 ABI 构建，仅构建通用 fat APK",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="预演模式：仅打印构建步骤和命令，不实际执行构建与打包",
    )
    return parser.parse_args()


def make_release() -> None:
    args = parse_args()
    github, version = get_destination()

    print(f"== {APP_NAME} 发布构建 (v{version}) ==")
    print(f"目标平台: {args.platform}")
    print(f"输出目录: {github}")

    generate_build_info(dry_run=args.dry_run)

    if args.clean:
        print("\n--- 执行工程清理与依赖获取 ---")
        run("flutter clean && flutter pub get", dry_run=args.dry_run)

    if args.platform in ("all", "android"):
        build_android(github, version, split_abi=not args.no_split_abi, dry_run=args.dry_run)

    if args.platform in ("all", "windows"):
        build_windows(github, version, dry_run=args.dry_run)

    print("\n--- 生成 SHA256 校验清单 ---")
    write_sha256(github, dry_run=args.dry_run)

    print(f"\n== Release 产物已就绪：{github} ==")
    if not args.dry_run:
        for f in sorted(github.iterdir()):
            if f.is_file():
                print(f"  - {f.name}（{f.stat().st_size / 1024 / 1024:.1f} MB）")

    print(
        "\nGitHub 发布命令示例：\n"
        f"  gh release create v{version} {github}/*.zip {github}/*.apk {github}/SHA256SUMS.txt \\\n"
        f"    --title '{APP_NAME} v{version}' --notes '...'"
    )


if __name__ == "__main__":
    make_release()
