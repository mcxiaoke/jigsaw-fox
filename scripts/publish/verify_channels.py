#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_channels.py — 素材发布可达性与一致性巡检（v2）

方案依据
--------
docs/assets-publish-workflow-v2-20260910.md §4 Step 2 / Step 4

环境语义
--------
  --env stage  只巡检 R2 预演区（https://<host>/_stage/）：JSON 200 + 内容 sha256 一致、
               全部 WebP 200、全部 zip 主地址（相对 zipUrl 解析结果）200。
  --env prod   巡检 R2 生产区（https://<host>/release/）全量：
               JSON 200 + 内容 sha256 一致、全部 WebP 200、全部 zip 主地址 200。
               Gitee/GitHub 的 zip Release 镜像必然可达（Step 3 先于 Step 4 就位）。
               加 --include-mirrors 时额外全量巡检 Gitee/GitHub 的 raw JSON/WebP
               （需 Step 5 git push 之后才成立）。

本地契约校验（与网络无关，始终执行）
------------------------------------
  1. index.json 的 zipUrl 必须为相对路径；zipUrls 必须为绝对地址且与
     channels.json 的 zipMirrorChannels 顺序逐项一致。
  2. manifest.modules.<m>.hash 必须等于本地 <m>/index.json 的 sha256。
  3. 所有被引用的 zip 本地存在，basename 全局无冲突。

用法
----
  python verify_channels.py --env stage
  python verify_channels.py --env prod
  python verify_channels.py --env prod --include-mirrors
  python verify_channels.py --env stage --keys-only     # 跳过 HTTP，仅本地契约
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import hashlib
import json
import posixpath
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from assetmap import load_channels, load_doc  # noqa: E402

ZIP_MODULES = ("daily", "events", "collections")
JSON_SUFFIX = ".json"
UA_HEADERS = {"User-Agent": "jigsaw-publish-verify/2.0"}


