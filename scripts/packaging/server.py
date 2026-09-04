#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Content Packaging Studio — Local packaging tool for jigsaw puzzle
  python scripts/packaging/server.py
  python scripts/packaging/server.py --port 5173 --open

No build, no npm. Serves index.html + JSON APIs for directory scan / thumb / tags / export.
Works with tags.json produced by scripts/ai_tag_images.py (21-tag taxonomy, single primary tag).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import shutil
import sys
import threading
import urllib.parse
import webbrowser
import re
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any

# Pillow optional for thumbnails
try:
    from PIL import Image  # type: ignore

    HAS_PIL = True
except ImportError:
    HAS_PIL = False

# ---------------------------------------------------------------------------
# Catalogs (11) & Specific Tags (32 + Others)
# Aligned with docs/jigsaw-catalog-tags-mapping-specification-20260904.md v2.2
# Catalogs have 'cat_' prefix; Specific Tags are lowercase with NO prefix.
# ---------------------------------------------------------------------------

CATALOG_DEFS: list[dict[str, Any]] = [
    {"id": "cat_nature", "name": "Nature", "zh": "自然风光", "icon": "🌲"},
    {"id": "cat_animals", "name": "Animals", "zh": "动物萌宠", "icon": "🐾"},
    {"id": "cat_colors", "name": "Colors", "zh": "缤纷色彩", "icon": "🌈"},
    {"id": "cat_flowers", "name": "Flowers", "zh": "花卉园艺", "icon": "🌸"},
    {"id": "cat_cozy", "name": "Cozy", "zh": "温馨生活", "icon": "☕"},
    {"id": "cat_travel", "name": "Travel", "zh": "城市旅行", "icon": "✈️"},
    {"id": "cat_food", "name": "Food", "zh": "美食甜品", "icon": "🍰"},
    {"id": "cat_art", "name": "Art", "zh": "唯美艺术", "icon": "🎨"},
    {"id": "cat_fantasy", "name": "Fantasy", "zh": "奇幻仙境", "icon": "✨"},
    {"id": "cat_holidays", "name": "Holidays", "zh": "节日时令", "icon": "🎉"},
    {"id": "cat_others", "name": "Others", "zh": "其他分类", "icon": "📦"},
]

SPECIFIC_TAG_DEFS: list[dict[str, Any]] = [
    # 动物萌宠 (5)
    {"id": "cats", "name": "Cats", "zh": "猫咪", "catalogs": ["cat_animals"]},
    {"id": "dogs", "name": "Dogs", "zh": "狗狗", "catalogs": ["cat_animals"]},
    {"id": "birds", "name": "Birds", "zh": "飞禽鸟类", "catalogs": ["cat_animals"]},
    {"id": "wildlife", "name": "Wildlife", "zh": "陆地野兽", "catalogs": ["cat_animals", "cat_nature"]},
    {"id": "sealife", "name": "SeaLife", "zh": "海洋水族", "catalogs": ["cat_animals", "cat_nature"]},
    # 自然风光 (4)
    {"id": "mountains", "name": "Mountains", "zh": "山峦湖泊", "catalogs": ["cat_nature"]},
    {"id": "forests", "name": "Forests", "zh": "森林自然", "catalogs": ["cat_nature"]},
    {"id": "oceans", "name": "Oceans", "zh": "海洋海岸", "catalogs": ["cat_nature", "cat_travel"]},
    {"id": "sunsets", "name": "Sunsets", "zh": "日落晚霞", "catalogs": ["cat_nature"]},
    # 建筑旅行 (3)
    {"id": "landmarks", "name": "Landmarks", "zh": "名胜地标", "catalogs": ["cat_travel"]},
    {"id": "castles", "name": "Castles", "zh": "古堡宫殿", "catalogs": ["cat_travel", "cat_fantasy"]},
    {"id": "villages", "name": "Villages", "zh": "街景小镇", "catalogs": ["cat_travel"]},
    # 花卉园艺 (2)
    {"id": "flowers", "name": "Flowers", "zh": "花卉花园", "catalogs": ["cat_flowers"]},
    {"id": "botanical", "name": "Botanical", "zh": "绿植微观", "catalogs": ["cat_flowers"]},
    # 温馨生活 (4)
    {"id": "cottages", "name": "Cottages", "zh": "乡村木屋", "catalogs": ["cat_cozy"]},
    {"id": "cozy_home", "name": "CozyHome", "zh": "温馨室内", "catalogs": ["cat_cozy"]},
    {"id": "vintage", "name": "Vintage", "zh": "复古珍奇", "catalogs": ["cat_cozy", "cat_travel"]},
    {"id": "crafts", "name": "Crafts", "zh": "手作布艺", "catalogs": ["cat_cozy", "cat_colors"]},
    # 美食甜品 (3)
    {"id": "desserts", "name": "Desserts", "zh": "甜点茶饮", "catalogs": ["cat_food"]},
    {"id": "cuisine", "name": "Cuisine", "zh": "环球料理", "catalogs": ["cat_food"]},
    {"id": "fruits", "name": "Fruits", "zh": "鲜果时蔬", "catalogs": ["cat_food"]},
    # 缤纷色彩 (3)
    {"id": "colors", "name": "Colors", "zh": "彩虹色彩", "catalogs": ["cat_colors", "cat_fantasy"]},
    {"id": "flat_lay", "name": "FlatLay", "zh": "俯拍平铺", "catalogs": ["cat_colors"]},
    {"id": "mandalas", "name": "Mandalas", "zh": "曼陀罗图腾", "catalogs": ["cat_colors", "cat_art"]},
    # 唯美艺术 (3)
    {"id": "fine_art", "name": "FineArt", "zh": "经典名画", "catalogs": ["cat_art"]},
    {"id": "illustrations", "name": "Illustrations", "zh": "治愈插画", "catalogs": ["cat_art"]},
    {"id": "oriental", "name": "Oriental", "zh": "国风东方", "catalogs": ["cat_art"]},
    # 奇幻神秘 (2)
    {"id": "mythical", "name": "Mythical", "zh": "奇幻神兽", "catalogs": ["cat_fantasy"]},
    {"id": "zodiac", "name": "Zodiac", "zh": "星座星象", "catalogs": ["cat_fantasy"]},
    # 节日时令 (2)
    {"id": "holidays", "name": "Holidays", "zh": "节庆假日", "catalogs": ["cat_holidays"]},
    {"id": "seasons", "name": "Seasons", "zh": "四季节令", "catalogs": ["cat_holidays", "cat_nature"]},
    # 兜底 (1)
    {"id": "others", "name": "Others", "zh": "其他分类", "catalogs": ["cat_others"]},
]

TAG_ZH: dict[str, str] = {item["id"]: item["zh"] for item in SPECIFIC_TAG_DEFS}

CATALOG_TO_TAGS_MAP: dict[str, list[str]] = {
    "cat_nature": ["mountains", "forests", "oceans", "sunsets", "seasons"],
    "cat_animals": ["cats", "dogs", "birds", "wildlife", "sealife"],
    "cat_colors": ["colors", "flat_lay", "mandalas", "crafts"],
    "cat_flowers": ["flowers", "botanical"],
    "cat_cozy": ["cottages", "cozy_home", "vintage", "crafts"],
    "cat_travel": ["landmarks", "castles", "villages", "vintage"],
    "cat_food": ["desserts", "cuisine", "fruits"],
    "cat_art": ["fine_art", "illustrations", "oriental", "mandalas"],
    "cat_fantasy": ["mythical", "zodiac", "colors"],
    "cat_holidays": ["holidays", "seasons"],
    "cat_others": ["others"],
}

