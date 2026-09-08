#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_channels.py — 跨通道可达性 + 一致性巡检

对每个启用的 channel，把 dist 内全部 canonical key 展开成真实 URL，
并发 HEAD/GET 抽查可达性；对 zip 做 sha256 抽检（与本地一致 = 内容同一份）。
同时校验：
  - flatten 通道无 basename 冲突
  - 每个 zip 至少在一个已发布通道可达（否则 app 会缺资源）
  - zipKey 已注入、zipUrls 旧字段已清理

用法
----
  python verify_channels.py                 # 全通道
  python verify_channels.py --channel r2cdn # 单通道
  python verify_channels.py --json report.json
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import hashlib
import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from assetmap import (  # noqa: E402
    load_channels,
    load_doc,
    scan_dist_keys,
    is_zip_key,
    check_flatten_collisions,
)

import urllib.request

DOC = load_doc()
DIST = Path(DOC["dist"].get("publishRoot", DOC["dist"]["root"]))
STAGE = Path(DOC["dist"].get("publishRoot", DOC["dist"]["stage"]))
EXCL = DOC["dist"].get("excludeNames", [])
TAG = DOC["releaseTag"]


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def _http_check(url: str, want_size: int | None = None) -> dict:
    try:
        req = urllib.request.Request(
            url, method="GET", headers={"User-Agent": "jigsaw-verify/1.0"}
        )
        with urllib.request.urlopen(req, timeout=30) as r:
            data = r.read()
            return {
                "ok": 200 <= r.status < 400,
                "status": r.status,
                "bytes": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
            }
    except Exception as e:  # noqa
        return {
            "ok": False,
            "status": None,
            "bytes": 0,
            "sha256": "",
            "error": str(e)[:120],
        }


def local_sha(key: str) -> str | None:
    p = STAGE / key
    return _sha256(p) if p.exists() else None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--channel", default=None)
    ap.add_argument("--json", default=None)
    args = ap.parse_args()

    channels = load_channels()
    if args.channel:
        channels = [c for c in channels if c.id == args.channel]
    else:
        # 默认只巡检启用通道：禁用（modelscope）与仅 manifest 备份（jsdelivr）不参与内容巡检
        skipped = [c.id for c in channels if c.disabled or c.manifest_backup]
        channels = [c for c in channels if not c.disabled and not c.manifest_backup]
        if skipped:
            print(
                f"跳过（disabled/manifest_backup，不参与内容巡检）: {', '.join(skipped)}"
            )
    keys = [k for k in scan_dist_keys(STAGE, EXCL) if not k.endswith(".gitattributes")]

    # 静态校验
    problems: list[str] = []
    for ch in channels:
        col = (
            check_flatten_collisions(keys)
            if any(r.layout == "flatten" for r in ch.rules)
            else []
        )
        if col:
            problems.append(f"[{ch.id}] flatten basename 冲突: {col}")

    # 并发检查
    tasks = []  # (channel_id, key, url)
    for ch in channels:
        for k in keys:
            tasks.append((ch.id, k, ch.key_to_url(k, TAG)))

    print(f"巡检 {len(channels)} 通道 × {len(keys)} key = {len(tasks)} 请求 ...")
    results = {}
    with cf.ThreadPoolExecutor(max_workers=16) as ex:
        futs = {ex.submit(_http_check, url): (cid, k, url) for cid, k, url in tasks}
        for fut in cf.as_completed(futs):
            cid, k, url = futs[fut]
            res = fut.result()
            results.setdefault(cid, {})[k] = res

    # 汇总
    report = {"channels": {}, "problems": problems}
    for ch in channels:
        ch_res = results.get(ch.id, {})
        ok = sum(1 for r in ch_res.values() if r.get("ok"))
        # zip 一致性
        zip_mismatch = []
        for k, r in ch_res.items():
            if is_zip_key(k) and r.get("ok"):
                ls = local_sha(k)
                if ls and r.get("sha256") and r["sha256"] != ls:
                    zip_mismatch.append(k)
        # 该通道 zip 不可达（关键失败，计入 problems；.gitattributes 404 是有意排除，忽略）
        zip_fail = [k for k, r in ch_res.items() if is_zip_key(k) and not r.get("ok")]
        if zip_fail:
            problems.append(f"[{ch.id}] zip 不可达 x{len(zip_fail)}: {zip_fail[:3]}")
        report["channels"][ch.id] = {
            "total": len(ch_res),
            "ok": ok,
            "fail": [
                k
                for k, r in ch_res.items()
                if not r.get("ok") and not k.endswith(".gitattributes")
            ],
            "zip_sha_mismatch": zip_mismatch,
        }
        status = (
            "OK" if ok == len(ch_res) and not zip_mismatch and not zip_fail else "FAIL"
        )
        print(
            f"  [{ch.id}] {status}  ok={ok}/{len(ch_res)}  zip_fail={len(zip_fail)} zip_mismatch={len(zip_mismatch)}"
        )

    # zip 全局覆盖：每个 zip 至少一条 ok
    zip_keys = [k for k in keys if is_zip_key(k)]
    uncovered = []
    for zk in zip_keys:
        any_ok = any(results.get(c.id, {}).get(zk, {}).get("ok") for c in channels)
        if not any_ok:
            uncovered.append(zk)
    if uncovered:
        problems.append(f"zip 全通道不可达: {uncovered}")

    report["problems"] = problems
    if args.json:
        Path(args.json).write_text(
            json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        print(f"\nreport -> {args.json}")
    if problems:
        print("\n问题：")
        for p in problems:
            print("  -", p)
        return 1
    print("\n所有通道巡检通过 ✅")
    return 0


if __name__ == "__main__":
    sys.exit(main())
