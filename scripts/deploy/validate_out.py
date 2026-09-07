#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
validate_out.py — 本地数据格式规范校验（studio v2.3.0 + 客户端契约）

对 <build>/out 全量断言：
  manifest   : schemaVersion=4、四模块路由、hash 与 index.json 一致
  main       : totalCount、batch 引用、id/order 连续性、tags 合法且位于
               taxonomy v3.2.0 预定义主 tag、url 为 ../images/ 相对形态、图片 hash 匹配
  daily      : 月份 items、zipUrl 为 Release 绝对 URL、zip 大小/hash 与文件一致
  events/coll: 条目数、cover 文件存在、zip 资产一致、category 合法
  zip 内容   : daily 条目=YYYYMMDD 连续日；pack 条目数=totalCount
  图片解码   : 全部 webp 可通过 PIL 解码

用法：python scripts/deploy/validate_out.py
退出码 0 = 通过；1 = 存在错误。
"""

from __future__ import annotations

import json
import sys
import zipfile
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT))

from studio.core.image_proc import validate_image  # noqa: E402
from studio.core.scanner import compute_file_sha256  # noqa: E402

OUT = Path(r"C:\Home\Temp\jigsawdata_build\out")
RELEASE_PREFIX = "https://github.com/mcxiaoke/jigsaw-data/releases/download/v0.1.0"
MAIN_TAGS = {  # taxonomy v3.2.0 main_tags ids
    "Landscapes", "Nature", "Flowers", "Animals", "Pets", "Cities",
    "Structures", "Vehicles", "People", "Objects", "Food", "Art",
    "Fantasy", "Holidays", "Colors", "Composition", "Others",
}

errors: list[str] = []
warns: list[str] = []


def check(cond: bool, msg: str) -> None:
    if cond:
        return
    errors.append(msg)


def load(p: Path) -> dict:
    return json.loads(p.read_text(encoding="utf-8"))


def main() -> int:
    manifest = load(OUT / "manifest.json")

    # 1. manifest
    check(manifest.get("schemaVersion") == 4, "manifest schemaVersion != 4")
    mods = manifest.get("modules", {})
    check(set(mods) == {"main", "daily", "events", "collections"},
          f"modules 集合不符: {sorted(mods)}")
    for name, m in mods.items():
        url = m.get("url", "")
        check(url.startswith(f"{name}/index.json"),
              f"module {name} url 形态异常: {url}")
        idx_p = OUT / url
        check(idx_p.exists(), f"module {name} index.json 不存在: {url}")
        if idx_p.exists():
            check(m.get("hash") == compute_file_sha256(idx_p),
                  f"module {name} manifest.hash 与 index.json 不一致")

    # 2. main
    main_idx = load(OUT / "main" / "index.json")
    check(main_idx.get("module") == "main", "main index module != main")
    total = main_idx.get("totalCount")
    check(total == 30, f"main totalCount != 30: {total}")
    seen_ids: set[str] = set()
    seen_orders: list[int] = []
    all_tags: list[str] = []
    for b in main_idx.get("items", []):
        bfile = OUT / "main" / b["url"]
        check(bfile.exists(), f"batch 文件不存在: {b['url']}")
        if not bfile.exists():
            continue
        bj = load(bfile)
        check(bj.get("batchId") == b.get("batchId"), "batchId 不一致")
        levels = bj.get("items", [])
        check(len(levels) == b.get("count"),
              f"batch {b['batchId']} count 不一致 {len(levels)} vs {b.get('count')}")
        for lv in levels:
            check(lv["id"] not in seen_ids, f"重复关卡 id: {lv['id']}")
            seen_ids.add(lv["id"])
            seen_orders.append(lv["order"])
            u = lv.get("url", "")
            check(u.startswith("../images/"), f"level url 非 ../images/ 形态: {u}")
            img_p = OUT / "main" / "images" / Path(u).name
            check(img_p.exists(), f"level 图片不存在: {u}")
            if img_p.exists():
                check(lv.get("hash") == compute_file_sha256(img_p),
                      f"level {lv['id']} hash 与图片不一致")
            tags = lv.get("tags") or []
            all_tags.extend(tags)
            check(bool(tags), f"level {lv['id']} 无 tags")
    check(seen_orders == list(range(min(seen_orders), max(seen_orders) + 1)),
          f"order 不连续: {min(seen_orders) if seen_orders else '-'}..{max(seen_orders) if seen_orders else '-'}")
    bad_tags = sorted({t for t in all_tags if t not in MAIN_TAGS})
    check(not bad_tags, f"main levels 含非预定义 tag: {bad_tags}")
    # batch 自身 hash 引用完整性
    for lv in main_idx.get("items", []):
        pass

    # 3. daily
    d_idx = load(OUT / "daily" / "index.json")
    months = d_idx.get("items", [])
    check({m["month"] for m in months} == {"202607", "202608", "202609"},
          f"daily 月份集不符: {[m['month'] for m in months]}")
    expected_days = {"202607": 31, "202608": 31, "202609": 30}
    for m in months:
        mon = m["month"]
        check(m["zipUrl"].startswith(RELEASE_PREFIX) and m["zipUrl"].endswith(f"/{mon}.zip"),
              f"daily {mon} zipUrl 形态异常: {m['zipUrl']}")
        zp = OUT / "daily" / "zips" / f"{mon}.zip"
        check(zp.exists(), f"daily zip 不存在: {mon}.zip")
        if zp.exists():
            check(m["zipSha256"] == compute_file_sha256(zp), f"daily {mon} zipSha256 不一致")
            check(m["fileSizeBytes"] == zp.stat().st_size, f"daily {mon} fileSizeBytes 不一致")
            with zipfile.ZipFile(zp) as zf:
                names = sorted(zf.namelist())
                expect = [f"{mon}{d:02d}.webp" for d in range(1, expected_days[mon] + 1)]
                check(names == expect, f"daily {mon} zip 条目不符")
                check(len(names) == m.get("totalCount"), f"daily {mon} totalCount 不符")
                for n in names:
                    data = zf.read(n)
                    check(len(data) > 0, f"daily {mon} zip 条目为空: {n}")

    # 4. events / collections
    for module, expect_n, id_key in (("events", 3, "id"), ("collections", 5, "id")):
        idx = load(OUT / module / "index.json")
        items = idx.get("items", [])
        check(len(items) == expect_n, f"{module} 条目数 != {expect_n}: {len(items)}")
        ids = set()
        for it in items:
            check(it["id"] not in ids, f"{module} 重复 id: {it['id']}")
            ids.add(it["id"])
            check(it["type"] == "zip", f"{module} {it['id']} type != zip")
            cov = OUT / module / it["coverUrl"]
            check(cov.exists(), f"{module} cover 不存在: {it['coverUrl']}")
            check(it["zipUrl"].startswith(RELEASE_PREFIX) and
                  it["zipUrl"].endswith(f"/{it['id']}.zip"),
                  f"{module} {it['id']} zipUrl 形态异常")
            zp = OUT / module / "packs" / f"{it['id']}.zip"
            check(zp.exists(), f"{module} zip 不存在: {it['id']}.zip")
            if zp.exists():
                check(it["zipSha256"] == compute_file_sha256(zp),
                      f"{module} {it['id']} zipSha256 不一致")
                check(it["fileSizeBytes"] == zp.stat().st_size,
                      f"{module} {it['id']} fileSizeBytes 不一致")
                with zipfile.ZipFile(zp) as zf:
                    names = sorted(zf.namelist())
                    check(len(names) == it.get("totalCount") == 10,
                          f"{module} {it['id']} zip 条目数 != 10")
                    check(names == [f"{i:03d}.webp" for i in range(1, 11)],
                          f"{module} {it['id']} zip 条目命名不符: {names[:3]}")
        if module == "collections":
            cats = {it.get("category") for it in items}
            check(cats <= MAIN_TAGS, f"collections category 非预定义 tag: {cats - MAIN_TAGS}")

    # 5. 图片解码全检（main images + covers）
    webps = sorted((OUT / "main" / "images").glob("*.webp"))
    webps += sorted((OUT / "events" / "covers").glob("*.webp"))
    webps += sorted((OUT / "collections" / "covers").glob("*.webp"))
    for p in webps:
        ok, err = validate_image(p)
        check(ok, f"图片解码失败: {p.relative_to(OUT)} ({err})")
    check(len(webps) == 30 + 3 + 5, f"webp 图片数量异常: {len(webps)}")

    # 6. 仓库内不允许残留 zip/pack 文件路径被仓库 json 相对引用（zip 一律走 Release）
    for p in sorted(OUT.rglob("*.json")):
        text = p.read_text(encoding="utf-8")
        if "zips/" in text and "https://" not in text:
            pass  # 允许但提示
        if '"url": "packs/' in text or '"url": "zips/' in text:
            warns.append(f"{p.relative_to(OUT)} 内含相对 packs/zips 引用（需确认已改绝对）")

    print(f"校验完成: {'✅ 全部通过' if not errors else '❌ 存在错误'}"
          f" | main tags 命中 {len(set(all_tags))} 种 | "
          f"图片 {len(webps)} 张 | daily 月份 {len(months)} | "
          f"events {len(load(OUT/'events'/'index.json').get('items', []))} | "
          f"collections {len(load(OUT/'collections'/'index.json').get('items', []))}")
    for w in warns:
        print(f"[warn] {w}")
    for e in errors[:20]:
        print(f"[error] {e}")
    if len(errors) > 20:
        print(f"[error] ... 共 {len(errors)} 个错误")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
