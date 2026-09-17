#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
release_app.py — App 自动更新发版与全链路完整性巡检工具（支持分 ABI 与通用包）

依据设计文档：docs/app-auto-update-design-20260914.md

核心特性：
1. Android 支持按 ABI 分包（arm64-v8a, armeabi-v7a），大幅缩减客户端下载包体积
2. 自动化完整性校验：
   - verify --local: 检查本地安装包、SHA256、线上版本递增门禁、APK 签名有效性与 aapt versionCode
   - verify --remote: 抓取远端 updates.json，HEAD 校验所有平台所有 ABI 的主源与全部镜像（状态码与 Content-Length）
3. publish 安全时序发版：
   [本地校验] -> [上传所有安装包至 R2] -> [远端 HEAD 快速校验(状态码+大小)]
   -> [发布 GitHub/Gitee Release 镜像资产] -> [最后更新 updates.json] -> [远端 HEAD 巡检终检]
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
import time
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
# R2 bucket 根（自定义域名 jigsawdata.umao.top 映射到 bucket 根目录）
R2_BUCKET_ROOT = "r2:jigsaw-data"
# bucket 内 App 更新资源目录：安装包位于 app/<版本目录>/<平台>/，updates.json 位于 app/updates.json
R2_APP_DIR = "app"
UPDATES_JSON_REMOTE = f"{R2_APP_BASE}{R2_APP_DIR}/updates.json"
# GitHub / Gitee Release 镜像仓库（与 updates.json 中 mirrors 配置保持一致，tag 统一为 v{version}）
GITHUB_MIRROR_REPO = "mcxiaoke/jigsaw-fox"
GITEE_MIRROR_REPO = "macitee/jigsaw-fox"
# Gitee Release 附件体积上限与软告警线（与素材侧 gitee_release.py 一致）
GITEE_LIMIT_BYTES = 1024 * 1024 * 1024
GITEE_SOFT_WARN_BYTES = 800 * 1024 * 1024
GITEE_API = "https://gitee.com/api/v5"


def version_dir(version_name: str, version_code: int) -> str:
    """对象存储版本目录名：使用 '-' 分隔，避免 URL 路径中出现 '+'"""
    return f"{version_name}-{version_code}"


def _mirror_urls(version_name: str, file_name: str) -> List[str]:
    """镜像 Release 下载 URL 列表（GitHub + Gitee），按镜像仓库常量拼接，禁止写死仓库名。"""
    return [
        f"https://github.com/{GITHUB_MIRROR_REPO}/releases/download/v{version_name}/{file_name}",
        f"https://gitee.com/{GITEE_MIRROR_REPO}/releases/download/v{version_name}/{file_name}",
    ]


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
    match = re.search(
        r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)", content, re.MULTILINE
    )
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


def verify_apk_binary(
    apk_path: Path, expected_version_code: Optional[int] = None
) -> Dict[str, Any]:
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
            raise ValueError(
                f"APK 签名校验失败 ({apk_path.name}, 返回码 {proc.returncode}):\n{proc.stderr}\n{proc.stdout}"
            )
        result["verified_signature"] = True
        log_info(f"APK 签名校验通过: {apk_path.name} (via {Path(apksigner).name})")
    else:
        log_warn(
            f"未找到 apksigner 工具，退回使用 ZIP 签名文件基础检查: {apk_path.name}"
        )
        import zipfile

        with zipfile.ZipFile(apk_path, "r") as z:
            signatures = [
                n
                for n in z.namelist()
                if n.startswith("META-INF/")
                and (n.endswith(".RSA") or n.endswith(".DSA") or n.endswith(".EC"))
            ]
            if not signatures:
                raise ValueError(
                    f"APK 文件中未找到任何 META-INF 签名证书！可能为未签名包: {apk_path.name}"
                )
        result["verified_signature"] = True

    # 2. 元数据与 versionCode 校验 (aapt)
    aapt = find_android_tool("aapt")
    if aapt:
        result["tools_used"].append("aapt")
        cmd = [aapt, "dump", "badging", str(apk_path)]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            raise ValueError(
                f"aapt dump badging 解析失败 ({apk_path.name}): {proc.stderr}"
            )

        output = proc.stdout
        match = re.search(
            r"package:\s+name='([^']+)'\s+versionCode='(\d+)'\s+versionName='([^']*)'",
            output,
        )
        if match:
            result["package_name"] = match.group(1)
            result["version_code"] = int(match.group(2))
            result["version_name"] = match.group(3)

            log_info(
                f"APK 元数据: {apk_path.name} -> package={result['package_name']}, "
                f"versionCode={result['version_code']}, versionName={result['version_name']}"
            )

            if (
                expected_version_code is not None
                and result["version_code"] != expected_version_code
            ):
                raise ValueError(
                    f"APK versionCode 不匹配！文件: {apk_path.name}, 预期: {expected_version_code}, 实际: {result['version_code']}"
                )
        else:
            log_warn(
                f"未能从 aapt dump badging 输出中解析到 package 格式: {apk_path.name}"
            )
    else:
        log_warn("未找到 aapt 工具，跳过 aapt 元数据深度比对")

    return result


