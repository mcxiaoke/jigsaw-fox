#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
release_app.py — App 自动更新发版与全链路完整性巡检工具（支持分 ABI 与通用包）

依据设计文档：docs/app-auto-update-design-20260914.md

核心特性：
1. Android 支持按 ABI 分包（arm64-v8a, armeabi-v7a, x86_64, all），大幅缩减客户端下载包体积
2. 自动化完整性校验：
   - verify --local: 检查本地安装包、SHA256、线上版本递增门禁、APK 签名有效性与 aapt versionCode
   - verify --remote: 流式抓取远端 updates.json，探测并校验所有平台所有 ABI 的主源与全部镜像，
                      真实下载 APK 二进制验证 apksigner 签名有效性与 aapt versionCode
3. publish 安全时序发版：
   [本地校验] -> [上传所有安装包至 R2/备源] -> [远端真机下载各 ABI 验签+验版本] -> [最后更新 updates.json] -> [远端终检巡检]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
PUBSPEC_PATH = PROJECT_ROOT / "pubspec.yaml"
OUTPUT_DIR = PROJECT_ROOT / "temp" / "app-release"
R2_APP_BASE = "https://jigsawdata.umao.top/"
UPDATES_JSON_REMOTE = f"{R2_APP_BASE}app/updates.json"
R2_REMOTE_PREFIX = "r2:jigsaw-data/app"

# GMT+8 时区
TZ_CN = timezone(timedelta(hours=8))


def log_info(msg: str) -> None:
    print(f"[INFO] {msg}")


def log_warn(msg: str) -> None:
    print(f"[WARN] {msg}")


def log_error(msg: str) -> None:
    print(f"[ERROR] {msg}", file=sys.stderr)


def log_success(msg: str) -> None:
    print(f"[SUCCESS] {msg}")


def get_pubspec_version(pubspec_path: Path = PUBSPEC_PATH) -> Tuple[str, int]:
    """从 pubspec.yaml 解析 version: x.y.z+N"""
    if not pubspec_path.is_file():
        raise FileNotFoundError(f"pubspec.yaml 不存在: {pubspec_path}")

    content = pubspec_path.read_text(encoding="utf-8")
    match = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)", content, re.MULTILINE)
    if not match:
        raise ValueError("未能从 pubspec.yaml 提取到合法的 version: x.y.z+N 格式")

    version_name = match.group(1)
    version_code = int(match.group(2))
    return version_name, version_code


def calculate_sha256_and_size(file_path: Path) -> Tuple[str, int]:
    """计算本地文件的 SHA256 哈希值与字节数"""
    if not file_path.is_file():
        raise FileNotFoundError(f"目标文件不存在: {file_path}")

    sha256 = hashlib.sha256()
    size = 0
    with open(file_path, "rb") as f:
        while chunk := f.read(1024 * 1024):
            sha256.update(chunk)
            size += len(chunk)
    return sha256.hexdigest(), size


def find_android_tool(tool_name: str) -> Optional[str]:
    """自动探测 aapt 或 apksigner 可执行路径"""
    found = shutil.which(tool_name)
    if found:
        return found

    if os.name == "nt":
        for ext in [".bat", ".exe", ".cmd"]:
            found = shutil.which(f"{tool_name}{ext}")
            if found:
                return found

    android_home = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if not android_home and Path("C:/Home/Develop/android-sdk").is_dir():
        android_home = "C:/Home/Develop/android-sdk"

    if android_home:
        build_tools_dir = Path(android_home) / "build-tools"
        if build_tools_dir.is_dir():
            versions = sorted(build_tools_dir.iterdir(), reverse=True)
            for v_dir in versions:
                if not v_dir.is_dir():
                    continue
                candidates = [
                    v_dir / tool_name,
                    v_dir / f"{tool_name}.exe",
                    v_dir / f"{tool_name}.bat",
                ]
                for c in candidates:
                    if c.is_file():
                        return str(c)
    return None


