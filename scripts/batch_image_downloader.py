#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
🧩 拼图素材批量下载器 - 免费分类图库自动化管线
支持 Pixabay / Pexels / Unsplash / Openverse 四大源，按动物/植物/建筑/风光等分类自动建目录。

用法:
  pip install requests pillow tqdm
  # 设置 Key（任选其一，推荐 Pixabay 起步零门槛）
  $env:PIXABAY_API_KEY="xxx"        # https://pixabay.com/api/docs/
  $env:PEXELS_API_KEY="xxx"         # https://www.pexels.com/api/
  $env:UNSPLASH_ACCESS_KEY="xxx"    # https://unsplash.com/developers

  python scripts/batch_image_downloader.py --source pixabay --per-category 50
  python scripts/batch_image_downloader.py --source pexels --categories animals landscape --per-category 30 --dry-run
  python scripts/batch_image_downloader.py --source unsplash --per-category 20 --min-width 1920

特性:
  - 分类 -> 关键词映射，自动创建 assets/images/levels/{category}/
  - 分辨率/方向过滤，去重，并发下载，重试，限流
  - 生成 download_manifest.json 记录 sourceUrl/license/author，便于合规溯源与后续质检
  - dry-run 仅预览命中数，不落盘
"""

import argparse
import hashlib
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from urllib.parse import urlparse

if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

try:
    import requests
except ImportError:
    print("缺少依赖 requests，请先 pip install requests pillow tqdm")
    sys.exit(1)

try:
    from tqdm import tqdm
    TQDM_AVAILABLE = True
except ImportError:
    TQDM_AVAILABLE = False
    tqdm = lambda x, **k: x  # type: ignore

# ==============================================================================
# 分类 -> 搜索关键词映射（与 docs/image-source-and-batch-download-guide.md 保持一致）
# ==============================================================================

CATEGORY_KEYWORDS: Dict[str, List[str]] = {
    "animals":      ["animals", "cute animals", "wildlife", "pets"],
    "plants":       ["plants", "flowers", "forest", "garden"],
    "architecture": ["architecture", "cityscape", "building", "castle"],
    "landscape":    ["landscape", "mountains", "sea", "sunset nature"],
    "anime":        ["anime illustration", "illustration", "fantasy art"],
}

# Pixabay 官方 category 枚举，用于 q 为空时精确分类
PIXABAY_CATEGORY_MAP = {
    "animals": "animals",
    "plants": "nature",
    "architecture": "buildings",
    "landscape": "nature",
    "anime": "illustration",
}

DEFAULT_CATEGORIES = ["animals", "plants", "architecture", "landscape"]

# ==============================================================================
# 数据模型
# ==============================================================================

@dataclass
class ImageRecord:
    id: str
    category: str
    query: str
    source: str
    page: int
    image_url: str
    preview_url: str
    source_url: str  # 原站页面，便于溯源
    author: str
    license: str
    width: int
    height: int
    tags: str

# ==============================================================================
# 工具函数
# ==============================================================================

def get_env_key(name: str) -> Optional[str]:
    return os.environ.get(name) or os.environ.get(name.upper())

def ensure_dir(p: Path):
    p.mkdir(parents=True, exist_ok=True)

def safe_filename(url: str, fallback_id: str) -> str:
    parsed = urlparse(url)
    name = Path(parsed.path).name
    if not name or "." not in name:
        ext = ".jpg"
        # 尝试从 url 猜扩展
        if ".png" in url.lower():
            ext = ".png"
        elif ".webp" in url.lower():
            ext = ".webp"
        name = f"{fallback_id}{ext}"
    # 清理非法字符
    name = "".join(c if c.isalnum() or c in "._-" else "_" for c in name)
    return name

def download_one(url: str, dest: Path, retries: int = 3, timeout: int = 30) -> bool:
    for attempt in range(retries):
        try:
            r = requests.get(url, timeout=timeout, stream=True)
            if r.status_code == 200:
                dest.parent.mkdir(parents=True, exist_ok=True)
                with open(dest, "wb") as f:
                    for chunk in r.iter_content(chunk_size=8192):
                        if chunk:
                            f.write(chunk)
                # 简单校验非空
                if dest.stat().st_size < 1024:
                    dest.unlink(missing_ok=True)
                    raise ValueError("file too small")
                return True
            elif r.status_code in (429, 503):
                wait = 2 ** attempt * 2
                print(f"  [限流] {r.status_code} 等待 {wait}s 重试...")
                time.sleep(wait)
            else:
                print(f"  [失败] {url} -> HTTP {r.status_code}")
                return False
        except Exception as e:
            if attempt == retries - 1:
                print(f"  [失败] {url} -> {e}")
                return False
            time.sleep(1.5 * (attempt + 1))
    return False

# ==============================================================================
# 各图库 API 封装
# ==============================================================================

def fetch_pixabay(category: str, keywords: List[str], per_category: int, api_key: str,
                  min_width: int, orientation: str, image_type: str = "photo",
                  safesearch: bool = True, editors_choice: bool = False) -> List[ImageRecord]:
    records: List[ImageRecord] = []
    per_page = min(50, per_category)  # Pixabay 每页最大 200，用 50 平衡
    pages = (per_category + per_page - 1) // per_page
    base_url = "https://pixabay.com/api/"

    # 轮询关键词以增加多样性
    for page in range(1, pages + 1):
        if len(records) >= per_category:
            break
        # 轮换关键词
        q = keywords[(page - 1) % len(keywords)] if keywords else ""
        params = {
            "key": api_key,
            "q": q,
            "image_type": image_type,
            "orientation": orientation if orientation != "all" else "all",
            "min_width": min_width,
            "per_page": per_page,
            "page": page,
            "safesearch": str(safesearch).lower(),
            "order": "popular",
        }
        # 可选分类过滤（当 q 较泛时更准）
        if category in PIXABAY_CATEGORY_MAP and not q:
            params["category"] = PIXABAY_CATEGORY_MAP[category]
        if editors_choice:
            params["editors_choice"] = "true"

        try:
            r = requests.get(base_url, params=params, timeout=20)
            if r.status_code == 429:
                print("  [Pixabay] 限流，等待 5s...")
                time.sleep(5)
                r = requests.get(base_url, params=params, timeout=20)
            r.raise_for_status()
            data = r.json()
            hits = data.get("hits", [])
            if not hits:
                print(f"  [Pixabay] {category} page {page} 无结果 (q={q})")
                break
            for hit in hits:
                if len(records) >= per_category:
                    break
                # 优先 largeImageURL（1280），其次 imageURL 原图
                img_url = hit.get("largeImageURL") or hit.get("imageURL") or hit.get("webformatURL")
                if not img_url:
                    continue
                rec = ImageRecord(
                    id=str(hit.get("id", hashlib.md5(img_url.encode()).hexdigest()[:8])),
                    category=category,
                    query=q,
                    source="pixabay",
                    page=page,
                    image_url=img_url,
                    preview_url=hit.get("previewURL", "") or hit.get("webformatURL", ""),
                    source_url=hit.get("pageURL", f"https://pixabay.com/photos/{hit.get('id')}"),
                    author=hit.get("user", "pixabay"),
                    license="Pixabay Content License (free commercial, no attribution required)",
                    width=hit.get("imageWidth", 0),
                    height=hit.get("imageHeight", 0),
                    tags=hit.get("tags", ""),
                )
                # 本地过滤分辨率
                if rec.width and rec.width < min_width:
                    continue
                records.append(rec)
            time.sleep(0.6)  # 限流保护
        except Exception as e:
            print(f"  [Pixabay] 请求失败 page={page} q={q}: {e}")
            time.sleep(1)
            break
    return records[:per_category]


def fetch_pexels(category: str, keywords: List[str], per_category: int, api_key: str,
                 min_width: int, orientation: str) -> List[ImageRecord]:
    records: List[ImageRecord] = []
    per_page = min(80, per_category)  # Pexels 最大 80
    pages = (per_category + per_page - 1) // per_page
    base_url = "https://api.pexels.com/v1/search"
    headers = {"Authorization": api_key}

    for page in range(1, pages + 1):
        if len(records) >= per_category:
            break
        q = keywords[(page - 1) % len(keywords)] if keywords else category
        params = {
            "query": q,
            "per_page": per_page,
            "page": page,
            "orientation": orientation if orientation in ("landscape", "portrait", "square") else None,
        }
        # 清理 None
        params = {k: v for k, v in params.items() if v is not None}
        try:
            r = requests.get(base_url, headers=headers, params=params, timeout=20)
            if r.status_code == 429:
                print("  [Pexels] 限流 429，等待 5s...")
                time.sleep(5)
                r = requests.get(base_url, headers=headers, params=params, timeout=20)
            r.raise_for_status()
            data = r.json()
            photos = data.get("photos", [])
            if not photos:
                print(f"  [Pexels] {category} page {page} 无结果 (q={q})")
                break
            for p in photos:
                if len(records) >= per_category:
                    break
                src = p.get("src", {})
                # 优先 large2x / original
                img_url = src.get("large2x") or src.get("large") or src.get("original") or src.get("medium")
                if not img_url:
                    continue
                w, h = p.get("width", 0), p.get("height", 0)
                if w and w < min_width:
                    continue
                rec = ImageRecord(
                    id=str(p.get("id", hashlib.md5(img_url.encode()).hexdigest()[:8])),
                    category=category,
                    query=q,
                    source="pexels",
                    page=page,
                    image_url=img_url,
                    preview_url=src.get("medium", "") or src.get("small", ""),
                    source_url=p.get("url", f"https://www.pexels.com/photo/{p.get('id')}"),
                    author=p.get("photographer", "pexels"),
                    license="Pexels License (free commercial, no attribution required)",
                    width=w,
                    height=h,
                    tags=q,
                )
                records.append(rec)
            time.sleep(0.8)
        except Exception as e:
            print(f"  [Pexels] 请求失败 page={page} q={q}: {e}")
            time.sleep(1)
            break
    return records[:per_category]


def fetch_unsplash(category: str, keywords: List[str], per_category: int, access_key: str,
                   min_width: int, orientation: str) -> List[ImageRecord]:
    records: List[ImageRecord] = []
    per_page = min(30, per_category)  # Unsplash search 每页最大 30
    pages = (per_category + per_page - 1) // per_page
    base_url = "https://api.unsplash.com/search/photos"
    headers = {"Authorization": f"Client-ID {access_key}"}

    for page in range(1, pages + 1):
        if len(records) >= per_category:
            break
        q = keywords[(page - 1) % len(keywords)] if keywords else category
        params = {
            "query": q,
            "per_page": per_page,
            "page": page,
            "orientation": orientation if orientation in ("landscape", "portrait", "squarish") else None,
            "content_filter": "high",
        }
        params = {k: v for k, v in params.items() if v is not None}
        try:
            r = requests.get(base_url, headers=headers, params=params, timeout=20)
            if r.status_code == 429:
                print("  [Unsplash] 限流 429（免费 50次/小时），等待 10s...")
                time.sleep(10)
                r = requests.get(base_url, headers=headers, params=params, timeout=20)
            # 401/403 提示 Key 问题
            if r.status_code in (401, 403):
                print(f"  [Unsplash] 认证失败 {r.status_code}，请检查 UNSPLASH_ACCESS_KEY")
                break
            r.raise_for_status()
            data = r.json()
            results = data.get("results", [])
            if not results:
                print(f"  [Unsplash] {category} page {page} 无结果 (q={q})")
                break
            for item in results:
                if len(records) >= per_category:
                    break
                urls = item.get("urls", {})
                img_url = urls.get("full") or urls.get("regular") or urls.get("raw")
                if not img_url:
                    continue
                # Unsplash 可通过 w 参数控制宽度，追加 min_width
                if "?" in img_url:
                    img_url += f"&w={max(min_width, 1920)}"
                else:
                    img_url += f"?w={max(min_width, 1920)}"
                w, h = item.get("width", 0), item.get("height", 0)
                rec = ImageRecord(
                    id=item.get("id", hashlib.md5(img_url.encode()).hexdigest()[:8]),
                    category=category,
                    query=q,
                    source="unsplash",
                    page=page,
                    image_url=img_url,
                    preview_url=urls.get("small", "") or urls.get("thumb", ""),
                    source_url=item.get("links", {}).get("html", f"https://unsplash.com/photos/{item.get('id')}"),
                    author=item.get("user", {}).get("name", "unsplash"),
                    license="Unsplash License (free commercial, no attribution required)",
                    width=w,
                    height=h,
                    tags=",".join([t.get("title", "") for t in item.get("tags", [])[:5]]),
                )
                records.append(rec)
            time.sleep(1.0)  # Unsplash 限流较严
        except Exception as e:
            print(f"  [Unsplash] 请求失败 page={page} q={q}: {e}")
            time.sleep(1)
            break
    return records[:per_category]


def fetch_openverse(category: str, keywords: List[str], per_category: int,
                    min_width: int) -> List[ImageRecord]:
    records: List[ImageRecord] = []
    per_page = min(50, per_category)
    pages = (per_category + per_page - 1) // per_page
    base_url = "https://api.openverse.engineering/v1/images/"

    for page in range(1, pages + 1):
        if len(records) >= per_category:
            break
        q = keywords[(page - 1) % len(keywords)] if keywords else category
        params = {
            "q": q,
            "page_size": per_page,
            "page": page,
            "license": "cc0,pdm,by",  # 仅拉可商用
            "license_type": "commercial",
            "mature": "false",
        }
        try:
            r = requests.get(base_url, params=params, timeout=20)
            if r.status_code == 429:
                time.sleep(5)
                r = requests.get(base_url, params=params, timeout=20)
            r.raise_for_status()
            data = r.json()
            results = data.get("results", [])
            if not results:
                print(f"  [Openverse] {category} page {page} 无结果 (q={q})")
                break
            for item in results:
                if len(records) >= per_category:
                    break
                img_url = item.get("url")
                if not img_url:
                    continue
                raw_tags = item.get("tags", [])
                tag_str = ""
                if isinstance(raw_tags, list):
                    parts = []
                    for t in raw_tags[:5]:
                        if isinstance(t, dict):
                            parts.append(t.get("name", "") or t.get("title", ""))
                        elif isinstance(t, str):
                            parts.append(t)
                    tag_str = ",".join([p for p in parts if p])
                else:
                    tag_str = str(raw_tags)
                rec = ImageRecord(
                    id=item.get("id", hashlib.md5(img_url.encode()).hexdigest()[:8]),
                    category=category,
                    query=q,
                    source="openverse",
                    page=page,
                    image_url=img_url,
                    preview_url=item.get("thumbnail", ""),
                    source_url=item.get("foreign_landing_url", img_url),
                    author=item.get("creator", "openverse"),
                    license=item.get("license", "cc0"),
                    width=item.get("width", 0) or 0,
                    height=item.get("height", 0) or 0,
                    tags=tag_str,
                )
                records.append(rec)
            time.sleep(0.6)
        except Exception as e:
            print(f"  [Openverse] 请求失败 page={page} q={q}: {e}")
            time.sleep(1)
            break
    return records[:per_category]

# ==============================================================================
# 主流程
# ==============================================================================

def collect_records(source: str, categories: List[str], per_category: int,
                    min_width: int, orientation: str) -> List[ImageRecord]:
    all_records: List[ImageRecord] = []

    # 读取 Key
    pixabay_key = get_env_key("PIXABAY_API_KEY")
    pexels_key = get_env_key("PEXELS_API_KEY")
    unsplash_key = get_env_key("UNSPLASH_ACCESS_KEY") or get_env_key("UNSPLASH_API_KEY")

    if source == "pixabay" and not pixabay_key:
        print("[错误] 未设置 PIXABAY_API_KEY，请先 $env:PIXABAY_API_KEY='xxx' 或 --api-key 传入")
        sys.exit(1)
    if source == "pexels" and not pexels_key:
        print("[错误] 未设置 PEXELS_API_KEY")
        sys.exit(1)
    if source == "unsplash" and not unsplash_key:
        print("[错误] 未设置 UNSPLASH_ACCESS_KEY")
        sys.exit(1)

    for cat in categories:
        keywords = CATEGORY_KEYWORDS.get(cat, [cat])
        print(f"\n▶ 分类 [{cat}] 关键词 {keywords} -> 目标 {per_category} 张 (source={source})")
        if source == "pixabay":
            recs = fetch_pixabay(cat, keywords, per_category, pixabay_key, min_width, orientation)
        elif source == "pexels":
            # Pexels orientation 映射
            pex_ori = "landscape" if orientation == "horizontal" else orientation
            recs = fetch_pexels(cat, keywords, per_category, pexels_key, min_width, pex_ori)
        elif source == "unsplash":
            us_ori = "landscape" if orientation == "horizontal" else orientation
            recs = fetch_unsplash(cat, keywords, per_category, unsplash_key, min_width, us_ori)
        elif source == "openverse":
            recs = fetch_openverse(cat, keywords, per_category, min_width)
        else:
            raise ValueError(f"未知 source: {source}")

        print(f"  ↳ 命中 {len(recs)} 张")
        all_records.extend(recs)

    # 去重（按 image_url 去重）
    seen = set()
    deduped: List[ImageRecord] = []
    for r in all_records:
        if r.image_url not in seen:
            seen.add(r.image_url)
            deduped.append(r)
    if len(deduped) != len(all_records):
        print(f"\n[去重] {len(all_records)} -> {len(deduped)} 张")
    return deduped


def main():
    parser = argparse.ArgumentParser(
        description="拼图素材批量下载器 (Pixabay/Pexels/Unsplash/Openverse)",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--source", choices=["pixabay", "pexels", "unsplash", "openverse"],
                        default="pixabay", help="图库来源")
    parser.add_argument("--categories", nargs="+", default=DEFAULT_CATEGORIES,
                        choices=list(CATEGORY_KEYWORDS.keys()),
                        help="要下载的分类")
    parser.add_argument("--per-category", type=int, default=30, help="每分类下载张数")
    parser.add_argument("--out-dir", type=str, default="assets/images/levels",
                        help="输出根目录（下按分类建子目录）")
    parser.add_argument("--min-width", type=int, default=1920, help="最小宽度过滤")
    parser.add_argument("--orientation", type=str, default="horizontal",
                        choices=["horizontal", "vertical", "all", "landscape", "portrait", "square", "squarish"],
                        help="方向过滤（pixabay 用 horizontal/vertical/all）")
    parser.add_argument("--api-key", type=str, default=None, help="API Key（也可走环境变量）")
    parser.add_argument("--dry-run", action="store_true", help="仅预览命中数，不下载")
    parser.add_argument("--workers", type=int, default=6, help="并发下载线程数")
    parser.add_argument("--manifest", type=str, default=None, help="manifest 输出路径（默认 out-dir/download_manifest.json）")

    args = parser.parse_args()

    # 若通过 --api-key 传入，写入环境变量
    if args.api_key:
        env_map = {
            "pixabay": "PIXABAY_API_KEY",
            "pexels": "PEXELS_API_KEY",
            "unsplash": "UNSPLASH_ACCESS_KEY",
            "openverse": None,
        }
        env_name = env_map.get(args.source)
        if env_name:
            os.environ[env_name] = args.api_key

    print(f"=== 拼图素材批量下载器 ===")
    print(f"来源: {args.source} | 分类: {args.categories} | 每类: {args.per_category} | dry-run: {args.dry_run}")
    print(f"输出: {args.out_dir} | 最小宽度: {args.min_width} | 方向: {args.orientation}")

    records = collect_records(args.source, args.categories, args.per_category,
                              args.min_width, args.orientation)

    print(f"\n[汇总] 共命中 {len(records)} 张（去重后）")
    for cat in args.categories:
        cnt = sum(1 for r in records if r.category == cat)
        print(f"  - {cat}: {cnt} 张")

    if args.dry_run:
        print("\n[dry-run] 预览结束，未下载。去掉 --dry-run 即可正式下载。")
        # 打印前 5 条示例
        for r in records[:5]:
            print(f"  示例: [{r.category}] {r.image_url} | {r.source_url} | {r.author}")
        return

    if not records:
        print("[警告] 无命中结果，请尝试更换关键词或降低 min-width")
        return

    out_root = Path(args.out_dir)
    manifest_path = Path(args.manifest) if args.manifest else out_root / "download_manifest.json"

    # 并发下载
    print(f"\n▶ 开始下载到 {out_root} (workers={args.workers})")
    success = 0
    failed = 0
    manifest_entries = []

    def _download_task(rec: ImageRecord) -> Tuple[ImageRecord, bool, str]:
        subdir = out_root / rec.category
        ensure_dir(subdir)
        fname = safe_filename(rec.image_url, rec.id)
        # 避免重名：前缀 category + id
        fname = f"{rec.category}_{rec.id}_{fname}"
        dest = subdir / fname
        # 已存在则跳过（断点续传）
        if dest.exists() and dest.stat().st_size > 1024:
            return rec, True, str(dest)
        ok = download_one(rec.image_url, dest)
        return rec, ok, str(dest)

    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        futures = {executor.submit(_download_task, r): r for r in records}
        iterator = as_completed(futures)
        if TQDM_AVAILABLE:
            iterator = tqdm(iterator, total=len(futures), desc="下载进度")

        for fut in iterator:
            rec, ok, dest_path = fut.result()
            entry = {
                **asdict(rec),
                "local_path": dest_path,
                "download_success": ok,
                "downloaded_at": time.strftime("%Y-%m-%dT%H:%M:%S+08:00"),
            }
            manifest_entries.append(entry)
            if ok:
                success += 1
            else:
                failed += 1

    print(f"\n[完成] 成功 {success} 张，失败 {failed} 张")

    # 写入 manifest
    ensure_dir(manifest_path.parent)
    # 读取旧 manifest 合并（追加模式，保留历史）
    existing = []
    if manifest_path.exists():
        try:
            with open(manifest_path, "r", encoding="utf-8") as f:
                old = json.load(f)
                if isinstance(old, list):
                    existing = old
                elif isinstance(old, dict) and "images" in old:
                    existing = old["images"]
        except Exception:
            pass

    # 合并去重（按 image_url）
    merged_map = {e.get("image_url"): e for e in existing}
    for e in manifest_entries:
        merged_map[e["image_url"]] = e
    merged = list(merged_map.values())

    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump({
            "source": args.source,
            "categories": args.categories,
            "per_category": args.per_category,
            "total_downloaded": len(merged),
            "last_batch_success": success,
            "last_batch_failed": failed,
            "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S+08:00"),
            "images": merged,
        }, f, ensure_ascii=False, indent=2)

    print(f"[清单] 已写入 {manifest_path}（共 {len(merged)} 条，含历史）")
    print(f"\n下一步建议:")
    print(f"  python scripts/puzzle_quality_analyzer.py --source {out_root} --html temp/batch_report.html --json temp/batch_report.json")
    print(f"  # 然后在 temp/batch_report.html 中筛选 S/A 级，再用 export_selected_puzzles.py 归档")


if __name__ == "__main__":
    main()