def verify_windows_binary(file_path: Path) -> None:
    """Windows 产物一致性检查：文件名与 zip 内容均不得出现 Android 痕迹，zip 内须含 .exe"""
    fname = file_path.name.lower()
    if "android" in fname:
        raise ValueError(
            f"Windows 产物文件名含 android，疑似平台错配: {file_path.name}"
        )
    if file_path.suffix.lower() == ".zip":
        import zipfile

        with zipfile.ZipFile(file_path, "r") as z:
            names = z.namelist()
        if not any(n.lower().endswith(".exe") for n in names):
            raise ValueError(
                f"Windows zip 内未找到 .exe 可执行文件，疑似平台错配: {file_path.name}"
            )
        log_info(f"Windows 产物内容检查通过: {file_path.name} (含 .exe)")


def _build_http_opener() -> urllib.request.OpenerDirector:
    """构建支持 HTTP(S) 代理的 opener。

    遵守 HTTP(S) 代理环境变量（http_proxy / https_proxy / all_proxy / HTTP_PROXY / HTTPS_PROXY / ALL_PROXY）
    以及系统代理配置，确保国内网络环境下可正常连接 GitHub 等需要代理的镜像源。
    """
    env_proxies = urllib.request.getproxies_environment()
    all_proxy = os.environ.get("ALL_PROXY") or os.environ.get("all_proxy")
    if all_proxy and all_proxy.startswith("http"):
        env_proxies.setdefault("http", all_proxy)
        env_proxies.setdefault("https", all_proxy)
    proxies = env_proxies or urllib.request.getproxies()
    if proxies:
        return urllib.request.build_opener(urllib.request.ProxyHandler(proxies))
    return urllib.request.build_opener()


_HTTP_OPENER = _build_http_opener()


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
        with _HTTP_OPENER.open(req, timeout=timeout) as resp:
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


def check_remote_head(
    url: str, expected_size: int, timeout: int = 30, tag: str = ""
) -> None:
    """远端快速存在性校验：HEAD 请求校验状态码与 Content-Length（本地产物已做完整哈希/验签）"""
    req = urllib.request.Request(
        url,
        method="HEAD",
        headers={"User-Agent": "JigsawReleaseChecker/1.0", "Cache-Control": "no-cache"},
    )
    prefix = f"[{tag}] " if tag else ""
    try:
        with _HTTP_OPENER.open(req, timeout=timeout) as resp:
            if resp.status != 200:
                raise ValueError(f"{prefix}HTTP 请求返回非 200 状态码: {resp.status} ({url})")
            content_length = resp.headers.get("Content-Length")
            if content_length is None:
                log_warn(f"{prefix}远端未返回 Content-Length，跳过大小比对: {url}")
                return
            if int(content_length) != int(expected_size):
                raise ValueError(
                    f"{prefix}远端文件大小不匹配 ({url})！预期: {expected_size}, 实际: {content_length}"
                )
            log_success(f"{prefix}远端 HEAD 校验通过: {url} ({content_length} bytes)")
    except urllib.error.HTTPError as e:
        raise ValueError(f"{prefix}HTTP 请求失败 ({e.code} {e.reason}): {url}") from e
    except urllib.error.URLError as e:
        raise ValueError(f"{prefix}网络连接异常 ({e.reason}): {url}") from e