TAG_TO_CATALOGS: dict[str, list[str]] = {}
for cid, tlist in CATALOG_TO_TAGS_MAP.items():
    for t in tlist:
        TAG_TO_CATALOGS.setdefault(t, []).append(cid)
TAG_TO_CATALOGS.setdefault("others", ["cat_others"])

ALL_CANONICAL_TAGS = [item["id"] for item in SPECIFIC_TAG_DEFS]
TAGS_21 = ALL_CANONICAL_TAGS

# Comprehensive synonym and alias dictionary for smart path & filename recognition
ALIASES: dict[str, list[str]] = {
    "cats": ["cat", "cats", "kitten", "kittens", "kitty", "猫", "猫咪"],
    "dogs": ["dog", "dogs", "puppy", "puppies", "狗", "狗狗"],
    "birds": ["bird", "birds", "鸟", "鸟类", "飞禽"],
    "wildlife": ["wildlife", "beast", "beasts", "safari", "野兽", "野生动物"],
    "sealife": ["sealife", "sea_life", "marine", "underwater", "oceanlife", "fish", "fishes", "水族", "海洋生物"],
    "mountains": ["mountain", "mountains", "lake", "lakes", "alps", "waterfall", "waterfalls", "山", "山峦", "雪山", "湖泊", "瀑布"],
    "forests": ["forest", "forests", "wood", "woods", "森林", "树林"],
    "oceans": ["ocean", "oceans", "beach", "beaches", "sea", "seas", "coast", "coasts", "shore", "海洋", "海滩", "海岸"],
    "sunsets": ["sunset", "sunsets", "sunrise", "sunrises", "dusk", "dawn", "晚霞", "日落", "朝霞", "夕阳"],
    "landmarks": ["landmark", "landmarks", "city", "cities", "tower", "architecture", "地标", "名胜", "城市"],
    "castles": ["castle", "castles", "palace", "palaces", "城堡", "古堡", "宫殿"],
    "villages": ["village", "villages", "town", "towns", "小镇", "村庄", "水乡", "街景"],
    "flowers": ["flower", "flowers", "floral", "garden", "rose", "roses", "bloom", "花", "花卉", "花园"],
    "botanical": ["botanical", "botanicals", "plant", "plants", "succulent", "succulents", "mushroom", "mushrooms", "植物", "绿植", "多肉", "菌菇"],
    "cottages": ["cottage", "cottages", "cabin", "cabins", "木屋", "乡村木屋", "小屋"],
    "cozy_home": ["cozy_home", "cozyhome", "interior", "interiors", "room", "rooms", "livingroom", "bedroom", "居室", "室内", "温馨室内", "壁炉"],
    "vintage": ["vintage", "retro", "antique", "antiques", "nostalgia", "car", "cars", "automobile", "classiccar", "classiccars", "vintagecar", "vintagecars", "复古", "怀旧", "老车", "古董", "老爷车"],
    "crafts": ["craft", "crafts", "sewing", "knitting", "yarn", "handcraft", "手作", "毛线", "缝纫", "布艺", "编织"],
    "desserts": ["dessert", "desserts", "sweet", "sweets", "cake", "cakes", "bakery", "candy", "candies", "pastry", "pastries", "cookie", "cookies", "coffee", "tea", "coffeetea", "cafe", "afternoontea", "甜点", "烘焙", "蛋糕", "咖啡", "茶饮", "下午茶"],
    "cuisine": ["cuisine", "cuisines", "food", "foods", "meal", "meals", "cooking", "dish", "dishes", "noodle", "noodles", "pizza", "sushi", "ramen", "bbq", "dinner", "美食", "料理", "火锅", "餐饮"],
    "fruits": ["fruit", "fruits", "berry", "berries", "citrus", "orange", "apple", "vegetable", "vegetables", "水果", "鲜果", "果盘"],
    "colors": ["color", "colors", "colour", "colours", "rainbow", "colorful", "色彩", "彩虹", "高饱和", "五彩"],
    "flat_lay": ["flatlay", "flat_lay", "knolling", "平铺", "俯拍"],
    "mandalas": ["mandala", "mandalas", "kaleidoscope", "pattern", "patterns", "曼陀罗", "万花筒", "图腾"],
    "fine_art": ["fineart", "fine_art", "masterpiece", "oilpainting", "oil_painting", "painting", "paintings", "名画", "经典名画", "古典艺术", "油画"],
    "illustrations": ["illustration", "illustrations", "illust", "cartoon", "drawing", "drawings", "clipart", "插画", "治愈插画", "手绘"],
    "oriental": ["oriental", "guochao", "chinese", "asian_art", "国风", "古风", "东方", "国潮"],
    "mythical": ["mythical", "myth", "dragon", "dragons", "unicorn", "unicorns", "fairy", "fairies", "fantasy_creature", "神兽", "奇幻神兽", "独角兽"],
    "zodiac": ["zodiac", "astrology", "constellation", "constellations", "horoscope", "star", "stars", "星座", "星盘", "星象"],
    "holidays": ["holiday", "holidays", "christmas", "xmas", "noel", "santa", "halloween", "pumpkin", "pumpkins", "witch", "easter", "thanksgiving", "newyear", "valentine", "carnival", "节日", "节庆", "假日", "圣诞", "圣诞节", "万圣", "万圣节", "复活节", "感恩节", "新年", "元旦"],
    "seasons": ["season", "seasons", "seasonal", "spring", "summer", "autumn", "winter", "四季", "时令", "节气"],
    "others": ["others", "other", "misc", "杂项", "其他"],
}

TAG_LOOKUP_MAP: dict[str, str] = {}
for tag_key, aliases in ALIASES.items():
    TAG_LOOKUP_MAP[tag_key.lower().replace("_", "")] = tag_key
    for a in aliases:
        norm = a.lower().replace("_", "").replace("-", "").replace(" ", "")
        TAG_LOOKUP_MAP[norm] = tag_key

for item in SPECIFIC_TAG_DEFS:
    TAG_LOOKUP_MAP[item["name"].lower().replace("_", "")] = item["id"]
    TAG_LOOKUP_MAP[item["zh"].lower().replace("_", "")] = item["id"]


def normalize_token(w: str | None) -> str | None:
    """Normalize word/token to canonical tag key, handling case and singular/plural."""
    if not w or not str(w).strip():
        return None
    raw = str(w).strip().lower()
    norm = re.sub(r"[_\-\s]+", "", raw)
    if not norm:
        return None
    if norm in TAG_LOOKUP_MAP:
        return TAG_LOOKUP_MAP[norm]
    # Check plural endings (ies -> y, es, s)
    if norm.endswith("ies") and len(norm) > 4:
        cand = norm[:-3] + "y"
        if cand in TAG_LOOKUP_MAP:
            return TAG_LOOKUP_MAP[cand]
    elif norm.endswith("es") and len(norm) > 3:
        cand = norm[:-2]
        if cand in TAG_LOOKUP_MAP:
            return TAG_LOOKUP_MAP[cand]
    elif norm.endswith("s") and not norm.endswith("ss") and len(norm) > 2:
        cand = norm[:-1]
        if cand in TAG_LOOKUP_MAP:
            return TAG_LOOKUP_MAP[cand]
    return None


def normalize_tag(tag: str | None) -> str | None:
    """Normalize any tag string, tag ID, or directory name to canonical tag key."""
    return normalize_token(tag)


def get_catalogs_for_tags(tags: list[str]) -> list[str]:
    """Get list of mapped catalog IDs for a list of tags. Defaults to ['cat_others']."""
    cats: list[str] = []
    for t in tags:
        canon = normalize_token(t) or "others"
        for c in TAG_TO_CATALOGS.get(canon, []):
            if c not in cats:
                cats.append(c)
    return cats if cats else ["cat_others"]


