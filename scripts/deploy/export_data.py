#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
export_data.py — 按 studio v2.3.0 规范从采样素材导出 jigsaw-data 发布内容

调用 studio.exporters.registry 的官方导出器（Main/Daily/Event/Collection），
全部输出到同一 out 目录以累积根 manifest.json。导出完成后执行 Release 后处理：
  - daily/events/collections 的 index.json 中 zipUrl 改写为 GitHub Release 绝对 URL
    （zip 本体不进入 git 仓库，作为 gh release 资产上传）；
  - 重新计算各 index.json 哈希并回写 manifest.json modules.<m>.hash，保持规范一致。

产物：
  <build>/out/manifest.json + main/ + daily/ + events/ + collections/
  <build>/publish_plan.json   待上传 Release 的 zip 资产清单

用法：python scripts/deploy/export_data.py
（必须在项目根目录运行，studio 依赖 data/taxonomy.json 相对加载）
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT))

BUILD = Path(r"C:\Home\Temp\jigsawdata_build")
OUT = BUILD / "out"

REPO = "mcxiaoke/jigsaw-data"
TAG = "v0.1.0"
RELEASE_PREFIX = f"https://github.com/{REPO}/releases/download/{TAG}"

from studio.core.scanner import compute_file_sha256, scan_images  # noqa: E402
from studio.exporters.registry import get_exporter  # noqa: E402


def log(level: str, msg: str) -> None:
    print(f"[{level}] {msg}", flush=True)


def run_exporter(exp_type: str, data: dict, src: Path) -> None:
    src_p = Path(src)
    result = get_exporter(exp_type, data, src_p, OUT,
                          RELEASE_PREFIX, log).execute()
    if not result.success:
        raise RuntimeError(f"导出失败 {exp_type} {data.get('id', '')}: {result.error}")
    log("ok", f"{exp_type} 导出成功: {result.summary}")


def rewrite_zip_urls() -> None:
    """把 zip 类模块 index.json 内的 zipUrl 改写为 Release 绝对 URL，并同步 manifest hash"""
    manifest_p = OUT / "manifest.json"
    manifest = json.loads(manifest_p.read_text(encoding="utf-8"))

    def fix_index(module: str, key: str) -> None:
        idx_p = OUT / module / "index.json"
        if not idx_p.exists():
            return
        idx = json.loads(idx_p.read_text(encoding="utf-8"))
        for item in idx.get("items", []):
            zu = item.get("zipUrl", "")
            if zu.startswith("zips/") or zu.startswith("packs/"):
                fname = Path(zu).name
                item["zipUrl"] = f"{RELEASE_PREFIX}/{fname}"
                log("ok", f"{module} {item.get('month') or item.get('id')} zipUrl -> {item['zipUrl']}")
        idx_p.write_text(json.dumps(idx, ensure_ascii=False, indent=2) + "\n",
                         encoding="utf-8")
        h = compute_file_sha256(idx_p)
        if manifest.get("modules", {}).get(module):
            manifest["modules"][module]["hash"] = h
            log("ok", f"{module}/index.json hash 已回写 manifest: {h[:12]}...")

    for module, key in (("daily", "month"), ("events", "id"), ("collections", "id")):
        fix_index(module, key)

    manifest_p.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                          encoding="utf-8")
    log("ok", "manifest.json 已同步 zipUrl 改写后的模块哈希")


def collect_zip_assets() -> list[str]:
    """收集待上传 Release 的 zip 资产（相对 out 路径）"""
    zips: list[str] = []
    for sub in ("daily/zips", "events/packs", "collections/packs"):
        d = OUT / sub
        if d.exists():
            for p in sorted(d.glob("*.zip")):
                zips.append(p.relative_to(OUT).as_posix())
    return zips


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    plan = json.loads((BUILD / "assets_plan.json").read_text(encoding="utf-8"))
    mod = plan["modules"]

    # 1. main
    run_exporter("main", {"format": "webp", "rename": "sequence"}, BUILD / "src_main")

    # 2. daily × 3（共享 src_daily_all 素材根以累积同一 .studio 工作区 index）
    for month, info in mod["daily"].items():
        month_dir = BUILD / info["src_dir"]
        rels = [p.relative_to(BUILD / "src_daily_all").as_posix()
                for p in sorted(scan_images(month_dir))]
        run_exporter("daily",
                     {"month": month, "format": "webp", "rename": "none",
                      "selectedPaths": rels},
                     BUILD / "src_daily_all")

    # 3. events × 3
    for it in mod["events"]:
        src_dir = BUILD / it["src_dir"]
        rels = [p.relative_to(BUILD / "src_events").as_posix()
                for p in scan_images(src_dir)]
        data = {k: it[k] for k in ("id", "title", "desc", "status") if k in it}
        for k in ("titleZh", "descZh", "startTime", "endTime"):
            if it.get(k):
                data[k] = it[k]
        data.update({"format": "webp", "rename": "none",
                     "selectedPaths": rels, "displayOrder": 1})
        run_exporter("event", data, BUILD / "src_events")

    # 4. collections × 5
    for it in mod["collections"]:
        src_dir = BUILD / it["src_dir"]
        rels = [p.relative_to(BUILD / "src_collections").as_posix()
                for p in scan_images(src_dir)]
        data = {k: it[k] for k in ("id", "title", "desc", "status") if k in it}
        for k in ("titleZh", "descZh", "category"):
            if it.get(k):
                data[k] = it[k]
        data.update({"format": "webp", "rename": "none",
                     "selectedPaths": rels, "displayOrder": 1})
        run_exporter("collection", data, BUILD / "src_collections")

    # 5. Release 后处理
    rewrite_zip_urls()
    assets = collect_zip_assets()
    publish = {"repo": REPO, "tag": TAG, "release_prefix": RELEASE_PREFIX,
               "assets": assets}
    (BUILD / "publish_plan.json").write_text(
        json.dumps(publish, ensure_ascii=False, indent=2), encoding="utf-8")
    log("ok", f"publish_plan.json 已写入，共 {len(assets)} 个 zip 资产待上传")
    return 0


if __name__ == "__main__":
    sys.exit(main())