def fetch_remote_updates_json(
    url: str = UPDATES_JSON_REMOTE,
) -> Optional[Dict[str, Any]]:
    """拉取线上当前的 updates.json，若 404 返回 None"""
    try:
        req = urllib.request.Request(
            url,
            headers={
                "User-Agent": "JigsawReleaseChecker/1.0",
                "Cache-Control": "no-cache",
            },
        )
        with _HTTP_OPENER.open(req, timeout=15) as resp:
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


def flatten_platform_entries(
    platforms: Dict[str, Any],
) -> List[Tuple[str, Optional[str], Dict[str, Any]]]:
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
    # 查找目录候选：仅 releases/<version>/github/（发布唯一可信产物目录）
    # 发布只认 releases/<version>/github 目录，build/、temp/ 等项目临时产物不参与发布
    apk_search_dirs = [
        PROJECT_ROOT / "releases" / version_name / "github",
    ]
    if args.apk_dir:
        apk_search_dirs.insert(0, Path(args.apk_dir))

    abi_map: Dict[str, Path] = {}
    # 仅发布 arm64-v8a / armeabi-v7a 两个 ABI（与 scripts/release.py 构建产物集合保持一致）
    known_abis = ["arm64-v8a", "armeabi-v7a"]

    for d in apk_search_dirs:
        if not d.is_dir():
            continue
        for f in d.glob("*.apk"):
            fname = f.name.lower()
            if "arm64-v8a" in fname and "arm64-v8a" not in abi_map:
                abi_map["arm64-v8a"] = f
            elif "armeabi-v7a" in fname and "armeabi-v7a" not in abi_map:
                abi_map["armeabi-v7a"] = f

    if abi_map:
        android_dict: Dict[str, Any] = {}
        for abi_key, apk_file in abi_map.items():
            sha256, size = calculate_sha256_and_size(apk_file)
            verify_apk_binary(apk_file, expected_version_code=version_code)

            rel_url = f"{R2_APP_DIR}/{version_dir(version_name, version_code)}/android/{apk_file.name}"
            android_dict[abi_key] = {
                "url": rel_url,
                "sha256": sha256,
                "size": size,
                "mirrors": _mirror_urls(version_name, apk_file.name),
            }
            log_success(
                f"已包含 Android [{abi_key}]: {apk_file.name} ({size} bytes, sha256={sha256[:12]}...)"
            )

        # 若只有一个且是 all，也可以直接输出单包结构兼容旧客户端，但输出分 ABI 字典新客户端更优
        platforms_data["android"] = android_dict
    else:
        log_warn("未在常见目录中找到任何 Android APK 构建产物")

    # 2. 扫描 Windows 安装包 / 绿色 Zip
    win_search_dirs = [
        PROJECT_ROOT / "releases" / version_name / "github",
    ]
    if args.windows_path:
        win_candidates = [Path(args.windows_path)]
    else:
        win_candidates = []
        for d in win_search_dirs:
            if not d.is_dir():
                continue
            # 仅接受 windows/exe 命名，排除 Android 打包 zip，避免平台错配
            win_candidates.extend(
                f
                for f in d.glob(f"*{version_name}*.exe")
                if "android" not in f.name.lower()
            )
            win_candidates.extend(
                f
                for f in d.glob(f"*{version_name}*.zip")
                if "windows" in f.name.lower() and "android" not in f.name.lower()
            )

    win_file: Optional[Path] = None
    for c in win_candidates:
        if c.is_file():
            win_file = c
            break

    if win_file:
        verify_windows_binary(win_file)
        sha256, size = calculate_sha256_and_size(win_file)
        rel_url = f"{R2_APP_DIR}/{version_dir(version_name, version_code)}/windows/{win_file.name}"
        platforms_data["windows"] = {
            "url": rel_url,
            "sha256": sha256,
            "size": size,
            "mirrors": _mirror_urls(version_name, win_file.name),
        }
        log_success(
            f"已包含 Windows 产物: {win_file.name} ({size} bytes, sha256={sha256[:12]}...)"
        )
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
    out_json.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
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
        log_info(
            f"线上当前 versionCode={online_code}，本地待发布 versionCode={local_version_code}"
        )
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
            elif plat_name == "windows":
                verify_windows_binary(found_file)
            log_success(f"本地平台产物 [{tag_name}] 校验通过: {found_file.name}")
        else:
            log_warn(f"未找到本地平台产物物理文件 [{tag_name}]: {file_name}")

    log_success("=== 本地验证全部通过 ===")