def get_catalogs_for_tag(tag: str | None) -> list[str]:
    """Get list of mapped catalog IDs for a single tag. Defaults to ['cat_others']."""
    return get_catalogs_for_tags([tag] if tag else [])


def match_dir_part(part: str) -> str | None:
    """Try to match a directory component to a canonical tag key."""
    p_lower = part.lower().strip()
    if p_lower.startswith("cat_") or any(c["id"] == p_lower for c in CATALOG_DEFS):
        return None
    t = normalize_token(part)
    if t and t != "others":
        return t
    words = re.split(r"[^a-zA-Z0-9\u4e00-\u9fa5]+", part)
    for w in words:
        if not w:
            continue
        t = normalize_token(w)
        if t and t != "others":
            return t
    return None


def guess_tags_from_path(img_path: str | Path) -> list[str]:
    """
    Tag recognition from directory only:
    Check parent directories from innermost upwards. If any directory matches a tag,
    return matched tag(s).
    Strictly do NOT check filename.
    If no parent directory matched any tag, return ['others'].
    """
    parts = Path(img_path).parts
    if len(parts) >= 2:
        for part in reversed(parts[:-1]):
            p_lower = part.lower().strip()
            if p_lower.startswith("cat_") or any(c["id"] == p_lower for c in CATALOG_DEFS):
                continue
            # 1. Try full directory name
            t = normalize_token(part)
            if t and t != "others":
                return [t]
            # 2. Try splitting directory name by delimiters
            words = re.split(r"[^a-zA-Z0-9\u4e00-\u9fa5]+", part)
            matched_tags: list[str] = []
            for w in words:
                if not w:
                    continue
                matched = normalize_token(w)
                if matched and matched != "others" and matched not in matched_tags:
                    matched_tags.append(matched)
            if matched_tags:
                return matched_tags

    return ["others"]


def guess_tag_from_path(img_path: str | Path) -> str | None:
    """Legacy helper: returns primary guessed tag."""
    tags = guess_tags_from_path(img_path)
    return tags[0] if tags and tags != ["others"] else None

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".tif", ".tiff"}

# Keep docs/puzzle-content-storage-and-expansion-design.md §4.1 / §4.3 compliant
# main.json: { version, levels:[{url, tags:[single], order}] }
# events.json: handled separately if needed


def scan_images(root: str | Path) -> list[Path]:
    r = Path(root)
    return sorted(
        p for p in r.rglob("*") if p.is_file() and p.suffix.lower() in IMAGE_EXTS
    )


def find_tags_file(root: str | Path) -> Path | None:
    r = Path(root)
    for name in ("tags.json", "ai_tags.json", "puzzle_tags.json", ".puzzle_tags.json"):
        cand = r / name
        if cand.exists():
            return cand
    return None


def load_tags_file(p: Path) -> Any:
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:
        return {"_error": str(e)}


def normalize_tags_records(raw: Any, root: Path) -> tuple[list[dict[str, Any]], str]:
    """
    Normalize both legacy and multi-tag formats:
      - ai_tag_images.py: list[{path, sha1, tag, confidence, review_required, ...}]
      - studio intermediate dict: {version, images:[{file, tags:[...], ...}]}
      - studio v2.2 list: list[{path, tags:[...], catalogs:[...], ...}]
    Returns (records_list, format_name)
      records_list items: {path, file, tags, catalogs, confidence, review_required, subject, scene, reason, sha1, model}
    """
    records: list[dict[str, Any]] = []

    def extract_tags(item: dict[str, Any], rel_path: str) -> list[str]:
        if "tags" in item and isinstance(item["tags"], list) and item["tags"]:
            res: list[str] = []
            for t in item["tags"]:
                canon = normalize_token(str(t)) or str(t).strip().lower()
                if canon and canon not in res:
                    res.append(canon)
            if res:
                return res
        raw_t = (item.get("correctedTag") or item.get("tag") or "").strip()
        if raw_t:
            canon = normalize_token(raw_t) or "others"
            return [canon]
        if rel_path:
            return guess_tags_from_path(root / rel_path)
        return ["others"]

    if isinstance(raw, list):
        for item in raw:
            if not isinstance(item, dict):
                continue
            rel = (item.get("path") or item.get("file") or "").replace("\\", "/")
            tags = extract_tags(item, rel)
            cats = get_catalogs_for_tags(tags)
            records.append(
                {
                    "path": rel,
                    "file": Path(rel).name,
                    "tags": tags,
                    "catalogs": cats,
                    "confidence": float(item.get("confidence", 0) or 0),
                    "review_required": bool(item.get("review_required", False)) or ("others" in tags),
                    "subject": item.get("subject", ""),
                    "scene": item.get("scene", ""),
                    "reason": item.get("reason", ""),
                    "sha1": item.get("sha1", ""),
                    "model": item.get("model", ""),
                }
            )
        return records, "list"

    if isinstance(raw, dict):
        if "images" in raw and isinstance(raw["images"], list):
            for item in raw["images"]:
                rel = (item.get("file") or item.get("path") or "").replace("\\", "/")
                tags = extract_tags(item, rel)
                cats = get_catalogs_for_tags(tags)
                records.append(
                    {
                        "path": rel,
                        "file": Path(rel).name,
                        "tags": tags,
                        "catalogs": cats,
                        "confidence": float(item.get("confidence", 0) or 0),
                        "review_required": bool(item.get("review_required", False)) or ("others" in tags),
                        "subject": item.get("subject", ""),
                        "scene": item.get("scene", ""),
                        "reason": item.get("reason", ""),
                        "sha1": item.get("sha1", ""),
                        "model": item.get("model", ""),
                    }
                )
            return records, "dict-images"
        return records, "dict-unknown"

    return records, "unknown"


def build_main_levels(
    records: list[dict[str, Any]],
    image_paths: list[Path],
    root: Path,
    http_base: str,
) -> list[dict[str, Any]]:
    """
    Build levels for main.json from records + filesystem.
    Url = http_base + "/main/" + filename (preserve ext)
    Order = natural sort order (1-indexed for display)
    Tags = array of tags, completely compatible with Dart LevelItem(url, tags, order).
    """
    tag_map: dict[str, list[str]] = {}
    for r in records:
        key = (r.get("path") or r.get("file") or "").replace("\\", "/")
        tags = r.get("tags")
        if not tags and (r.get("correctedTag") or r.get("tag")):
            canon = normalize_token(str(r.get("correctedTag") or r.get("tag"))) or "others"
            tags = [canon]
        if tags and isinstance(tags, list):
            norm_tags = [normalize_token(t) or t.lower() for t in tags]
        else:
            norm_tags = ["others"]
        tag_map[key] = norm_tags
        bn = Path(key).name
        if bn not in tag_map:
            tag_map[bn] = norm_tags

    levels: list[dict[str, Any]] = []
    sorted_paths = sorted(
        image_paths, key=lambda p: p.relative_to(root).as_posix().lower()
    )

    base = http_base.rstrip("/")
    start = 101

    for idx, p in enumerate(sorted_paths):
        rel = p.relative_to(root).as_posix().replace("\\", "/")
        bn = p.name
        tags = tag_map.get(rel) or tag_map.get(bn)
        if not tags or tags == ["others"]:
            guessed = guess_tags_from_path(p)
            if guessed:
                tags = guessed
        if not tags:
            tags = ["others"]
        tags = [normalize_token(t) or t.lower() for t in tags]

        url = f"{base}/main/{urllib.parse.quote(bn)}"
        levels.append(
            {
                "url": url,
                "tags": tags,
                "order": start + idx,
                "_file": rel,
            }
        )

    return levels