def _sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _http(url: str, method: str = "GET", timeout: int = 30) -> tuple[int, bytes]:
    req = urllib.request.Request(url, headers=UA_HEADERS, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = r.read() if method == "GET" else b""
            return r.status, data
    except urllib.error.HTTPError as e:
        return e.code, b""
    except Exception:
        return 0, b""


def _reachable(url: str) -> tuple[bool, int]:
    st, _ = _http(url, "HEAD")
    if st in (200, 204, 206):
        return True, st
    if st in (0, 403, 405):  # HEAD 不被支持时退化为 GET
        st2, _ = _http(url, "GET")
        return st2 in (200, 206), st2
    return False, st


# ------------------------------------------------------------ 本地契约校验
def local_contract_checks(publish_root: Path, doc: dict) -> list[str]:
    errs: list[str] = []
    manifest = json.loads((publish_root / "manifest.json").read_text("utf-8"))

    # 1. 模块 hash 与本地 index.json 一致
    for module, mod in (manifest.get("modules") or {}).items():
        idx = publish_root / module / "index.json"
        if not idx.exists():
            errs.append(f"缺少模块 index: {module}/index.json")
            continue
        actual = _sha256(idx)
        declared = mod.get("hash") or ""
        if declared != actual:
            errs.append(f"模块 {module} hash 不一致: manifest={declared[:16]}… local={actual[:16]}…")

    # 2. zipUrl 相对 / zipUrls 绝对且与通道展开结果逐项一致
    mirror_ids = [c.id for c in load_channels() if c.id in (doc.get("zipMirrorChannels") or [])]
    tag = doc["releaseTag"]
    by_id = {c.id: c for c in load_channels()}

    referenced: list[str] = []
    for module in ZIP_MODULES:
        data = json.loads((publish_root / module / "index.json").read_text("utf-8"))
        for it in data.get("items") or []:
            label = it.get("id") or it.get("month") or "?"
            zu = it.get("zipUrl")
            if not zu:
                errs.append(f"{module}/{label} 缺少 zipUrl")
                continue
            if zu.startswith(("http://", "https://")):
                errs.append(f"{module}/{label} zipUrl 应为相对路径: {zu}")
                continue
            key = posixpath.normpath(f"{module}/{zu}")
            referenced.append(key)
            urls = it.get("zipUrls")
            if not isinstance(urls, list) or len(urls) != len(mirror_ids):
                errs.append(f"{module}/{label} zipUrls 数量应为 {len(mirror_ids)}，实际 {urls}")
                continue
            for i, u in enumerate(urls):
                expected = by_id[mirror_ids[i]].key_to_url(key, tag)
                if not isinstance(u, str) or not u.startswith(("http://", "https://")):
                    errs.append(f"{module}/{label} zipUrls[{i}] 非绝对地址: {u}")
                elif u != expected:
                    errs.append(
                        f"{module}/{label} zipUrls[{i}] 与通道 {mirror_ids[i]} 展开不符: "
                        f"{u} != {expected}"
                    )

    # 3. zip 本地存在 + basename 无冲突
    missing = [k for k in referenced if not (publish_root / k).exists()]
    if missing:
        errs.append(f"以下 zip 本地不存在: {missing}")
    names = sorted(p.name for p in publish_root.rglob("*.zip"))
    dupes = sorted({n for n in names if names.count(n) > 1})
    if dupes:
        errs.append(f"zip basename 重名: {dupes}")

    return errs


# ------------------------------------------------------------ 网络巡检
def _collect_keys(publish_root: Path) -> tuple[list[str], list[str], list[str]]:
    jsons, images, zips = [], [], []
    for f in publish_root.rglob("*"):
        if not f.is_file():
            continue
        rel = f.relative_to(publish_root).as_posix()
        if rel.endswith(JSON_SUFFIX):
            jsons.append(rel)
        elif rel.endswith(".webp"):
            images.append(rel)
        elif rel.endswith(".zip"):
            zips.append(rel)
    return sorted(jsons), sorted(images), sorted(zips)


def _check_env(publish_root: Path, doc: dict, env: str, include_mirrors: bool) -> list[str]:
    errs: list[str] = []
    d = doc["dist"]
    tag = doc["releaseTag"]
    channels = {c.id: c for c in load_channels()}

    jsons, images, zips = _collect_keys(publish_root)
    print(f"[verify:{env}] 本地 key: json={len(jsons)} 图片={len(images)} zip={len(zips)}")

    # ---- 目标通道集合
    targets: list[tuple[str, list[str], list[str], list[str]]] = []  # (label, json_keys, image_keys, zip_keys)

    if env == "stage":
        base = f"{d['r2Host'].rstrip('/')}/{d['stagePrefix']}/"
        targets.append(("r2:_stage", jsons, images, zips))
        base_override = {"r2cdn": base}
    else:
        targets.append(("r2:release", jsons, images, zips))
        base_override = {}
        for cid in doc.get("zipMirrorChannels") or []:
            ch = channels[cid]
            if include_mirrors:
                # 全量终检：raw 的 JSON/WebP + Release 的 zip 都校验
                targets.append((f"{cid}(raw+release)", jsons, images, zips))
            elif ch.cn_rank > 0:
                # 默认：只校验国内可用通道（cn>0）的 zip Release 附件
                targets.append((f"{cid}(release only)", [], [], zips))
            else:
                print(f"[verify:prod] 跳过 {cid}（cn=0，本机网络不保证可达；"
                      f"如需全量请加 --include-mirrors）")

    # ---- 并发校验
    tasks: list[tuple[str, str, Path | None]] = []  # (label, url, local_file_or_None)
    for label, jk, ik, zk in targets:
        ch_id = "r2cdn" if label.startswith("r2:") else label.split("(")[0]
        ch = channels[ch_id]
        urls = {k: ch.key_to_url(k, tag) for k in set(jk + ik + zk)}
        if ch_id == "r2cdn" and base_override.get("r2cdn"):
            urls = {k: base_override["r2cdn"] + k for k in set(jk + ik + zk)}
        for k in jk:
            tasks.append((f"{label} json {k}", urls[k], publish_root / k))
        for k in ik:
            tasks.append((f"{label} img  {k}", urls[k], None))
        for k in zk:
            tasks.append((f"{label} zip  {k}", urls[k], None))

    print(f"[verify:{env}] 待校验 URL {len(tasks)} 条")

    def _one(task):
        label, url, local = task
        if local is not None:
            st, data = _http(url, "GET")
            if st != 200:
                return f"{label} HTTP {st} -> {url}"
            if _sha256_bytes(data) != _sha256(local):
                return f"{label} 内容 sha256 与本地不一致 -> {url}"
            return None
        ok, st = _reachable(url)
        return None if ok else f"{label} 不可达 HTTP {st} -> {url}"

    with cf.ThreadPoolExecutor(max_workers=16) as ex:
        for r in ex.map(_one, tasks):
            if r:
                errs.append(r)

    return errs


def _sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


# ------------------------------------------------------------ main
def main() -> int:
    ap = argparse.ArgumentParser(prog="verify_channels.py")
    ap.add_argument("--env", choices=("stage", "prod"), default="prod")
    ap.add_argument("--include-mirrors", action="store_true",
                    help="prod 下额外全量巡检 Gitee/GitHub raw 的 JSON/WebP（需 git push 后）")
    ap.add_argument("--keys-only", action="store_true", help="仅本地契约校验，跳过 HTTP")
    args = ap.parse_args()

    doc = load_doc()
    publish_root = Path(doc["dist"]["publishRoot"])
    if not publish_root.exists():
        print(f"[verify][FATAL] publishRoot 不存在: {publish_root}", file=sys.stderr)
        return 2

    errs = local_contract_checks(publish_root, doc)
    print(f"[verify] 本地契约校验: {'通过' if not errs else f'{len(errs)} 项失败'}")
    for e in errs:
        print(f"  [ERR] {e}", file=sys.stderr)

    if not args.keys_only:
        net_errs = _check_env(publish_root, doc, args.env, args.include_mirrors)
        errs.extend(net_errs)
        print(f"[verify:{args.env}] 网络巡检: {'通过' if not net_errs else f'{len(net_errs)} 项失败'}")
        for e in net_errs:
            print(f"  [ERR] {e}", file=sys.stderr)

    if errs:
        print(f"\n[verify][FAIL] 共 {len(errs)} 项错误", file=sys.stderr)
        return 1
    print(f"\n[verify][OK] env={args.env} 全部校验通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