def verify_apk_binary(apk_path: Path, expected_version_code: Optional[int] = None) -> Dict[str, Any]:
    """
    深度校验 APK 二进制文件：
    1. 使用 apksigner verify 校验签名有效性
    2. 使用 aapt dump badging 解析并校验 versionCode
    """
    if not apk_path.is_file():
        raise FileNotFoundError(f"APK 文件不存在: {apk_path}")

    result: Dict[str, Any] = {
        "verified_signature": False,
        "package_name": None,
        "version_code": None,
        "version_name": None,
        "tools_used": [],
    }

    # 1. 签名校验 (apksigner)
    apksigner = find_android_tool("apksigner")
    if apksigner:
        result["tools_used"].append("apksigner")
        cmd = [apksigner, "verify", "--verbose", str(apk_path)]
        shell_needed = apksigner.lower().endswith(".bat")
        proc = subprocess.run(cmd, capture_output=True, text=True, shell=shell_needed)
        if proc.returncode != 0:
            raise ValueError(f"APK 签名校验失败 ({apk_path.name}, 返回码 {proc.returncode}):\n{proc.stderr}\n{proc.stdout}")
        result["verified_signature"] = True
        log_info(f"APK 签名校验通过: {apk_path.name} (via {Path(apksigner).name})")
    else:
        log_warn(f"未找到 apksigner 工具，退回使用 ZIP 签名文件基础检查: {apk_path.name}")
        import zipfile
        with zipfile.ZipFile(apk_path, "r") as z:
            signatures = [n for n in z.namelist() if n.startswith("META-INF/") and (n.endswith(".RSA") or n.endswith(".DSA") or n.endswith(".EC"))]
            if not signatures:
                raise ValueError(f"APK 文件中未找到任何 META-INF 签名证书！可能为未签名包: {apk_path.name}")
        result["verified_signature"] = True

    # 2. 元数据与 versionCode 校验 (aapt)
    aapt = find_android_tool("aapt")
    if aapt:
        result["tools_used"].append("aapt")
        cmd = [aapt, "dump", "badging", str(apk_path)]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            raise ValueError(f"aapt dump badging 解析失败 ({apk_path.name}): {proc.stderr}")

        output = proc.stdout
        match = re.search(r"package:\s+name='([^']+)'\s+versionCode='(\d+)'\s+versionName='([^']*)'", output)
        if match:
            result["package_name"] = match.group(1)
            result["version_code"] = int(match.group(2))
            result["version_name"] = match.group(3)

            log_info(f"APK 元数据: {apk_path.name} -> package={result['package_name']}, "
                     f"versionCode={result['version_code']}, versionName={result['version_name']}")

            if expected_version_code is not None and result["version_code"] != expected_version_code:
                raise ValueError(
                    f"APK versionCode 不匹配！文件: {apk_path.name}, 预期: {expected_version_code}, 实际: {result['version_code']}"
                )
        else:
            log_warn(f"未能从 aapt dump badging 输出中解析到 package 格式: {apk_path.name}")
    else:
        log_warn("未找到 aapt 工具，跳过 aapt 元数据深度比对")

    return result


def fetch_remote_stream_and_verify(
    url: str,
    expected_sha256: str,
    expected_size: int,
    save_to_file: Optional[Path] = None,
    timeout: int = 60,
) -> Tuple[str, int]:
    """流式下载远程文件，实时计算 SHA256 与文件大小，并与预期值强比对"""
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "JigsawReleaseChecker/1.0", "Cache-Control": "no-cache"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                raise ValueError(f"HTTP 请求返回非 200 状态码: {resp.status} ({url})")

            sha256 = hashlib.sha256()
            downloaded_size = 0
            out_file = open(save_to_file, "wb") if save_to_file else None

            try:
                while chunk := resp.read(1024 * 1024):
                    sha256.update(chunk)
                    downloaded_size += len(chunk)
                    if out_file:
                        out_file.write(chunk)
            finally:
                if out_file:
                    out_file.close()

    except urllib.error.HTTPError as e:
        raise ValueError(f"HTTP 请求失败 ({e.code} {e.reason}): {url}") from e
    except urllib.error.URLError as e:
        raise ValueError(f"网络连接异常 ({e.reason}): {url}") from e

    calc_sha = sha256.hexdigest().lower()
    exp_sha = expected_sha256.lower()

    if downloaded_size != expected_size:
        raise ValueError(
            f"文件大小不匹配 ({url})！预期: {expected_size} 字节, 实际下载: {downloaded_size} 字节"
        )

    if calc_sha != exp_sha:
        raise ValueError(
            f"SHA256 哈希校验失败 ({url})！\n预期: {exp_sha}\n实际: {calc_sha}"
        )

    return calc_sha, downloaded_size