# ---------------------------------------------------------------------------
# Export helpers — format conversion, rename, daily.json builder
# ---------------------------------------------------------------------------


def convert_image(
    src_path: Path, dst_path: Path, fmt: str = "original", quality: int = 85
) -> tuple[bool, str | None]:
    """Convert image format using PIL. Returns (success, error_msg)."""
    if fmt == "original" or not HAS_PIL:
        if src_path.resolve() != dst_path.resolve():
            shutil.copy2(src_path, dst_path)
        return True, None
    try:
        with Image.open(src_path) as im:  # type: ignore
            try:
                from PIL import ImageOps  # type: ignore

                im = ImageOps.exif_transpose(im)  # type: ignore
            except Exception:
                pass
            if im.mode not in ("RGB", "RGBA"):
                im = im.convert("RGB")  # type: ignore
            if fmt == "webp":
                im.save(dst_path, "WEBP", quality=quality, method=6)  # type: ignore
            elif fmt in ("jpg", "jpeg"):
                if im.mode == "RGBA":
                    bg = Image.new("RGB", im.size, (255, 255, 255))  # type: ignore
                    bg.paste(im, mask=im.split()[3])  # type: ignore
                    im = bg  # type: ignore
                im.save(dst_path, "JPEG", quality=quality, optimize=True)  # type: ignore
            elif fmt == "png":
                im.save(dst_path, "PNG", optimize=True)  # type: ignore
            else:
                shutil.copy2(src_path, dst_path)
            return True, None
    except Exception as e:
        return False, str(e)


def make_rename(
    original_name: str, idx: int, rule: str, fmt: str, month: str = ""
) -> str:
    """Generate new filename based on rename rule."""
    if rule == "none":
        if fmt != "original":
            return Path(original_name).stem + f".{fmt}"
        return original_name
    elif rule == "sequence":
        ext = f".{fmt}" if fmt != "original" else Path(original_name).suffix
        return f"{idx:03d}{ext}"
    elif rule == "date":
        ext = f".{fmt}" if fmt != "original" else ".webp"
        if month:
            dd = f"{idx:02d}"
            return f"{month}{dd}{ext}"
        import datetime as _dt

        return f"{_dt.datetime.now().strftime('%Y%m%d')}_{idx:03d}{ext}"
    return original_name


def build_daily_json(
    out_p: Path, http_base: str, current_month: str, log
) -> dict[str, Any]:
    """Read existing daily.json, upsert current month, return payload."""
    daily_json = out_p / "daily.json"
    existing: dict[str, Any] = {}
    if daily_json.exists():
        try:
            existing = json.loads(daily_json.read_text(encoding="utf-8"))
        except Exception:
            existing = {}
    months = existing.get("months", [])
    month_entry = {
        "month": current_month,
        "type": "zip",
        "url": f"{http_base}/daily/{current_month}.zip",
    }
    found = False
    for i, m in enumerate(months):
        if m.get("month") == current_month:
            months[i] = month_entry
            found = True
            break
    if not found:
        months.insert(0, month_entry)
    return {
        "version": existing.get("version", 0),
        "updatedAt": __import__("datetime")
        .datetime.now(__import__("datetime").timezone.utc)
        .isoformat()
        .replace("+00:00", "Z"),
        "currentMonth": current_month,
        "months": months,
    }