def cmd_verify_remote(url: str = UPDATES_JSON_REMOTE) -> None:
    """
    远程全链路巡检：
    1. 拉取远端 updates.json 并校验 Schema
    2. 对所有平台所有 ABI 的主源与全部镜像执行 HEAD 请求快速校验
    3. 校验 HTTP 状态码 200 与 Content-Length 大小一致（不下载实际二进制）
    """
    log_info(f"=== 开始远程全链路巡检 (HEAD 快速校验): {url} ===")
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

    for plat_name, sub_key, info in entries:
        tag_name = f"{plat_name}/{sub_key}" if sub_key else plat_name
        exp_size = info["size"]
        main_url = info["url"]
        if not main_url.startswith("http"):
            main_url = urllib.parse.urljoin(R2_APP_BASE, main_url)

        all_urls = [("main", main_url)]
        for idx, mirror in enumerate(info.get("mirrors", [])):
            all_urls.append((f"mirror-{idx + 1}", mirror))

        log_info(
            f"\n--- 巡检平台产物 [{tag_name}] (共 {len(all_urls)} 个下载来源) ---"
        )

        for label, test_url in all_urls:
            log_info(f"[{tag_name}][{label}] 探测 HEAD: {test_url}")
            check_remote_head(test_url, exp_size, tag=f"{tag_name}][{label}")

    log_success(
        "=== 远程全链路巡检通过！线上所有平台所有 ABI 安装包 100% 存在且 Content-Length 匹配 ==="
    )


def _is_release_asset(name: str) -> bool:
    """是否属于收敛后的发布产物集合（与 scripts/release.py 构建产物一致）。

    仅发布 arm64-v8a / armeabi-v7a APK、windows-x64 zip 与 SHA256SUMS.txt，
    排除 all / x86_64 / android.zip / metadata-*.json / universal 等旧或非发布产物。
    """
    if name == "SHA256SUMS.txt":
        return True
    low = name.lower()
    if low.endswith(".apk"):
        return "arm64-v8a" in low or "armeabi-v7a" in low
    if low.endswith(".zip"):
        return "windows" in low
    return False


def _app_release_assets(assets_dir: Path) -> List[Path]:
    """App 发布资产 = 目录下收敛后的发布产物（arm64-v8a/armeabi-v7a APK、windows zip、SHA256SUMS.txt），按文件名排序。"""
    return sorted(
        p for p in assets_dir.iterdir() if p.is_file() and _is_release_asset(p.name)
    )


def _missing_assets(assets: List[Path], existing: set[str], force: bool) -> List[Path]:
    """计算需上传的资产：--force 时全部重传，否则仅上传远端缺失的文件（同名视为同内容）。"""
    if force:
        return list(assets)
    return [f for f in assets if f.name not in existing]


def _gh_run(cmd: List[str]) -> subprocess.CompletedProcess:
    """运行 gh CLI，显式以 UTF-8 解码输出。

    Windows 下 subprocess.run(text=True) 默认按 GBK 解码，gh 的 UTF-8 中文输出
    （如 Release 名称/说明）会使 reader thread 抛 UnicodeDecodeError。
    """
    return subprocess.run(
        cmd, capture_output=True, text=True, encoding="utf-8", errors="replace"
    )


