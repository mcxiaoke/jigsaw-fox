#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gitee_release.py — Gitee Release 附件增量上传（OpenAPI v5）

背景
----
gitee CLI（v0.3.0）只有 release create/edit/list/view/delete，**没有附件上传能力**，
故 Gitee 侧的 zip 附件必须走 OpenAPI。本脚本取代旧的 gitee_publish.py（后者存在
`sys.environ` 拼写 bug，且无跳过逻辑、无体积告警）。

行为
----
1. 幂等确保 tag=assets 的 Release 存在（不存在则由 target_commitish=master 建占位）。
2. 读取已有附件清单，按 **文件名** 比对：已存在即跳过（Studio 导出 zip 名自带 -r{rev}，
   同名即同内容 => Release 资产只追加不覆盖，可安全跳过）。
3. 仅上传本次新增 zip；上传完成后统计附件总体积，超过 800MB（Gitee 上限 1GB）输出软告警。

凭证
----
环境变量 GITEE_TOKEN（repo 权限的私人令牌）。缺失时直接失败退出（不交互输入，便于流水线）。

用法
----
  python gitee_release.py                       # 用 channels.json 的 publishRoot / releaseTag
  python gitee_release.py --publish-root <dir>  # 指定发布产物目录
  python gitee_release.py --dry-run
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from assetmap import load_channels, load_doc  # noqa: E402

API = "https://gitee.com/api/v5"
GITEE_LIMIT_BYTES = 1024 * 1024 * 1024          # Gitee Release 附件上限 1GB
SOFT_WARN_BYTES = 800 * 1024 * 1024             # 800MB 软告警线


def _owner_repo(doc: dict) -> str:
    ch = next(c for c in load_channels() if c.id == "gitee")
    return ch.publish["remote"].split("gitee.com/")[-1].removesuffix(".git")


def _req(method: str, url: str, token: str, data: bytes | None = None,
         content_type: str | None = None, timeout: int = 60) -> tuple[int, str]:
    headers = {"Authorization": f"token {token}"}
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:  # 网络异常统一为 0 便于上层判错
        return 0, str(e)


def _multipart_upload(url: str, token: str, path: Path) -> tuple[int, str]:
    boundary = "----jigsawboundary" + os.urandom(8).hex()
    size = path.stat().st_size
    head = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{path.name}"\r\n'
        f"Content-Type: application/octet-stream\r\n\r\n"
    ).encode()
    tail = f"\r\n--{boundary}--\r\n".encode()
    body = head + path.read_bytes() + tail
    return _req(
        "POST", url, token, data=body,
        content_type=f"multipart/form-data; boundary={boundary}",
        timeout=max(120, int(size / (64 * 1024)) + 60),  # 按 64KB/s 保守下限给超时
    )


def _existing_assets(repo: str, token: str, release: dict) -> dict[str, int]:
    """返回 {文件名: 字节数}；优先用 attach_files 接口，失败时退回 release.assets 字段。"""
    rid = release.get("id")
    if rid is not None:
        st, body = _req("GET", f"{API}/repos/{repo}/releases/{rid}/attach_files?per_page=100", token)
        if st == 200:
            try:
                out: dict[str, int] = {}
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


