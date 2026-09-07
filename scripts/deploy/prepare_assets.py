#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
prepare_assets.py — 从 Jigsaw_Organized 素材库采样构建 jigsaw-data 测试部署素材集

输出（按 studio v2.3.0 规范导出所需的源目录结构）：
  <build>/src_main/           主线关卡素材（平铺，tags.json 记录 tag）
  <build>/src_daily_YYYYMM/   每日挑战按月独立目录，文件名 YYYYMMDD.png
  <build>/src_events/<id>/    活动包（每包 001.png...010.png）
  <build>/src_collections/<id>/ 合集包（同上）
  <build>/assets_plan.json    完整采样清单（供后续脚本复用/审计）

tag 一律取自 taxonomy v3.2.0 预定义主 tag 集合（data/taxonomy.json main_tags）。
本脚本不修改源素材库，仅复制采样文件。
"""

from __future__ import annotations

import calendar
import json
import random
import shutil
import sys
from pathlib import Path

SOURCE = Path(r"C:\Home\Temp\Jigsaw_Organized")
BUILD = Path(r"C:\Home\Temp\jigsawdata_build")
SEED = 20260907

EXT = {".png", ".jpg", ".jpeg", ".webp", ".bmp"}

# taxonomy v3.2.0 预定义主 tag（与 data/taxonomy.json main_tags 对齐，供校验/审计）
MAIN_TAGS = [
    "Landscapes", "Nature", "Flowers", "Animals", "Pets", "Cities",
    "Structures", "Vehicles", "People", "Objects", "Food", "Art",
    "Fantasy", "Holidays", "Colors", "Composition", "Others",
]

# 图片目录池：tag -> 可采样的 Jigsaw_Organized 目录（近似映射，测试数据允许内容与 tag 弱相关）
TAG_DIRS = {
    "Landscapes": ["Landscapes", "Mountains", "Sunsets"],
    "Nature": ["Nature", "Forests", "Botanical", "Seasons"],
    "Flowers": ["Flowers", "Botanical"],
    "Animals": ["Animals", "Wildlife"],
    "Pets": ["Pets", "Cats", "Dogs"],
    "Cities": ["Cities", "Villages", "Architecture"],
    "Structures": ["Castles", "Landmarks", "Architecture"],
    "Vehicles": ["Transportation"],
    "People": ["People"],
    "Objects": ["Objects", "Crafts", "CozyHome", "CoffeeTea"],
    "Food": ["Food", "Sweets", "CoffeeTea"],
    "Art": ["Art", "FineArt", "Illustration"],
    "Fantasy": ["Fantasy", "Mythical", "Space", "Mandala"],
    "Holidays": ["Christmas", "Halloween", "Holidays"],
    "Colors": ["Colors", "Abstract"],
    "Composition": ["Abstract", "FlatLay"],
    "Others": ["Others"],
}

MAIN_TAG_PLAN: list[tuple[str, int]] = [  # (tag, 张数) 共 30
    ("Animals", 8), ("Nature", 4), ("Flowers", 4), ("Structures", 3),
    ("Vehicles", 3), ("Food", 3), ("Cities", 2), ("Fantasy", 2),
    ("Holidays", 1),
]

DAILY_MONTHS = ["202607", "202608", "202609"]  # 31/31/30 天按日历实际天数

EVENTS_PLAN = [
    dict(id="evt_ocean_adventure", title="Ocean Adventure", titleZh="海洋探险",
         desc="10 hand-picked ocean & sealife scenes", descZh="10 张深海与海岸精选",
         startTime="2026-09-10T00:00:00Z", endTime="2026-10-10T00:00:00Z",
         dirs=["Ocean", "SeaLife", "Sunsets"], count=10),
    dict(id="evt_halloween_fun", title="Halloween Fun", titleZh="万圣节狂欢",
         desc="Spooky & cozy Halloween illustrations", descZh="惊悚又温馨的万圣节插画精选",
         startTime="2026-10-20T00:00:00Z", endTime="2026-11-02T00:00:00Z",
         dirs=["Halloween", "People", "Crafts"], count=10),
    dict(id="evt_aurora_dreams", title="Aurora Dreams", titleZh="极光梦境",
         desc="Night skies, aurora and dreamy landscapes", descZh="夜空极光与梦幻风景",
         startTime="2026-12-20T00:00:00Z", endTime="2027-01-05T00:00:00Z",
         dirs=["Sunsets", "Landscapes", "Space", "Mountains"], count=10),
]

COLLECTIONS_PLAN = [
    dict(id="col_wild_animals", title="Wild Animals", titleZh="野生动物精选",
         desc="Majestic wildlife from around the world", descZh="全球野性生灵精选",
         category="Animals", dirs=["Wildlife", "Animals"], count=10),
    dict(id="col_garden_flowers", title="Garden Flowers", titleZh="花园花卉",
         desc="Blooming gardens and fresh flowers", descZh="盛放的花园与鲜花",
         category="Flowers", dirs=["Flowers", "Botanical"], count=10),
    dict(id="col_old_castles", title="Castles & Landmarks", titleZh="古堡与地标",
         desc="Timeless castles and famous landmarks", descZh="不朽古堡与经典地标",
         category="Structures", dirs=["Castles", "Landmarks", "Architecture"], count=10),
    dict(id="col_fantasy_world", title="Fantasy World", titleZh="奇幻世界",
         desc="Dragons, myths and magical worlds", descZh="巨龙神话与魔法世界",
         category="Fantasy", dirs=["Fantasy", "Mythical", "Mandala"], count=10),
    dict(id="col_sweet_food", title="Sweet & Food", titleZh="甜点美食",
         desc="Delicious desserts and gourmet food", descZh="诱人甜品与精致料理",
         category="Food", dirs=["Sweets", "Food", "CoffeeTea"], count=10),
]


def collect_pool() -> dict[str, list[Path]]:
    """按顶层 tag 目录收集全部候选图片（非递归，仅顶层分类目录下的文件）"""
    pool: dict[str, list[Path]] = {}
    for d in SOURCE.iterdir():
        if not d.is_dir() or d.name.startswith("_"):
            continue
        files = [p for p in d.iterdir()
                 if p.is_file() and p.suffix.lower() in EXT and p.stat().st_size > 0]
        files.sort(key=lambda p: p.name)
        pool[d.name] = files
    missing = sorted(set(x for dirs in TAG_DIRS.values() for x in dirs if x not in pool))
    if missing:
        print(f"[warn] 素材目录不存在: {missing}")
    return pool


def pick(pool: dict[str, list[Path]], dirs: list[str], n: int, used: set[Path], rng: random.Random) -> list[Path]:
    """从若干目录随机抽取 n 张未使用的图片；不足则报错"""
    cands = [p for d in dirs for p in pool.get(d, []) if p not in used]
    if len(cands) < n:
        raise RuntimeError(f"候选不足: dirs={dirs} need={n} got={len(cands)}")
    rng.shuffle(cands)
    sel = cands[:n]
    used.update(sel)
    return sel


def copy_renamed(src: Path, dst_dir: Path, name: str) -> Path:
    dst_dir.mkdir(parents=True, exist_ok=True)
    dst = dst_dir / name
    shutil.copy2(src, dst)
    return dst


def main() -> int:
    if not SOURCE.exists():
        print(f"[error] 素材目录不存在: {SOURCE}")
        return 1
    rng = random.Random(SEED)
    pool = collect_pool()
    used: set[Path] = set()
    plan: dict[str, object] = {
        "seed": SEED,
        "source": str(SOURCE),
        "main_tags": MAIN_TAGS,
        "modules": {},
    }

    # 1. main
    src_main = BUILD / "src_main"
    main_tags: list[dict[str, str]] = []
    idx = 0
    for tag, n in MAIN_TAG_PLAN:
        files = pick(pool, TAG_DIRS[tag], n, used, rng)
        for p in files:
            idx += 1
            name = f"main_{idx:03d}.png"
            dst = copy_renamed(p, src_main, name)
            main_tags.append({"path": name, "file": name, "tags": [tag],
                              "confidence": 1.0, "review_required": False})
    (src_main / "tags.json").write_text(
        json.dumps(main_tags, ensure_ascii=False, indent=2), encoding="utf-8")
    plan["modules"]["main"] = {"count": len(main_tags),
                               "tags_file": "src_main/tags.json"}
    print(f"[ok] main 素材 {len(main_tags)} 张 (src_main)")

    # 2. daily（按日历实际天数 31/31/30，文件名 YYYYMMDD）
    #    三个月份必须共用一个素材根 src_daily_all（各自 YYYYMM 子目录），
    #    因为 daily/index.json 按 .studio 工作区累积，跨目录导出会导致月份互相覆盖。
    daily_pool_dirs = ["Landscapes", "Mountains", "Nature", "Ocean", "SeaLife",
                       "Animals", "Flowers", "Cities", "Architecture", "Food",
                       "Art", "Fantasy", "Seasons", "Sunsets", "Villages"]
    daily_root = BUILD / "src_daily_all"
    plan_daily: dict[str, object] = {}
    for month in DAILY_MONTHS:
        y, m = int(month[:4]), int(month[4:])
        ndays = calendar.monthrange(y, m)[1]
        files = pick(pool, daily_pool_dirs, ndays, used, rng)
        month_dir = daily_root / month
        copied = []
        for day, p in enumerate(files, start=1):
            name = f"{month}{day:02d}.png"
            copy_renamed(p, month_dir, name)
            copied.append(name)
        plan_daily[month] = {"days": ndays, "src_dir": f"src_daily_all/{month}",
                             "files": copied}
        print(f"[ok] daily {month} 素材 {ndays} 张 (src_daily_all/{month})")
    plan["modules"]["daily"] = plan_daily

    # 3. events / collections
    for module, sub in (("events", EVENTS_PLAN), ("collections", COLLECTIONS_PLAN)):
        plan_items = []
        root = BUILD / f"src_{module}"
        for item in sub:
            files = pick(pool, item["dirs"], item["count"], used, rng)
            pdir = root / item["id"]
            names = []
            for i, p in enumerate(files, start=1):
                name = f"{i:03d}.png"
                copy_renamed(p, pdir, name)
                names.append(name)
            rec = {k: v for k, v in item.items() if k != "dirs"}
            rec["src_dir"] = f"src_{module}/{item['id']}"
            rec["count"] = len(names)
            plan_items.append(rec)
        plan["modules"][module] = plan_items
        print(f"[ok] {module} 素材: {[it['id'] for it in plan_items]}")

    (BUILD / "assets_plan.json").write_text(
        json.dumps(plan, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[ok] 采样清单已写入 {BUILD / 'assets_plan.json'}")
    print(f"[ok] 素材总量 {len(used)} 张（全局无重复）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