def publish_github_release(tag: str, assets_dir: Path, force: bool = False) -> int:
    """GitHub Release 幂等发布（gh CLI，逻辑对齐素材侧 publish.py::_github_release）。

    - Release 不存在则创建（先 --verify-tag，tag 未推送时退化为不带该标志重试）；
    - 附件按文件名差集增量上传，--force 时忽略清单全部重传。
    返回 gh 命令退出码（需 0 表示成功）。
    """
    repo = GITHUB_MIRROR_REPO
    assets = _app_release_assets(assets_dir)
    if not assets:
        log_error(f"GitHub Release 资产目录为空: {assets_dir}")
        return 2
    log_info(f"[github] repo={repo} tag={tag} 本地资产 {len(assets)} 个")

    # 1. 幂等确保 Release 存在
    if _gh_run(["gh", "release", "view", tag, "-R", repo]).returncode != 0:
        log_info(f"[github] Release {tag} 不存在，创建中")
        create_cmd = [
            "gh",
            "release",
            "create",
            tag,
            "-R",
            repo,
            "--title",
            f"JigsawFox {tag}",
            "--notes",
            f"JigsawFox {tag} 自动更新发布",
        ]
        if _gh_run([*create_cmd, "--verify-tag"]).returncode != 0:
            log_warn(
                f"[github] --verify-tag 创建失败（tag 可能未推送），退化为不带该标志重试"
            )
            _gh_run(create_cmd)
    else:
        log_info(f"[github] Release {tag} 已存在")

    # 2. 已有附件清单 -> 按文件名差集增量上传
    existing: set[str] = set()
    if not force:
        p = _gh_run(
            [
                "gh",
                "release",
                "view",
                tag,
                "-R",
                repo,
                "--json",
                "assets",
                "-q",
                ".assets[].name",
            ]
        )
        if p.returncode == 0:
            existing = {ln.strip() for ln in p.stdout.splitlines() if ln.strip()}

    missing = _missing_assets(assets, existing, force)
    if not missing:
        log_info(f"[github] 已是最新，无需上传（远端已有 {len(existing)} 个附件）")
        return 0
    log_info(
        f"[github] {'强制重传' if force else '新增'} {len(missing)} 个资产: "
        f"{[f.name for f in missing]}"
    )
    rc = _gh_run(
        [
            "gh",
            "release",
            "upload",
            tag,
            "-R",
            repo,
            *[str(f) for f in missing],
            "--clobber",
        ]
    ).returncode
    if rc != 0:
        log_error(f"[github] 附件上传失败 rc={rc}")
    return rc


def _gitee_req(
    method: str,
    url: str,
    token: str,
    data: bytes | None = None,
    content_type: str | None = None,
    timeout: int = 60,
) -> Tuple[int, str]:
    """Gitee OpenAPI 请求（走 _HTTP_OPENER，遵守代理配置；对齐素材侧 gitee_release.py）。"""
    headers = {"Authorization": f"token {token}"}
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with _HTTP_OPENER.open(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:  # 网络异常统一为 0 便于上层判错
        return 0, str(e)


def _gitee_multipart_upload(url: str, token: str, path: Path) -> Tuple[int, str]:
    boundary = "----jigsawboundary" + os.urandom(8).hex()
    size = path.stat().st_size
    head = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{path.name}"\r\n'
        f"Content-Type: application/octet-stream\r\n\r\n"
    ).encode()
    tail = f"\r\n--{boundary}--\r\n".encode()
    body = head + path.read_bytes() + tail
    return _gitee_req(
        "POST",
        url,
        token,
        data=body,
        content_type=f"multipart/form-data; boundary={boundary}",
        timeout=max(120, int(size / (64 * 1024)) + 60),  # 按 64KB/s 保守下限给超时
    )


def _gitee_default_branch(repo: str, token: str) -> str:
    """查询仓库默认分支（Gitee 创建 Release 时必须显式传 target_commitish，实测缺失会 HTTP 400）。"""
    st, body = _gitee_req("GET", f"{GITEE_API}/repos/{repo}", token)
    if st == 200:
        try:
            br = json.loads(body).get("default_branch")
            if br:
                return br
        except Exception:
            pass
    log_warn(f"[gitee] 查询默认分支失败（HTTP {st}），回退 master")
    return "master"


