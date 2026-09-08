#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
normalize.py — 把 studio 已导出的 out/ 产物归一化为多平台友好形态。

out/ 现状：export_data.py 会把 zipUrl 改写成单一平台绝对地址，且只有 zipUrl/zipUrls。
本步在“不动 studio 代码、不动原 out/ 语义”的前提下，叠加：
  - 为每个 zip 条目注入 `zipKey`：相对 dist 根的 canonical key（如 daily/zips/202609.zip）。
    app 端若读到 zipKey 就用通道表合成多平台镜像；读不到才退回旧 zipUrl，旧端零破坏。
  - 保留原 zipUrl（gitee release 绝对地址）作为旧端兼容兜底。
  - 重算 manifest.json 各模块的 hash，保持 schemaVersion=4 规范一致。

只写 stage/ 目录，不回写 out/（out/ 视为 studio 产物，仅读取）。
"""
from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from assetmap import load_doc, scan_dist_keys  # noqa: E402

try:
    from studio.core.scanner import compute_file_sha256  # type: ignore
except Exception:  # 兜底：独立实现 sha256
    import hashlib

    def compute_file_sha256(p: Path) -> str:
        h = hashlib.sha256()
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()


def _copy_dist(dist: Path, stage: Path, exclude: list[str]) -> None:
    if stage.resolve() == dist.resolve():
        # root 与 stage 同目录：就地归一化，无需拷贝
        keys = scan_dist_keys(dist, exclude)
    else:
        if stage.exists():
            shutil.rmtree(stage)
        stage.mkdir(parents=True)
        keys = scan_dist_keys(dist, exclude)
        for k in keys:
            src = dist / k
            dst = stage / k
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
    # 复制 .gitattributes 到每个模块目录（ModelScope 按目录生效 LFS 规则，必须下沉）
    if (Path(dist if stage.resolve() != dist.resolve() else dist) / ".gitattributes").exists():
        for mod in ("main", "daily", "events", "collections"):
            d = stage / mod
            if d.is_dir():
                shutil.copy2(dist / ".gitattributes", d / ".gitattributes")


def _zip_candidates(dist: Path) -> dict[str, str]:
    """basename -> canonical key，用于把绝对 zipUrl 反推回 zipKey。"""
    cands: dict[str, str] = {}
    for k in scan_dist_keys(dist):
        if k.endswith(".zip"):
            cands[Path(k).name] = k
    return cands


def _fix_index(idx_path: Path, cands: dict[str, str]) -> int:
    idx = json.loads(idx_path.read_text(encoding="utf-8"))
    n = 0
    for item in idx.get("items", []):
        zu = item.get("zipUrl", "")
        if not zu:
            continue
        fname = Path(zu).name
        key = cands.get(fname)
        if key and "zipKey" not in item:
            item["zipKey"] = key
            # 旧端兼容：保留原 zipUrl；清掉单平台 zipUrls（避免误导旧端），
            # 新端完全由 app 用通道表合成。
            item.pop("zipUrls", None)
            n += 1
    idx_path.write_text(json.dumps(idx, ensure_ascii=False, indent=2) + "\n",
                         encoding="utf-8")
    return n


def main() -> int:
    doc = load_doc()
    dist = Path(doc["dist"]["root"])
    stage = Path(doc["dist"]["stage"])
    excl = doc["dist"].get("excludeNames", [])

    print(f"[normalize] copy dist {dist} -> stage {stage}")
    _copy_dist(dist, stage, excl)

    cands = _zip_candidates(dist)
    total = 0
    for module in ("daily", "events", "collections"):
        idx = stage / module / "index.json"
        if idx.exists():
            n = _fix_index(idx, cands)
            total += n
            print(f"[normalize] {module}/index.json injected zipKey x{n}")

    # 重算 manifest 模块 hash（与 export_data.rewrite_zip_urls 同逻辑）
    manifest_p = stage / "manifest.json"
    manifest = json.loads(manifest_p.read_text(encoding="utf-8"))
    for module, rel in (("daily", "daily/index.json"), ("events", "events/index.json"),
                        ("collections", "collections/index.json")):
        ip = stage / rel
        if ip.exists() and manifest.get("modules", {}).get(module):
            manifest["modules"][module]["hash"] = compute_file_sha256(ip)
    manifest_p.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                          encoding="utf-8")
    print(f"[normalize] manifest hash 已同步；zipKey 总计 {total}")
    print("[normalize] done ->", stage)
    return 0


if __name__ == "__main__":
    sys.exit(main())