class Handler(BaseHTTPRequestHandler):
    # class var set by main()
    serve_dir: Path = Path(__file__).parent

    def log_message(self, format, *args):
        # quiet except errors; print to stdout
        sys.stdout.write(f"[{self.log_date_time_string()}] {format % args}\n")

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)

        # Static
        if path in ("/", "/index.html"):
            self._serve_file(self.serve_dir / "index.html", "text/html; charset=utf-8")
            return
        if path == "/api/health":
            self._json({
                "ok": True,
                "has_pil": HAS_PIL,
                "tags": ALL_CANONICAL_TAGS,
                "catalogs": CATALOG_DEFS,
                "specific_tags": SPECIFIC_TAG_DEFS,
                "catalog_tags_map": CATALOG_TO_TAGS_MAP,
                "tag_to_catalogs": TAG_TO_CATALOGS,
                "tag_zh": TAG_ZH,
            })
            return
        if path == "/api/scan":
            self._handle_scan(qs)
            return
        if path == "/api/thumb":
            self._handle_thumb(qs)
            return
        if path == "/api/tags":
            self._handle_get_tags(qs)
            return
        if path == "/api/file":
            # serve arbitrary image for preview (same as thumb but full)
            self._handle_file(qs)
            return

        # fallback static
        rel = Path(path.lstrip("/"))
        cand = self.serve_dir / rel
        if cand.exists() and cand.is_file():
            ctype, _ = mimetypes.guess_type(str(cand))
            self._serve_file(cand, ctype or "application/octet-stream")
            return

        self.send_error(404, f"Not found: {path}")

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        try:
            data = json.loads(body.decode("utf-8")) if body else {}
        except Exception:
            data = {}

        if path == "/api/tags":
            self._handle_post_tags(data)
            return
        if path == "/api/export/main":
            self._handle_export_main(data)
            return
        if path == "/api/export/events":
            self._handle_export_events(data)
            return
        if path == "/api/export/daily":
            self._handle_export_daily(data)
            return
        if path == "/api/export":
            self._handle_export(data)
            return

        self.send_error(404, f"Not found POST {path}")

    # ---- handlers ----

    def _json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self._cors()
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_file(self, p: Path, ctype: str):
        if not p.exists():
            self.send_error(404, str(p))
            return
        data = p.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self._cors()
        self.send_header("Content-Length", str(len(data)))
        # cache thumbs
        if "thumb" in self.path:
            self.send_header("Cache-Control", "public, max-age=3600")
        self.end_headers()
        self.wfile.write(data)

    def _handle_scan(self, qs):
        dir_s = (qs.get("dir") or qs.get("path") or [""])[0]
        if not dir_s:
            self._json({"error": "missing ?dir=PATH"}, 400)
            return
        root = Path(dir_s)
        if not root.exists():
            self._json({"error": f"dir not found: {dir_s}"}, 404)
            return
        if not root.is_dir():
            self._json({"error": f"not a directory: {dir_s}"}, 400)
            return

        images = scan_images(root)
        tag_file = find_tags_file(root)
        tag_records: list[dict[str, Any]] | None = None
        tag_format: str | None = None
        tag_error: str | None = None
        raw_tags: Any = None
        if tag_file is not None:
            raw_tags = load_tags_file(tag_file)
            if isinstance(raw_tags, dict) and "_error" in raw_tags:
                tag_error = raw_tags["_error"]
            else:
                tag_records, tag_format = normalize_tags_records(raw_tags, root)

        # build response
        img_list = []
        for p in images:
            try:
                stat = p.stat()
                rel = p.relative_to(root).as_posix().replace("\\", "/")
                img_list.append(
                    {
                        "path": rel,
                        "file": p.name,
                        "size": stat.st_size,
                        "mtime": int(stat.st_mtime),
                    }
                )
            except Exception:
                continue

        # If no tags file existed, auto initialize tag_records using guess_tags_from_path!
        if tag_records is None:
            tag_records = []
            for p in images:
                rel = p.relative_to(root).as_posix().replace("\\", "/")
                guessed = guess_tags_from_path(p)
                cats = get_catalogs_for_tags(guessed)
                tag_records.append({
                    "path": rel,
                    "file": p.name,
                    "tags": guessed,
                    "catalogs": cats,
                    "confidence": 1.0 if guessed != ["others"] else 0.0,
                    "review_required": (guessed == ["others"]),
                    "subject": "",
                    "scene": "",
                    "reason": f"自动识别: {', '.join(guessed)}" if guessed != ["others"] else "未打标",
                    "sha1": "",
                    "model": "rule",
                })
        else:
            # Check for any new images not in tag_records
            known_paths = {r["path"].replace("\\", "/") for r in tag_records}
            for p in images:
                rel = p.relative_to(root).as_posix().replace("\\", "/")
                if rel not in known_paths:
                    guessed = guess_tags_from_path(p)
                    cats = get_catalogs_for_tags(guessed)
                    tag_records.append({
                        "path": rel,
                        "file": p.name,
                        "tags": guessed,
                        "catalogs": cats,
                        "confidence": 1.0 if guessed != ["others"] else 0.0,
                        "review_required": (guessed == ["others"]),
                        "subject": "",
                        "scene": "",
                        "reason": f"新增自动识别: {', '.join(guessed)}" if guessed != ["others"] else "新增未打标",
                        "sha1": "",
                        "model": "rule",
                    })

        # stats by tags
        tag_stats: dict[str, int] = {}
        review_count = 0
        for r in tag_records:
            tags = r.get("tags", [])
            for t in tags:
                tag_stats[t] = tag_stats.get(t, 0) + 1
            if r.get("review_required") or "others" in tags:
                review_count += 1

        self._json(
            {
                "dir": str(root.resolve()),
                "tagFile": str(tag_file.resolve()) if tag_file else None,
                "tagFormat": tag_format,
                "tagError": tag_error,
                "tagRecords": tag_records,
                "rawTags": raw_tags
                if isinstance(raw_tags, list) and len(str(raw_tags)) < 20000
                else None,
                "images": img_list,
                "total": len(img_list),
                "stats": {"byTag": tag_stats, "reviewCount": review_count},
            }
        )

    def _handle_get_tags(self, qs):
        dir_s = (qs.get("dir") or [""])[0]
        if not dir_s:
            self._json({"error": "missing ?dir"}, 400)
            return
        root = Path(dir_s)
        tag_file = find_tags_file(root)
        if tag_file is None:
            alt = qs.get("path", [None])[0]
            if alt and Path(alt).exists():
                tag_file = Path(alt)
            else:
                self._json({"error": "tags.json not found", "dir": str(root)}, 404)
                return
        raw = load_tags_file(tag_file)
        self._json({"file": str(tag_file), "data": raw})

    def _handle_post_tags(self, data):
        dir_s = data.get("dir") or data.get("root") or ""
        records = data.get("records") or data.get("images") or data.get("tags")
        if not dir_s:
            self._json({"error": "missing dir"}, 400)
            return
        root = Path(dir_s)
        if not root.exists():
            self._json({"error": "dir not found"}, 404)
            return
        if records is None:
            self._json({"error": "missing records"}, 400)
            return

        existing_raw = None
        tag_file = root / "tags.json"
        existing = find_tags_file(root)
        if existing and existing.exists():
            existing_raw = load_tags_file(existing)
            tag_file = existing

        sha_map: dict[str, str] = {}
        if isinstance(existing_raw, list):
            for item in existing_raw:
                if isinstance(item, dict) and item.get("path"):
                    sha_map[item["path"]] = item.get("sha1", "")

        out_list: list[dict[str, Any]] = []
        flat: list[dict[str, Any]]
        if isinstance(records, dict) and "images" in records:
            flat = records["images"]  # type: ignore
        elif isinstance(records, list):
            flat = records  # type: ignore
        else:
            flat = []

        for item in flat:
            if not isinstance(item, dict):
                continue
            rel = (item.get("path") or item.get("file") or "").replace("\\", "/")
            if not rel:
                continue

            raw_tags = item.get("tags")
            tags_list: list[str] = []
            if isinstance(raw_tags, list):
                for t in raw_tags:
                    canon = normalize_token(str(t)) or str(t).strip().lower()
                    if canon and canon not in tags_list:
                        tags_list.append(canon)
            elif item.get("correctedTag") or item.get("tag"):
                raw_s = str(item.get("correctedTag") or item.get("tag"))
                canon = normalize_token(raw_s) or "others"
                tags_list = [canon]

            if not tags_list:
                tags_list = ["others"]

            cats = get_catalogs_for_tags(tags_list)
            conf = item.get("confidence", 0.8)
            try:
                conf = float(conf)
            except Exception:
                conf = 0.8

            review = bool(item.get("review_required", False))
            if conf < 0.75 or "others" in tags_list:
                review = True

            out_list.append(
                {
                    "path": rel,
                    "sha1": item.get("sha1") or sha_map.get(rel, ""),
                    "tags": tags_list,
                    "catalogs": cats,
                    "confidence": conf,
                    "subject": item.get("subject", ""),
                    "scene": item.get("scene", ""),
                    "reason": item.get("reason", ""),
                    "review_required": review,
                    "model": item.get("model", "manual"),
                    "taxonomy_version": "jigsaw-tag-v2.2-32",
                }
            )

        # atomic write
        tmp = tag_file.with_suffix(tag_file.suffix + ".tmp")
        tmp.write_text(
            json.dumps(out_list, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        tmp.replace(tag_file)

        self._json(
            {"ok": True, "file": str(tag_file.resolve()), "count": len(out_list)}
        )

    def _handle_thumb(self, qs):
        path_s = (qs.get("path") or qs.get("p") or [""])[0]
        size_s = (qs.get("size") or qs.get("s") or ["360"])[0]
        try:
            size = int(size_s)
            size = max(64, min(size, 800))
        except Exception:
            size = 360

        if not path_s:
            self.send_error(400, "missing ?path")
            return
        # path may be absolute or relative; try resolve
        p = Path(path_s)
        if not p.exists():
            # try url decoding
            p = Path(urllib.parse.unquote(path_s))
        if not p.exists():
            self.send_error(404, f"file not found: {path_s}")
            return
        if not p.is_file():
            self.send_error(404, "not a file")
            return

        # If PIL available, resize; else serve original
        if HAS_PIL:
            try:
                # Use Pillow to generate thumbnail
                with Image.open(p) as im:  # type: ignore
                    # exif transpose
                    try:
                        from PIL import ImageOps  # type: ignore

                        im = ImageOps.exif_transpose(im)  # type: ignore
                    except Exception:
                        pass
                    # convert to RGB if needed for JPEG thumb
                    if im.mode not in ("RGB", "RGBA"):
                        im = im.convert("RGB")  # type: ignore
                    # thumbnail
                    im.thumbnail((size, size), Image.LANCZOS)  # type: ignore
                    # save to bytes
                    import io

                    buf = io.BytesIO()
                    # Use WEBP for smaller transfer if supported, else JPEG
                    # Browser supports webp, but to keep simple use JPEG
                    # Preserve transparency? convert to JPEG
                    if im.mode == "RGBA":
                        # composite on white
                        bg = Image.new("RGB", im.size, (255, 255, 255))  # type: ignore
                        bg.paste(im, mask=im.split()[3])  # type: ignore
                        im = bg  # type: ignore
                    im.save(buf, format="JPEG", quality=82, optimize=True)  # type: ignore
                    data = buf.getvalue()
                    self.send_response(200)
                    self.send_header("Content-Type", "image/jpeg")
                    self.send_header("Content-Length", str(len(data)))
                    self.send_header("Cache-Control", "public, max-age=3600")
                    self._cors()
                    self.end_headers()
                    self.wfile.write(data)
                    return
            except Exception as e:
                # fallback to original
                sys.stderr.write(f"thumb error {p}: {e}\n")

        # fallback: serve original file bytes
        ctype, _ = mimetypes.guess_type(str(p))
        self._serve_file(p, ctype or "image/jpeg")

    def _handle_file(self, qs):
        path_s = (qs.get("path") or [""])[0]
        if not path_s:
            self.send_error(400, "missing ?path")
            return
        p = Path(urllib.parse.unquote(path_s))
        if not p.exists():
            self.send_error(404, f"file not found: {path_s}")
            return
        ctype, _ = mimetypes.guess_type(str(p))
        self._serve_file(p, ctype or "application/octet-stream")

    # ------------------------------------------------------------------
    # Unified export — POST /api/export
    # ------------------------------------------------------------------

    def _handle_export(self, data):
        import datetime as dt

        exp_type = data.get("type", "main")
        src = (data.get("srcDir") or "").strip()
        out = (data.get("outDir") or "").strip()
        http_base = (data.get("httpBase") or "").strip().rstrip("/")
        fmt = data.get("format", "original")
        rename_rule = data.get("rename", "none")
        title = data.get("title", "")
        output_mode = data.get("outputMode", "zip")
        raw_records = data.get("tagsRecords") or []

        logs: list[dict[str, str]] = []

        def log(msg, level="info"):
            logs.append(
                {
                    "t": dt.datetime.now().strftime("%H:%M:%S"),
                    "level": level,
                    "msg": msg,
                }
            )

        if not src or not out:
            self._json({"ok": False, "error": "missing srcDir/outDir"}, 400)
            return
        src_p = Path(src)
        out_p = Path(out)
        if not src_p.exists() or not src_p.is_dir():
            self._json({"ok": False, "error": f"src not found: {src}"}, 404)
            return

        log(f"开始导出 {exp_type}...")
        log(f"源: {src}")
        log(f"输出: {out}")
        if fmt != "original":
            log(f"格式转换: {fmt}")
        if rename_rule != "none":
            log(f"重命名: {rename_rule}")

        out_p.mkdir(parents=True, exist_ok=True)
        files: list[str] = []

        try:
            if exp_type == "main":
                r = self._exp_main(
                    src_p, out_p, http_base, fmt, rename_rule, data, raw_records, log
                )
            elif exp_type == "daily":
                r = self._exp_daily(
                    src_p, out_p, http_base, fmt, rename_rule, data, log
                )
            elif exp_type == "event":
                r = self._exp_event(
                    src_p, out_p, http_base, fmt, rename_rule, data, output_mode, log
                )
            elif exp_type == "collection":
                r = self._exp_collection(
                    src_p, out_p, http_base, fmt, rename_rule, data, output_mode, log
                )
            else:
                self._json(
                    {"ok": False, "error": f"unknown type: {exp_type}", "logs": logs},
                    400,
                )
                return

            files = r.get("files", [])
            log("导出完成", "ok")
            self._json(
                {
                    "ok": True,
                    "type": exp_type,
                    "summary": r.get("summary", ""),
                    "files": files,
                    "logs": logs,
                }
            )
        except Exception as e:
            import traceback

            log(f"导出异常: {e}", "err")
            log(traceback.format_exc().splitlines()[-1], "err")
            self._json({"ok": False, "error": str(e), "logs": logs})

    def _exp_main(
        self, src_p, out_p, http_base, fmt, rename_rule, data, raw_records, log
    ):
        images = scan_images(src_p)
        log(f"扫描到 {len(images)} 张图片")
        tag_file = find_tags_file(src_p)
        records: list[dict[str, Any]] = []
        if tag_file and tag_file.exists():
            raw = load_tags_file(tag_file)
            records, _ = normalize_tags_records(raw, src_p)
        if raw_records:
            records, _ = normalize_tags_records(raw_records, src_p)

        levels = build_main_levels(records, images, src_p, http_base)
        start_order = int(data.get("startOrder", 101))
        version = data.get("version")
        try:
            version = int(version) if version not in (None, "") else 0
        except Exception:
            version = 0
        if version <= 0:
            existing = out_p / "main.json"
            if existing.exists():
                try:
                    version = (
                        int(
                            json.loads(existing.read_text(encoding="utf-8")).get(
                                "version", 0
                            )
                        )
                        + 1
                    )
                except Exception:
                    version = 101
            else:
                version = 101

        import datetime as dt

        payload = {
            "version": version,
            "updatedAt": dt.datetime.now(dt.timezone.utc)
            .isoformat()
            .replace("+00:00", "Z"),
            "levels": [
                {k: v for k, v in lv.items() if not k.startswith("_")} for lv in levels
            ],
        }
        main_dir = out_p / "main"
        main_dir.mkdir(parents=True, exist_ok=True)
        main_json = out_p / "main.json"
        tmp = main_json.with_suffix(".json.tmp")
        tmp.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        tmp.replace(main_json)
        log(f"main.json 已写入 (version={version})")
        files = [str(main_json.resolve())]

        converted = 0
        errors: list[str] = []
        for idx, p in enumerate(
            sorted(images, key=lambda x: x.relative_to(src_p).as_posix().lower())
        ):
            try:
                new_name = make_rename(p.name, start_order + idx, rename_rule, fmt)
                dst = main_dir / new_name
                ok, err = convert_image(p, dst, fmt)
                if ok:
                    converted += 1
                else:
                    errors.append(f"{p.name}: {err}")
            except Exception as e:
                errors.append(f"{p.name}: {e}")
        log(
            f"图片处理: {converted}/{len(images)}"
            + (f", {len(errors)} 失败" if errors else "")
        )
        if errors:
            for e in errors[:5]:
                log(f"  {e}", "warn")

        m_note = self._update_manifest(
            out_p, "main", version, http_base, f"{http_base}/main.json", log
        )
        if m_note:
            files.append(str((out_p / "manifest.json").resolve()))
        return {
            "summary": f"{len(images)} 张 -> main.json (version={version})",
            "files": files,
        }

    def _exp_daily(self, src_p, out_p, http_base, fmt, rename_rule, data, log):
        import re as _re
        import zipfile
        import datetime as dt

        month = (data.get("month") or data.get("YYYYMM") or "").strip()
        if not _re.match(r"^\d{6}$", month):
            raise ValueError(f"month must be YYYYMM, got: {month}")
        images = scan_images(src_p)
        log(f"扫描到 {len(images)} 张图片, 月份 {month}")
        daily_dir = out_p / "daily"
        daily_dir.mkdir(parents=True, exist_ok=True)
        zip_path = daily_dir / f"{month}.zip"
        images_sorted = sorted(images, key=lambda p: p.name.lower())
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for idx, p in enumerate(images_sorted, start=1):
                m = _re.match(r"^(\d{8})\.", p.name)
                if m and rename_rule != "sequence":
                    arc_name = p.name
                    if fmt != "original":
                        arc_name = Path(p.name).stem + f".{fmt}"
                else:
                    arc_name = make_rename(p.name, idx, rename_rule, fmt, month)
                if fmt != "original" and HAS_PIL:
                    import io
                    import tempfile

                    tmpf = Path(tempfile.gettempdir()) / f"_conv_{arc_name}"
                    ok, _ = convert_image(p, tmpf, fmt)
                    if ok:
                        zf.write(tmpf, arcname=arc_name)
                        tmpf.unlink(missing_ok=True)
                        continue
                zf.write(p, arcname=arc_name)
        log(f"ZIP 打包完成: {zip_path.name}")
        files = [str(zip_path.resolve())]

        daily_payload = build_daily_json(out_p, http_base, month, log)
        daily_payload["version"] = int(daily_payload.get("version", 0)) + 1
        daily_json = out_p / "daily.json"
        tmp2 = daily_json.with_suffix(".json.tmp")
        tmp2.write_text(
            json.dumps(daily_payload, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        tmp2.replace(daily_json)
        log(f"daily.json 已写入 (version={daily_payload['version']})")
        files.append(str(daily_json.resolve()))

        self._update_manifest(
            out_p,
            "daily",
            daily_payload["version"],
            http_base,
            f"{http_base}/daily.json",
            log,
        )
        files.append(str((out_p / "manifest.json").resolve()))
        return {
            "summary": f"{len(images_sorted)} 张 -> {month}.zip + daily.json",
            "files": files,
        }

    def _exp_event(
        self, src_p, out_p, http_base, fmt, rename_rule, data, output_mode, log
    ):
        return self._exp_event_or_collection(
            src_p,
            out_p,
            http_base,
            fmt,
            rename_rule,
            data,
            output_mode,
            log,
            kind="event",
        )

    def _exp_collection(
        self, src_p, out_p, http_base, fmt, rename_rule, data, output_mode, log
    ):
        return self._exp_event_or_collection(
            src_p,
            out_p,
            http_base,
            fmt,
            rename_rule,
            data,
            output_mode,
            log,
            kind="collection",
        )

    def _exp_event_or_collection(
        self,
        src_p,
        out_p,
        http_base,
        fmt,
        rename_rule,
        data,
        output_mode,
        log,
        kind="event",
    ):
        import zipfile
        import datetime as dt

        if kind == "event":
            item_id = (data.get("eventId") or "").strip()
            json_name = "events.json"
            sub_dir_name = "events"
            module_name = "events"
        else:
            item_id = (data.get("collectionId") or "").strip()
            json_name = "collections.json"
            sub_dir_name = "collections"
            module_name = "collections"
        if not item_id:
            raise ValueError(
                f"missing {'eventId' if kind == 'event' else 'collectionId'}"
            )
        title = data.get("title", item_id)
        desc = data.get("description", "")
        display_order = int(data.get("displayOrder", 1))
        images = scan_images(src_p)
        log(f"扫描到 {len(images)} 张图片, {kind} ID: {item_id}")
        sub_dir = out_p / sub_dir_name
        sub_dir.mkdir(parents=True, exist_ok=True)
        files: list[str] = []
        cover_url = ""
        level_urls: list[str] = []
        zip_url = ""

        if output_mode == "zip":
            zip_path = sub_dir / f"{item_id}.zip"
            images_sorted = sorted(images, key=lambda p: p.name.lower())
            with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
                for idx, p in enumerate(images_sorted, start=1):
                    arc_name = (
                        make_rename(p.name, idx, rename_rule, fmt)
                        if rename_rule != "none"
                        else p.name
                    )
                    if fmt != "original" and HAS_PIL:
                        import tempfile

                        tmpf = Path(tempfile.gettempdir()) / f"_conv_{arc_name}"
                        ok, _ = convert_image(p, tmpf, fmt)
                        if ok:
                            zf.write(tmpf, arcname=arc_name)
                            tmpf.unlink(missing_ok=True)
                            continue
                    zf.write(p, arcname=arc_name)
            zip_url = f"{http_base}/{sub_dir_name}/{item_id}.zip"
            if images_sorted:
                cover_url = f"{http_base}/{sub_dir_name}/{item_id}_cover.webp"
                cover_src = images_sorted[0]
                cover_dst = sub_dir / f"{item_id}_cover.webp"
                convert_image(cover_src, cover_dst, "webp")
            log(f"ZIP 打包完成: {zip_path.name}")
            files.append(str(zip_path.resolve()))
        else:
            item_img_dir = sub_dir / item_id
            item_img_dir.mkdir(parents=True, exist_ok=True)
            images_sorted = sorted(images, key=lambda p: p.name.lower())
            for idx, p in enumerate(images_sorted, start=1):
                new_name = (
                    make_rename(p.name, idx, rename_rule, fmt)
                    if rename_rule != "none"
                    else p.name
                )
                if fmt != "original" and fmt != "":
                    stem = Path(new_name).stem
                    new_name = f"{stem}.{fmt}"
                dst = item_img_dir / new_name
                convert_image(p, dst, fmt)
                level_urls.append(f"{http_base}/{sub_dir_name}/{item_id}/{new_name}")
            if images_sorted:
                cover_url = level_urls[0] if level_urls else ""
            log(f"Array 模式: {len(level_urls)} 张图片复制完成")
            files.append(str(item_img_dir.resolve()))

        out_json = sub_dir / json_name
        existing: list = []
        if out_json.exists():
            try:
                existing = json.loads(out_json.read_text(encoding="utf-8"))
                if not isinstance(existing, list):
                    existing = []
            except Exception:
                existing = []
        item: dict[str, Any] = {
            "id": item_id,
            "title": title,
            "desc": desc,
        }
        if cover_url:
            item["coverUrl"] = cover_url
        if kind == "event":
            item["status"] = data.get("status", "active")
            st = data.get("startTime")
            et = data.get("endTime")
            if st:
                item["startTime"] = st
            if et:
                item["endTime"] = et
        item["displayOrder"] = display_order
        if output_mode == "zip":
            item["type"] = "zip"
            item["zipUrl"] = zip_url
        else:
            item["type"] = "array"
            item["levels"] = level_urls
        found = False
        for i, ex in enumerate(existing):
            if isinstance(ex, dict) and ex.get("id") == item_id:
                existing[i] = item
                found = True
                break
        if not found:
            existing.append(item)
        tmp = out_json.with_suffix(".json.tmp")
        tmp.write_text(
            json.dumps(existing, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        tmp.replace(out_json)
        log(
            f"{json_name} 已写入 ({len(existing)} 条, {'更新' if found else '新增'} {item_id})"
        )
        files.append(str(out_json.resolve()))

        existing_version = 0
        if out_json.exists():
            try:
                existing_version = len(existing)
            except Exception:
                pass
        new_version = existing_version + 1
        self._update_manifest(
            out_p,
            module_name,
            new_version,
            http_base,
            f"{http_base}/{sub_dir_name}/{json_name}",
            log,
        )
        files.append(str((out_p / "manifest.json").resolve()))
        return {
            "summary": f"{len(images)} 张 -> {item_id} ({output_mode})",
            "files": files,
        }

    def _update_manifest(self, out_p, module_name, version, http_base, url, log):
        manifest = out_p / "manifest.json"
        if not manifest.exists():
            return None
        try:
            mj = json.loads(manifest.read_text(encoding="utf-8"))
            if "modules" not in mj:
                mj["modules"] = {}
            if module_name not in mj["modules"]:
                mj["modules"][module_name] = {}
            mj["modules"][module_name]["url"] = url
            mj["modules"][module_name]["version"] = version
            import datetime as dt

            mj["updatedAt"] = (
                dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
            )
            tmp = manifest.with_suffix(".json.tmp")
            tmp.write_text(
                json.dumps(mj, ensure_ascii=False, indent=2), encoding="utf-8"
            )
            tmp.replace(manifest)
            log(f"manifest.json {module_name}.version -> {version}")
            return f"{module_name}.version -> {version}"
        except Exception as e:
            log(f"manifest update failed: {e}", "warn")
            return None

    def _handle_export_main(self, data):
        src = (data.get("srcDir") or data.get("dir") or "").strip()
        out = (data.get("outDir") or data.get("out") or "").strip()
        http_base = (
            (
                data.get("httpBase")
                or data.get("base")
                or "http://192.168.1.118/data/www/game/test"
            )
            .strip()
            .rstrip("/")
        )
        version = data.get("version")
        try:
            version = int(version) if version not in (None, "") else 0
        except Exception:
            version = 0

        if not src or not out:
            self._json({"error": "missing srcDir/outDir"}, 400)
            return
        src_p = Path(src)
        out_p = Path(out)
        if not src_p.exists() or not src_p.is_dir():
            self._json({"error": f"src not found: {src}"}, 404)
            return

        images = scan_images(src_p)
        # load tags
        tag_file = find_tags_file(src_p)
        records: list[dict[str, Any]] = []
        if tag_file and tag_file.exists():
            raw = load_tags_file(tag_file)
            recs, _ = normalize_tags_records(raw, src_p)
            records = recs

        levels = build_main_levels(records, images, src_p, http_base)

        # auto bump version if not provided or 0
        if version <= 0:
            # try read existing main.json version
            existing_main = out_p / "main.json"
            if existing_main.exists():
                try:
                    ej = json.loads(existing_main.read_text(encoding="utf-8"))
                    version = int(ej.get("version", 0)) + 1
                except Exception:
                    version = 101
            else:
                version = 101
            # fallback to max order+1
            if not version:
                version = max((lv["order"] for lv in levels), default=100) + 1

        payload = {
            "version": version,
            "updatedAt": __import__("datetime")
            .datetime.now(__import__("datetime").timezone.utc)
            .isoformat()
            .replace("+00:00", "Z"),
            "levels": [
                {k: v for k, v in lv.items() if not k.startswith("_")} for lv in levels
            ],
        }

        # ensure out dirs
        out_p.mkdir(parents=True, exist_ok=True)
        main_dir = out_p / "main"
        main_dir.mkdir(parents=True, exist_ok=True)

        # write main.json atomically
        main_json = out_p / "main.json"
        tmp = main_json.with_suffix(".json.tmp")
        tmp.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        tmp.replace(main_json)

        # copy images
        copied = 0
        errors: list[str] = []
        for p in images:
            try:
                dst = main_dir / p.name
                # avoid self-copy
                if p.resolve() == dst.resolve():
                    continue
                shutil.copy2(p, dst)
                copied += 1
            except Exception as e:
                errors.append(f"{p.name}: {e}")

        # optionally update manifest.json version if present
        manifest = out_p / "manifest.json"
        manifest_note = None
        if manifest.exists():
            try:
                mj = json.loads(manifest.read_text(encoding="utf-8"))
                if "modules" in mj and "main" in mj["modules"]:
                    mj["modules"]["main"]["version"] = version
                    mj["modules"]["main"]["url"] = f"{http_base}/main.json"
                    mj["updatedAt"] = payload["updatedAt"]
                    tmp2 = manifest.with_suffix(".json.tmp")
                    tmp2.write_text(
                        json.dumps(mj, ensure_ascii=False, indent=2), encoding="utf-8"
                    )
                    tmp2.replace(manifest)
                    manifest_note = f"manifest.json main.version -> {version}"
            except Exception as e:
                manifest_note = f"manifest update failed: {e}"

        self._json(
            {
                "ok": True,
                "mainJson": str(main_json.resolve()),
                "version": version,
                "total": len(levels),
                "copied": copied,
                "errors": errors,
                "manifest": manifest_note,
                "levelsPreview": payload["levels"][:3],
            }
        )

    def _handle_export_events(self, data):
        # Minimal stub for prototype: create events.json with provided events
        out = (data.get("outDir") or "").strip()
        http_base = (
            (data.get("httpBase") or "http://192.168.1.118/data/www/game/test")
            .strip()
            .rstrip("/")
        )
        events = data.get("events") or []
        if not out:
            self._json({"error": "missing outDir"}, 400)
            return
        out_p = Path(out)
        out_p.mkdir(parents=True, exist_ok=True)
        events_dir = out_p / "events"
        events_dir.mkdir(parents=True, exist_ok=True)

        # For each event, if type zip and srcDir provided, zip images
        for ev in events:
            if not isinstance(ev, dict):
                continue
            eid = ev.get("id") or "event"
            typ = ev.get("type", "zip")
            src = ev.get("srcDir")
            if typ == "zip" and src:
                src_p = Path(src)
                if src_p.exists():
                    zip_path = events_dir / f"{eid}.zip"
                    import zipfile

                    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
                        for p in scan_images(src_p):
                            zf.write(p, arcname=p.name)
                    # auto set zipUrl if missing
                    if not ev.get("zipUrl"):
                        ev["zipUrl"] = f"{http_base}/events/{eid}.zip"
                    # coverUrl auto
                    if not ev.get("coverUrl"):
                        # pick first image as cover
                        imgs = scan_images(src_p)
                        if imgs:
                            ev["coverUrl"] = f"{http_base}/events/{imgs[0].name}"

        out_json = events_dir / "events.json"
        tmp = out_json.with_suffix(".json.tmp")
        tmp.write_text(
            json.dumps(events, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        tmp.replace(out_json)

        self._json({"ok": True, "file": str(out_json.resolve()), "count": len(events)})

    def _handle_export_daily(self, data):
        src = (data.get("srcDir") or "").strip()
        out = (data.get("outDir") or "").strip()
        month = (data.get("month") or data.get("YYYYMM") or "").strip()
        if not src or not out or not month:
            self._json({"error": "missing srcDir/outDir/month (YYYYMM)"}, 400)
            return
        src_p = Path(src)
        out_p = Path(out) / "daily"
        out_p.mkdir(parents=True, exist_ok=True)
        if not __import__("re").match(r"^\d{6}$", month):
            self._json({"error": "month must be YYYYMM"}, 400)
            return
        images = scan_images(src_p)
        import zipfile

        zip_path = out_p / f"{month}.zip"
        # Sort and rename to YYYYMMDD.webp sequentially
        images_sorted = sorted(images, key=lambda p: p.name.lower())
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for idx, p in enumerate(images_sorted, start=1):
                # For prototype, map to YYYYMMDD = YYYYMM + DD
                dd = f"{idx:02d}"
                # If image already named YYYYMMDD, keep it
                import re

                m = re.match(r"^(\d{8})\.", p.name)
                if m:
                    arc = p.name
                else:
                    # preserve ext as webp if original not webp? keep original ext per spec but daily uses webp/jpg/png both ok
                    ext = p.suffix.lower()
                    if ext not in (".webp", ".jpg", ".jpeg", ".png"):
                        ext = ".webp"
                    arc = f"{month}{dd}{ext}"
                zf.write(p, arcname=arc)

        self._json(
            {"ok": True, "zip": str(zip_path.resolve()), "count": len(images_sorted)}
        )


def main():
    ap = argparse.ArgumentParser(description="Content Packaging Studio")
    ap.add_argument("--port", type=int, default=5173, help="port (default 5173)")
    ap.add_argument(
        "--host",
        default="127.0.0.1",
        help="bind host (default 127.0.0.1, use 0.0.0.0 to expose)",
    )
    ap.add_argument("--open", action="store_true", help="auto open browser")
    ap.add_argument(
        "--dir",
        type=Path,
        default=Path(__file__).parent,
        help="serve dir (default scripts/packaging)",
    )
    args = ap.parse_args()

    Handler.serve_dir = args.dir.resolve()
    if not (Handler.serve_dir / "index.html").exists():
        print(f"index.html not found in {Handler.serve_dir}", file=sys.stderr)
        sys.exit(1)

    addr = (args.host, args.port)
    httpd = HTTPServer(addr, Handler)
    url = f"http://{args.host}:{args.port}/"
    print(f"Content Studio serving {Handler.serve_dir}")
    print(f" -> {url}")
    print(f" PIL available: {HAS_PIL} (pip install Pillow for thumbnails)")
    print(" Press Ctrl+C to stop")
    if args.open:
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")
        httpd.server_close()


if __name__ == "__main__":
    main()