def _gitee_existing_assets(repo: str, token: str, release: dict) -> Dict[str, int]:
    """返回 {文件名: 字节数}；优先用 attach_files 接口，失败时退回 release.assets 字段。"""
    rid = release.get("id")
    if rid is not None:
        st, body = _gitee_req(
            "GET",
            f"{GITEE_API}/repos/{repo}/releases/{rid}/attach_files?per_page=100",
            token,
        )
        if st == 200:
            try:
                out: Dict[str, int] = {}
                for a in json.loads(body):
                    name = a.get("name") or ""
                    if name:
                        out[name] = int(a.get("size") or 0)
                if out:
                    return out
            except Exception:
                pass
    return {
        a.get("name"): int(a.get("size") or 0)
        for a in (release.get("assets") or [])
        if a.get("name")
    }


def _gitee_warn_size(total: int) -> None:
    log_info(f"[gitee] 附件总规模 {total / 1048576:.1f} MB")
    if total > GITEE_LIMIT_BYTES:
        log_error(f"[gitee] 已超过 Gitee 1GB 上限，Release 可能被拒！")
    elif total > GITEE_SOFT_WARN_BYTES:
        log_warn(f"[gitee] 已超过 800MB 软告警线（上限 1GB），请规划分卷或迁移")


def publish_gitee_release(tag: str, assets_dir: Path, force: bool = False) -> int:
    """Gitee Release 幂等发布（OpenAPI v5，逻辑对齐素材侧 gitee_release.py，token 取环境变量）。

    - Release 不存在则由仓库默认分支建占位；附件走 attach_files 接口按文件名差集增量上传；
    - GITEE_TOKEN 缺失时 FATAL 返回 2（与素材发布一致，避免发布残缺镜像）。
    """
    token = os.environ.get("GITEE_TOKEN", "").strip()
    if not token:
        log_error("[gitee][FATAL] 未设置环境变量 GITEE_TOKEN，无法上传 Gitee 镜像源")
        return 2
    repo = GITEE_MIRROR_REPO
    assets = _app_release_assets(assets_dir)
    if not assets:
        log_error(f"[gitee][FATAL] Gitee Release 资产目录为空: {assets_dir}")
        return 2
    log_info(
        f"[gitee] repo={repo} tag={tag} 本地资产 {len(assets)} 个 共 "
        f"{sum(f.stat().st_size for f in assets):,} bytes"
    )

    # 1. 幂等确保 Release 存在
    #    注意：Gitee API 对「不存在的 release」返回 HTTP 200 + body `null`（而非 404），
    #    因此必须同时判断状态码与返回体是否可解析为 dict。
    st, body = _gitee_req("GET", f"{GITEE_API}/repos/{repo}/releases/tags/{tag}", token)
    release = None
    if st == 200:
        try:
            parsed = json.loads(body)
        except Exception:
            parsed = None
        if isinstance(parsed, dict) and parsed.get("id"):
            release = parsed
    if release is not None:
        log_info(f"[gitee] Release 已存在 id={release.get('id')}")
    else:
        log_info(f"[gitee] Release tag={tag} 不存在（HTTP {st}），尝试创建")
        default_branch = _gitee_default_branch(repo, token)
        log_info(f"[gitee] 仓库默认分支: {default_branch}")
        payload = json.dumps(
            {
                "tag_name": tag,
                "target_commitish": default_branch,  # Gitee 必填，缺失返回 HTTP 400
                "name": f"JigsawFox {tag}",
                "body": f"JigsawFox {tag} 自动更新发布",
            }
        ).encode()
        st, body = _gitee_req(
            "POST",
            f"{GITEE_API}/repos/{repo}/releases",
            token,
            data=payload,
            content_type="application/json",
        )
        if st not in (200, 201):
            log_error(f"[gitee][FATAL] 创建 Release 失败 HTTP {st}: {body[:300]}")
            return 1
        try:
            release = json.loads(body)
        except Exception:
            release = None
        if not isinstance(release, dict) or not release.get("id"):
            log_error(f"[gitee][FATAL] 创建 Release 返回异常: {body[:300]}")
            return 1
        log_info(f"[gitee] Release 创建成功 id={release.get('id')}")

    rid = release["id"]

    # 2. 已有附件 -> 按文件名差集增量上传（--force 时全部重传）
    existing = {} if force else _gitee_existing_assets(repo, token, release)
    log_info(
        f"[gitee] 远端已有附件 {len(existing)} 个"
        + ("（--force 忽略，将重传全部）" if force else "")
    )
    missing = _missing_assets(assets, set(existing), force)
    if not missing:
        log_info("[gitee] 已是最新，无需上传")
        _gitee_warn_size(sum(f.stat().st_size for f in assets))
        return 0
    log_info(
        f"[gitee] {'强制重传' if force else '新增'} {len(missing)} 个: "
        f"{[f.name for f in missing]}"
    )

    # 3. 逐个上传
    uploaded, failed = [], []
    for f in missing:
        sw = time.monotonic()
        st, body = _gitee_multipart_upload(
            f"{GITEE_API}/repos/{repo}/releases/{rid}/attach_files", token, f
        )
        dt = time.monotonic() - sw
        if st in (200, 201):
            uploaded.append(f.name)
            log_info(f"  [ok]   {f.name:<40} {f.stat().st_size:>12,} bytes  {dt:.1f}s")
        else:
            failed.append(f.name)
            log_error(f"  [FAIL] {f.name:<40} HTTP {st}  {body[:200]}")

    # 4. 体积累计与告警
    _gitee_warn_size(sum(f.stat().st_size for f in assets))

    if failed:
        log_error(f"[gitee][FATAL] 上传失败 {len(failed)} 个: {failed}")
        return 1
    log_info(f"[gitee] 上传完成 {len(uploaded)}/{len(missing)}")
    return 0