def fetch_remote_updates_json(url: str = UPDATES_JSON_REMOTE) -> Optional[Dict[str, Any]]:
    """拉取线上当前的 updates.json，若 404 返回 None"""
    try:
        req = urllib.request.Request(
            url,
            headers={"User-Agent": "JigsawReleaseChecker/1.0", "Cache-Control": "no-cache"},
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            if resp.status == 200:
                data = resp.read().decode("utf-8")
                return json.loads(data)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        log_warn(f"拉取线上 updates.json 异常: {e.code}")
    except Exception as e:
        log_warn(f"拉取线上 updates.json 失败: {e}")
    return None


def flatten_platform_entries(platforms: Dict[str, Any]) -> List[Tuple[str, Optional[str], Dict[str, Any]]]:
    """
    扁平化解析 platforms：
    返回列表: [(platform_name, sub_key_or_abi, info_dict), ...]
    例如:
      ('android', 'arm64-v8a', {url, sha256, size, mirrors})
      ('android', 'all', {url, sha256, size, mirrors})
      ('windows', None, {url, sha256, size, mirrors})
    """
    entries = []
    for plat_name, value in platforms.items():
        if not isinstance(value, dict):
            continue
        if "url" in value:
            # 单包格式
            entries.append((plat_name, None, value))
        else:
            # 分 ABI 或子架构字典
            for sub_key, sub_val in value.items():
                if isinstance(sub_val, dict) and "url" in sub_val:
                    entries.append((plat_name, sub_key, sub_val))
    return entries


def generate_manifest(
    version_name: str,
    version_code: int,
    platforms_data: Dict[str, Any],
    min_version_code: int = 1,
    notes: Optional[Dict[str, str]] = None,
) -> Dict[str, Any]:
    """生成符合规范的 updates.json 字典"""
    now_iso = datetime.now(TZ_CN).replace(microsecond=0).isoformat()
    if notes is None:
        notes = {
            "zh-CN": f"更新版本 {version_name}，修复若干问题并提升稳定性。",
            "en-US": f"Version {version_name} release with bug fixes and improvements.",
        }

    return {
        "schema": 1,
        "version": version_name,
        "versionCode": version_code,
        "minVersionCode": min_version_code,
        "publishedAt": now_iso,
        "notes": notes,
        "platforms": platforms_data,
    }


# ==============================================================================
# 命令实现
# ==============================================================================

def cmd_prepare(args: argparse.Namespace) -> Path:
    """生成本地 updates.json 与版本产物准备（支持分 ABI）"""
    version_name, version_code = get_pubspec_version()
    log_info(f"从 pubspec.yaml 提取版本: {version_name}+{version_code}")

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    platforms_data: Dict[str, Any] = {}

    # 1. 扫描 Android APK（分 ABI 优先）
    # 查找目录候选：releases/<version>/github/ -> build/app/outputs/flutter-apk/ -> temp/app-release/android/
    apk_search_dirs = [
        PROJECT_ROOT / "releases" / version_name / "github",
        PROJECT_ROOT / "build" / "app" / "outputs" / "flutter-apk",
        PROJECT_ROOT / "build" / "app" / "outputs" / "apk" / "release",
        OUTPUT_DIR / "android",
    ]
    if args.apk_dir:
        apk_search_dirs.insert(0, Path(args.apk_dir))

    abi_map: Dict[str, Path] = {}
    known_abis = ["arm64-v8a", "armeabi-v7a", "x86_64", "all"]

    for d in apk_search_dirs:
        if not d.is_dir():
            continue
        for f in d.glob("*.apk"):
            fname = f.name.lower()
            if "arm64-v8a" in fname and "arm64-v8a" not in abi_map:
                abi_map["arm64-v8a"] = f
            elif "armeabi-v7a" in fname and "armeabi-v7a" not in abi_map:
                abi_map["armeabi-v7a"] = f
            elif "x86_64" in fname and "x86_64" not in abi_map:
                abi_map["x86_64"] = f
            elif ("all" in fname or fname == "app-release.apk" or "universal" in fname) and "all" not in abi_map:
                abi_map["all"] = f

    if abi_map:
        android_dict: Dict[str, Any] = {}
        for abi_key, apk_file in abi_map.items():
            sha256, size = calculate_sha256_and_size(apk_file)
            verify_apk_binary(apk_file, expected_version_code=version_code)

            rel_url = f"app/{version_name}+{version_code}/android/{apk_file.name}"
            android_dict[abi_key] = {
                "url": rel_url,
                "sha256": sha256,
                "size": size,
                "mirrors": [
                    f"https://github.com/mcxiaoke/jigsaw-fox/releases/download/v{version_name}/{apk_file.name}",
                    f"https://gitee.com/mcxiaoke/jigsaw-fox/releases/download/v{version_name}/{apk_file.name}",
                ],
            }
            log_success(f"已包含 Android [{abi_key}]: {apk_file.name} ({size} bytes, sha256={sha256[:12]}...)")

        # 若只有一个且是 all，也可以直接输出单包结构兼容旧客户端，但输出分 ABI 字典新客户端更优
        platforms_data["android"] = android_dict
    else:
        log_warn("未在常见目录中找到任何 Android APK 构建产物")

    # 2. 扫描 Windows 安装包 / 绿色 Zip
    win_search_dirs = [
        PROJECT_ROOT / "releases" / version_name / "github",
        PROJECT_ROOT / "releases",
        OUTPUT_DIR / "windows",
    ]
    if args.windows_path:
        win_candidates = [Path(args.windows_path)]
    else:
        win_candidates = []
        for d in win_search_dirs:
            if not d.is_dir():
                continue
            win_candidates.extend(d.glob(f"*{version_name}*.zip"))
            win_candidates.extend(d.glob(f"*{version_name}*.exe"))

    win_file: Optional[Path] = None
    for c in win_candidates:
        if c.is_file():
            win_file = c
            break

    if win_file:
        sha256, size = calculate_sha256_and_size(win_file)
        rel_url = f"app/{version_name}+{version_code}/windows/{win_file.name}"
        platforms_data["windows"] = {
            "url": rel_url,
            "sha256": sha256,
            "size": size,
            "mirrors": [
                f"https://github.com/mcxiaoke/jigsaw-fox/releases/download/v{version_name}/{win_file.name}",
                f"https://gitee.com/mcxiaoke/jigsaw-fox/releases/download/v{version_name}/{win_file.name}",
            ],
        }
        log_success(f"已包含 Windows 产物: {win_file.name} ({size} bytes, sha256={sha256[:12]}...)")
    else:
        log_warn("未找到 Windows 产物文件 (*.zip / *.exe)")

    if not platforms_data:
        raise ValueError("未能找到任何平台的构建产物！请先执行发布构建。")

    manifest = generate_manifest(
        version_name=version_name,
        version_code=version_code,
        platforms_data=platforms_data,
        min_version_code=args.min_version_code or 1,
    )

    out_json = OUTPUT_DIR / "updates.json"
    out_json.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    log_success(f"已生成 updates.json -> {out_json}")
    return out_json


def cmd_verify_local(manifest_path: Path) -> None:
    """本地深度校验：产物存在性、哈希、线上版本递增门禁、本地各 ABI APK 验签"""
    log_info("=== 执行本地验证 (verify --local) ===")
    if not manifest_path.is_file():
        raise FileNotFoundError(f"清单文件不存在: {manifest_path}")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    local_version_code = manifest.get("versionCode")
    if not local_version_code:
        raise ValueError("清单中缺少 versionCode")

    # 1. 检查线上版本递增门禁
    online_manifest = fetch_remote_updates_json()
    if online_manifest:
        online_code = online_manifest.get("versionCode", 0)
        log_info(f"线上当前 versionCode={online_code}，本地待发布 versionCode={local_version_code}")
        if local_version_code <= online_code:
            raise ValueError(
                f"版本递增门禁失败！本地 versionCode ({local_version_code}) 必须大于线上当前值 ({online_code})"
            )
        log_success("版本号单调递增门禁检查通过")
    else:
        log_info("线上暂无 updates.json 或首次发版，跳过版本递增比对")

    # 2. 扁平遍历校验各平台与各 ABI 产物
    entries = flatten_platform_entries(manifest.get("platforms", {}))
    if not entries:
        raise ValueError("清单中 platforms 为空")

    for plat_name, sub_key, info in entries:
        tag_name = f"{plat_name}/{sub_key}" if sub_key else plat_name
        exp_sha = info["sha256"]
        exp_size = info["size"]
        file_name = Path(info["url"]).name
        log_info(f"校验本地平台产物 [{tag_name}]: {file_name} ...")

        # 查找本地对应文件
        search_dirs = [
            PROJECT_ROOT / "releases" / manifest.get("version", "") / "github",
            PROJECT_ROOT / "build" / "app" / "outputs" / "flutter-apk",
            OUTPUT_DIR / plat_name,
            PROJECT_ROOT / "releases",
        ]
        found_file = None
        for d in search_dirs:
            c = d / file_name
            if c.is_file():
                found_file = c
                break

        if found_file:
            calc_sha, calc_size = calculate_sha256_and_size(found_file)
            if calc_size != exp_size or calc_sha.lower() != exp_sha.lower():
                raise ValueError(
                    f"本地产物哈希/大小与 updates.json 不一致: {found_file}\n"
                    f"预期: size={exp_size}, sha256={exp_sha}\n"
                    f"实际: size={calc_size}, sha256={calc_sha}"
                )
            if found_file.suffix.lower() == ".apk":
                verify_apk_binary(found_file, expected_version_code=local_version_code)
            log_success(f"本地平台产物 [{tag_name}] 校验通过: {found_file.name}")
        else:
            log_warn(f"未找到本地平台产物物理文件 [{tag_name}]: {file_name}")

    log_success("=== 本地验证全部通过 ===")


def cmd_verify_remote(url: str = UPDATES_JSON_REMOTE) -> None:
    """
    远程全链路深度巡检：
    1. 拉取远端 updates.json 并校验 Schema
    2. 流式探测并下载所有平台所有 ABI 的主源与全部镜像
    3. 校验实际计算 SHA256 和 Size 与声明完全一致
    4. 对远端下载的每个 Android APK 执行 apksigner 签名验证与 aapt versionCode 比对
    """
    log_info(f"=== 开始远程全链路深度巡检: {url} ===")
    manifest = fetch_remote_updates_json(url)
    if not manifest:
        raise ValueError(f"无法拉取或解析远程 updates.json: {url}")

    version_name = manifest.get("version")
    version_code = manifest.get("versionCode")
    platforms = manifest.get("platforms", {})

    entries = flatten_platform_entries(platforms)
    log_info(f"远端版本: {version_name}+{version_code}, 包含产物条目数: {len(entries)}")
    if not entries:
        raise ValueError("远程 updates.json 的 platforms 为空！")

    with tempfile.TemporaryDirectory(prefix="jigsaw_verify_") as tmp_dir:
        tmp_path = Path(tmp_dir)

        for plat_name, sub_key, info in entries:
            tag_name = f"{plat_name}/{sub_key}" if sub_key else plat_name
            exp_sha = info["sha256"]
            exp_size = info["size"]
            main_url = info["url"]
            if not main_url.startswith("http"):
                main_url = urllib.parse.urljoin(R2_APP_BASE, main_url)

            all_urls = [("main", main_url)]
            for idx, mirror in enumerate(info.get("mirrors", [])):
                all_urls.append((f"mirror-{idx+1}", mirror))

            log_info(f"\n--- 巡检平台产物 [{tag_name}] (共 {len(all_urls)} 个下载来源) ---")

            downloaded_apk_path: Optional[Path] = None

            for label, test_url in all_urls:
                log_info(f"[{tag_name}][{label}] 探测并流式校验: {test_url}")
                save_file = None
                if plat_name == "android" and downloaded_apk_path is None:
                    safe_tag = tag_name.replace("/", "_")
                    save_file = tmp_path / f"remote_{safe_tag}_{label}.apk"

                calc_sha, calc_size = fetch_remote_stream_and_verify(
                    url=test_url,
                    expected_sha256=exp_sha,
                    expected_size=exp_size,
                    save_to_file=save_file,
                )
                log_success(f"[{tag_name}][{label}] 校验通过: {calc_size} 字节, SHA256 匹配")

                if save_file and save_file.is_file():
                    downloaded_apk_path = save_file

            # 若为 Android APK，对远端下载文件进行真实签名与版本比对
            if plat_name == "android" and downloaded_apk_path:
                log_info(f"正在对远端下载的 [{tag_name}] 进行本地签名与 versionCode 深度验签...")
                verify_apk_binary(downloaded_apk_path, expected_version_code=version_code)
                log_success(f"远端下载 [{tag_name}] 验签与版本号比对全部通过！")

    log_success("=== 远程全链路巡检通过！线上所有平台所有 ABI 安装包 100% 存在、哈希完全匹配且无损坏 ===")


def cmd_publish(args: argparse.Namespace) -> None:
    """
    安全时序发布：
    1. 本地 pre-flight 深度校验
    2. rclone copy 上传所有平台所有 ABI 安装包到 R2
    3. 远端真实下载所有 APK 进行深度验签
    4. 校验通过后，最后上传 updates.json 切生效
    5. verify --remote 线上终检
    """
    log_info("=== 开始执行 App 发布流程 ===")
    out_json = cmd_prepare(args)
    cmd_verify_local(out_json)

    manifest = json.loads(out_json.read_text(encoding="utf-8"))
    version_name = manifest["version"]
    version_code = manifest["versionCode"]

    if args.dry_run:
        log_info("[DRY RUN] 演练模式：跳过实际文件上传与远端写入")
        return

    if not shutil.which("rclone"):
        raise EnvironmentError("系统中未找到 rclone 命令，请先配置 rclone 访问 R2 存储桶")

    entries = flatten_platform_entries(manifest.get("platforms", {}))

    # 1. 上传各安装包到 R2
    log_info("Step 1: 上传各平台与各 ABI 安装包到 R2...")
    for plat_name, sub_key, info in entries:
        tag_name = f"{plat_name}/{sub_key}" if sub_key else plat_name
        rel_url = info["url"]
        file_name = Path(rel_url).name
        r2_dest_dir = f"{R2_REMOTE_PREFIX}/{Path(rel_url).parent.as_posix()}"

        search_dirs = [
            PROJECT_ROOT / "releases" / version_name / "github",
            PROJECT_ROOT / "build" / "app" / "outputs" / "flutter-apk",
            OUTPUT_DIR / plat_name,
            PROJECT_ROOT / "releases",
        ]
        local_file = None
        for d in search_dirs:
            c = d / file_name
            if c.is_file():
                local_file = c
                break

        if local_file and local_file.is_file():
            log_info(f"rclone copy [{tag_name}] {local_file.name} -> {r2_dest_dir}")
            subprocess.run(["rclone", "copy", str(local_file), r2_dest_dir], check=True)
        else:
            raise FileNotFoundError(f"未找到待上传的本地文件: {file_name}")

    # 2. 远端下载二进制深度验签
    log_info("\nStep 2: 从远端真实下载刚刚上传的所有安装包进行深度验签...")
    with tempfile.TemporaryDirectory(prefix="jigsaw_publish_verify_") as tmp_dir:
        tmp_path = Path(tmp_dir)
        for plat_name, sub_key, info in entries:
            tag_name = f"{plat_name}/{sub_key}" if sub_key else plat_name
            main_url = info["url"]
            if not main_url.startswith("http"):
                main_url = urllib.parse.urljoin(R2_APP_BASE, main_url)

            safe_tag = tag_name.replace("/", "_")
            down_path = tmp_path / f"target_{safe_tag}.bin"
            log_info(f"下载远端主源文件 [{tag_name}]: {main_url}")
            fetch_remote_stream_and_verify(
                url=main_url,
                expected_sha256=info["sha256"],
                expected_size=info["size"],
                save_to_file=down_path,
            )
            if plat_name == "android":
                log_info(f"深度校验远端下载的 [{tag_name}] 签名与 versionCode...")
                verify_apk_binary(down_path, expected_version_code=version_code)
                log_success(f"远端下载 [{tag_name}] 验签通过！")

    # 3. 最后上传 updates.json
    log_info("\nStep 3: 远端所有安装包深度校验全绿，上传 updates.json 切生效...")
    subprocess.run(["rclone", "copy", str(out_json), f"{R2_REMOTE_PREFIX}/"], check=True)
    log_success("updates.json 已上线！")

    # 4. 端到端巡检
    log_info("\nStep 4: 执行全链路巡检终检 (verify --remote)...")
    cmd_verify_remote()
    log_success(f"=== App 版本 {version_name}+{version_code} 发布并巡检成功！===")


def main() -> None:
    parser = argparse.ArgumentParser(description="App 自动更新发布与完整性巡检编排工具（支持分 ABI）")
    subparsers = parser.add_subparsers(dest="subcommand", required=True)

    # prepare
    p_prep = subparsers.add_parser("prepare", help="准备版本产物并生成 updates.json")
    p_prep.add_argument("--apk-dir", help="指定 APK 所在目录")
    p_prep.add_argument("--windows-path", help="指定 Windows 安装包或 Zip 路径")
    p_prep.add_argument("--min-version-code", type=int, help="最低强制更新版本号")

    # verify
    p_ver = subparsers.add_parser("verify", help="完整性验证与巡检")
    p_ver.add_argument("--local", action="store_true", help="执行本地硬门禁校验")
    p_ver.add_argument("--remote", action="store_true", help="执行远端全链路巡检与验签")
    p_ver.add_argument("--url", default=UPDATES_JSON_REMOTE, help="指定远程 updates.json URL")
    p_ver.add_argument("--manifest", default=str(OUTPUT_DIR / "updates.json"), help="指定本地 updates.json 路径")
    p_ver.add_argument("--apk-dir", help="指定 APK 所在目录")

    # publish
    p_pub = subparsers.add_parser("publish", help="安全时序发版")
    p_pub.add_argument("--dry-run", action="store_true", help="仅演练，不实际上传")
    p_pub.add_argument("--apk-dir", help="指定 APK 所在目录")
    p_pub.add_argument("--windows-path", help="指定 Windows 安装包或 Zip 路径")
    p_pub.add_argument("--min-version-code", type=int, help="最低强制更新版本号")

    args = parser.parse_args()

    if args.subcommand == "prepare":
        cmd_prepare(args)
    elif args.subcommand == "verify":
        if args.remote:
            cmd_verify_remote(args.url)
        else:
            manifest_p = Path(args.manifest)
            if not manifest_p.is_file():
                manifest_p = cmd_prepare(args)
            cmd_verify_local(manifest_p)
    elif args.subcommand == "publish":
        cmd_publish(args)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log_error(f"执行失败: {e}")
        sys.exit(1)