def main() -> int:
    ap = argparse.ArgumentParser(prog="gitee_release.py")
    ap.add_argument("--publish-root", default=None, help="发布产物目录（默认取 channels.json dist.publishRoot）")
    ap.add_argument("--tag", default=None, help="Release 标签（默认取 channels.json releaseTag）")
    ap.add_argument("--target", default="master", help="Release 不存在时的目标分支")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true",
                    help="忽略远端已有附件，强制重传全部 zip（内容重导但文件名未变时使用）")
    args = ap.parse_args()

    doc = load_doc()
    publish_root = Path(args.publish_root or doc["dist"]["publishRoot"])
    tag = args.tag or doc["releaseTag"]
    repo = _owner_repo(doc)

    token = os.environ.get("GITEE_TOKEN", "").strip()
    if not token:
        print("[gitee][FATAL] 未设置环境变量 GITEE_TOKEN", file=sys.stderr)
        return 2
    if not publish_root.exists():
        print(f"[gitee][FATAL] 发布目录不存在: {publish_root}", file=sys.stderr)
        return 2

    zips = sorted(p for p in publish_root.rglob("*.zip"))
    if not zips:
        print(f"[gitee][FATAL] 未找到任何 zip: {publish_root}", file=sys.stderr)
        return 2
    print(f"[gitee] repo={repo} tag={tag} 本地 zip={len(zips)} 个 共 {sum(z.stat().st_size for z in zips):,} bytes")

    # 1. 幂等确保 Release 存在
    #    注意：Gitee API 对「不存在的 release」返回 HTTP 200 + body `null`（而非 404），
    #    因此必须同时判断状态码与返回体是否可解析为 dict。
    st, body = _req("GET", f"{API}/repos/{repo}/releases/tags/{tag}", token)
    release = None
    if st == 200:
        try:
            parsed = json.loads(body)
        except Exception:
            parsed = None
        if isinstance(parsed, dict) and parsed.get("id"):
            release = parsed
    if release is not None:
        print(f"[gitee] Release 已存在 id={release.get('id')}")
    else:
        print(f"[gitee] Release tag={tag} 不存在（HTTP {st}），尝试创建")
        if args.dry_run:
            print("[gitee] DRY-RUN：跳过创建与上传")
            return 0
        payload = json.dumps(
            {"tag_name": tag, "name": f"assets {tag}",
             "body": "jigsaw-data zip packs", "target_commitish": args.target}
        ).encode()
        st, body = _req("POST", f"{API}/repos/{repo}/releases", token,
                        data=payload, content_type="application/json")
        if st not in (200, 201):
            print(f"[gitee][FATAL] 创建 Release 失败 HTTP {st}: {body[:300]}", file=sys.stderr)
            return 1
        try:
            release = json.loads(body)
        except Exception:
            release = None
        if not isinstance(release, dict) or not release.get("id"):
            print(f"[gitee][FATAL] 创建 Release 返回异常: {body[:300]}", file=sys.stderr)
            return 1
        print(f"[gitee] Release 创建成功 id={release.get('id')}")

    rid = release["id"]

    # 2. 已有附件 -> 仅上传缺失（Studio 导出 zip 名自带 -r{rev}，同名即同内容）
    #    --force 时跳过清单判断，全部重传（应对「内容改了但文件名没变」）
    existing = {} if args.force else _existing_assets(repo, token, release)
    print(f"[gitee] 远端已有附件 {len(existing)} 个"
          + ("（--force 忽略，将重传全部）" if args.force else ""))
    missing = [z for z in zips if z.name not in existing]
    if not missing:
        print("[gitee] 已是最新，无需上传")
        total = sum(z.stat().st_size for z in zips)
        _warn_size(total)
        return 0
    print(f"[gitee] {'强制重传' if args.force else '新增'} {len(missing)} 个: "
          f"{[z.name for z in missing]}")
    if args.dry_run:
        print("[gitee] DRY-RUN：跳过上传")
        return 0

    # 3. 逐个上传
    uploaded, failed = [], []
    for z in missing:
        sw = time.time()
        st, body = _multipart_upload(f"{API}/repos/{repo}/releases/{rid}/attach_files", token, z)
        dt = time.time() - sw
        if st in (200, 201):
            uploaded.append(z.name)
            print(f"  [ok]   {z.name:<40} {z.stat().st_size:>12,} bytes  {dt:.1f}s")
        else:
            failed.append(z.name)
            print(f"  [FAIL] {z.name:<40} HTTP {st}  {body[:200]}", file=sys.stderr)

    # 4. 体积累计与告警
    total = sum(z.stat().st_size for z in zips)
    _warn_size(total)

    if failed:
        print(f"[gitee][FATAL] 上传失败 {len(failed)} 个: {failed}", file=sys.stderr)
        return 1
    print(f"[gitee] 上传完成 {len(uploaded)}/{len(missing)}")
    return 0


def _warn_size(total: int) -> None:
    print(f"[gitee] 附件总规模 {total / 1048576:.1f} MB")
    if total > GITEE_LIMIT_BYTES:
        print(f"[gitee][WARN] 已超过 Gitee 1GB 上限，release 可能被拒！", file=sys.stderr)
    elif total > SOFT_WARN_BYTES:
        print(f"[gitee][WARN] 已超过 800MB 软告警线（上限 1GB），请规划分卷或迁移", file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main())