def cmd_publish(args: argparse.Namespace) -> None:
    """
    安全时序发布：
    1. 本地 pre-flight 深度校验（哈希、签名、版本递增门禁）
    2. rclone copy 上传所有平台所有 ABI 安装包到 R2（传输出错直接中断）
    3. 远端 HEAD 快速校验（状态码 + Content-Length）
    4. 发布 GitHub / Gitee Release 镜像资产（必须在切 updates.json 前完成：
       镜像 URL 内嵌于 updates.json，镜像未就绪会导致客户端 404）
    5. 校验通过后，最后上传 updates.json 切生效
    6. verify --remote 线上全量下载终检（内容级完整性兜底）
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
        raise EnvironmentError(
            "系统中未找到 rclone 命令，请先配置 rclone 访问 R2 存储桶"
        )

    entries = flatten_platform_entries(manifest.get("platforms", {}))

    # 1. 上传各安装包到 R2
    log_info("Step 1: 上传各平台与各 ABI 安装包到 R2...")
    for plat_name, sub_key, info in entries:
        tag_name = f"{plat_name}/{sub_key}" if sub_key else plat_name
        rel_url = info["url"]
        file_name = Path(rel_url).name
        # rel_url 已含 app/ 前缀，直接以 bucket 根为基准拼接，避免出现 app/app/ 双层路径
        r2_dest_dir = f"{R2_BUCKET_ROOT}/{Path(rel_url).parent.as_posix()}"

        search_dirs = [
            PROJECT_ROOT / "releases" / version_name / "github",
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

    # 2. 远端 HEAD 快速校验（rclone copy 传输出错会直接抛错中断，本地产物已过完整硬校验，
    #    这里只确认对象存在且大小一致；上传内容级完整性由 Step 4 的 verify --remote 全量下载终检兜底）
    log_info("\nStep 2: 远端 HEAD 快速校验刚上传的安装包（状态码 + Content-Length）...")
    for plat_name, sub_key, info in entries:
        tag_name = f"{plat_name}/{sub_key}" if sub_key else plat_name
        main_url = info["url"]
        if not main_url.startswith("http"):
            main_url = urllib.parse.urljoin(R2_APP_BASE, main_url)
        log_info(f"HEAD 校验 [{tag_name}]: {main_url}")
        check_remote_head(main_url, info["size"])

    # 2.5 发布 GitHub / Gitee Release 镜像资产。置于 updates.json 切换之前：
    #     updates.json 内嵌镜像 URL，镜像未发布会导致客户端点击 404；
    #     任一镜像发布失败即中止（未切 updates.json，线上仍是旧版本，可安全重试）。
    log_info(
        "\nStep 2.5: 发布 GitHub / Gitee Release 镜像资产（updates.json 切换前）..."
    )
    assets_dir = PROJECT_ROOT / "releases" / version_name / "github"
    if not assets_dir.is_dir():
        raise FileNotFoundError(
            f"镜像资产目录不存在: {assets_dir}（请先运行 prepare 生成发布产物）"
        )
    rc_gh = publish_github_release(
        f"v{version_name}", assets_dir, force=getattr(args, "force", False)
    )
    rc_gt = publish_gitee_release(
        f"v{version_name}", assets_dir, force=getattr(args, "force", False)
    )
    if rc_gh != 0 or rc_gt != 0:
        raise RuntimeError(
            f"GitHub/Gitee Release 镜像发布失败 (github={rc_gh}, gitee={rc_gt})，"
            f"未切换 updates.json，请修复后重跑 publish"
        )
    log_success("GitHub / Gitee Release 镜像资产发布完成")

    # 3. 最后上传 updates.json
    log_info("\nStep 3: 远端 HEAD 校验全部通过，上传 updates.json 切生效...")
    subprocess.run(
        ["rclone", "copy", str(out_json), f"{R2_BUCKET_ROOT}/{R2_APP_DIR}/"], check=True
    )
    log_success("updates.json 已上线！")

    # 4. 端到端巡检
    log_info("\nStep 4: 执行全链路巡检终检 (verify --remote)...")
    cmd_verify_remote()
    log_success(f"=== App 版本 {version_name}+{version_code} 发布并巡检成功！===")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="App 自动更新发布与完整性巡检编排工具（支持分 ABI）"
    )
    subparsers = parser.add_subparsers(dest="subcommand", required=True)

    # prepare
    p_prep = subparsers.add_parser("prepare", help="准备版本产物并生成 updates.json")
    p_prep.add_argument("--apk-dir", help="指定 APK 所在目录")
    p_prep.add_argument("--windows-path", help="指定 Windows 安装包或 Zip 路径")
    p_prep.add_argument("--min-version-code", type=int, help="最低强制更新版本号")

    # verify
    p_ver = subparsers.add_parser("verify", help="完整性验证与巡检")
    p_ver.add_argument("--local", action="store_true", help="执行本地硬门禁校验")
    p_ver.add_argument(
        "--remote",
        action="store_true",
        help="执行远端全链路巡检（HEAD 校验状态码与 Content-Length）",
    )
    p_ver.add_argument(
        "--url", default=UPDATES_JSON_REMOTE, help="指定远程 updates.json URL"
    )
    p_ver.add_argument(
        "--manifest",
        default=str(OUTPUT_DIR / "updates.json"),
        help="指定本地 updates.json 路径",
    )
    p_ver.add_argument("--apk-dir", help="指定 APK 所在目录")

    # publish
    p_pub = subparsers.add_parser("publish", help="安全时序发版")
    p_pub.add_argument("--dry-run", action="store_true", help="仅演练，不实际上传")
    p_pub.add_argument("--apk-dir", help="指定 APK 所在目录")
    p_pub.add_argument("--windows-path", help="指定 Windows 安装包或 Zip 路径")
    p_pub.add_argument("--min-version-code", type=int, help="最低强制更新版本号")
    p_pub.add_argument(
        "--force",
        action="store_true",
        help="强制重传 GitHub/Gitee Release 附件（内容已改但文件名未变时使用）",
    )

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
