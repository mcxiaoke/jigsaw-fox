#!/usr/bin/env python3
"""
在测试服务器 X:\\www\\game\\test2 下构建符合架构规范 v2.3.0 的新格式拼图内容测试数据。

包含：
1. manifest.json (Root Manifest, schemaVersion: 4, 相对路径引用)
2. main/
   - index.json (batches 数组, Append-Only)
   - batches/batch_001.json (关卡 101~110, 显式 id, hash, url: "../images/0101.webp")
   - batches/batch_002.json (关卡 111~120, 显式 id, hash, url: "../images/0111.webp")
   - batches/batch_003.json (补丁批次 patch: true, levelsAffected: [105], 指向 ../images/0105-r2.webp 并替换 hash)
   - images/0101.webp ~ 0120.webp + 0105-r2.webp
3. daily/
   - index.json (months 数组, 包含 202609, 202608, 202607)
   - zips/202609.zip (内部 20260901.webp ~ 20260930.webp)
   - zips/202608.zip (内部 20260801.webp ~ 20260831.webp)
   - zips/202607.zip (内部 20260701.webp ~ 20260731.webp)
4. events/
   - index.json (活动列表)
   - covers/ & zips/
5. collections/
   - index.json (合集列表)
   - covers/ & zips/
6. packs/ 扩展图包
"""

import os
import io
import shutil
import json
import hashlib
import zipfile
from pathlib import Path
from PIL import Image

BASE_DIR = Path("X:/www/game/test2")
SRC_ANIMALS = Path("temp/animals-cropped")
SRC_TESTIMAGES = Path("temp/testimages")


def compute_sha256(file_path: Path) -> str:
    """计算文件的 SHA-256 哈希十六进制字符串"""
    hasher = hashlib.sha256()
    with open(file_path, "rb") as f:
        while chunk := f.read(65536):
            hasher.update(chunk)
    return hasher.hexdigest()


def convert_to_webp(src_path: Path, dst_path: Path, quality: int = 85):
    """将源图片转换为 WebP 格式并保存"""
    dst_path.parent.mkdir(parents=True, exist_ok=True)
    with Image.open(src_path) as img:
        if img.mode not in ("RGB", "RGBA"):
            img = img.convert("RGB")
        img.save(dst_path, format="WEBP", quality=quality)


def main():
    print(f"==================================================")
    print(f"Deploying Universal v2.3.0 Test Server at: {BASE_DIR}")
    print(f"==================================================")
    BASE_DIR.mkdir(parents=True, exist_ok=True)

    # 收集源图片
    src_images = []
    if SRC_ANIMALS.exists():
        src_images.extend(sorted(list(SRC_ANIMALS.glob("*.jpg")) + list(SRC_ANIMALS.glob("*.png"))))
    if SRC_TESTIMAGES.exists():
        src_images.extend(sorted(list(SRC_TESTIMAGES.glob("*.jpg")) + list(SRC_TESTIMAGES.glob("*.png"))))

    if not src_images:
        print("Error: No source images found in temp/animals-cropped or temp/testimages!")
        return

    print(f"Loaded {len(src_images)} source images.")

    # ----------------------------------------------------
    # 1. 部署主线关卡 main/
    # ----------------------------------------------------
    print("\n[1/5] Building main module (Batches + Clean WebP + Patch)...")
    main_dir = BASE_DIR / "main"
    main_images_dir = main_dir / "images"
    main_batches_dir = main_dir / "batches"
    main_images_dir.mkdir(parents=True, exist_ok=True)
    main_batches_dir.mkdir(parents=True, exist_ok=True)

    # 对齐 data/taxonomy.json SSOT 核心规范主标签 (17 Main Tags: Landscapes, Nature, Flowers, Animals, Pets, Cities, Structures, Vehicles, People, Objects, Food, Art, Fantasy, Holidays, Colors, Composition, Others)
    predefined_tags = [
        ["Animals", "Landscapes"],
        ["Animals", "Nature"],
        ["Animals"],
        ["Animals"],
        ["Nature", "Animals"],
        ["Landscapes", "Nature"],
        ["Structures"],
        ["Art"],
        ["Pets", "Animals"],
        ["Animals", "Nature"],
        ["Landscapes", "Nature"],
        ["Cities", "Structures"],
        ["Art", "Colors"],
        ["Pets", "Animals"],
        ["Nature", "Landscapes"],
        ["Animals"],
        ["Landscapes"],
        ["Structures"],
        ["Flowers", "Art"],
        ["Pets", "Animals"],
    ]

    # 生成 0101.webp ~ 0120.webp
    main_levels_meta = {}
    for i in range(20):
        order = 101 + i
        fname = f"{order:04d}.webp"
        dst_path = main_images_dir / fname
        src_img = src_images[i % len(src_images)]
        convert_to_webp(src_img, dst_path, quality=85)
        fhash = compute_sha256(dst_path)
        main_levels_meta[order] = {
            "id": f"main:{order}",
            "order": order,
            "url": f"../images/{fname}",
            "hash": fhash,
            "tags": predefined_tags[i % len(predefined_tags)],
            "addedAt": "2026-09-01T00:00:00Z",
        }

    # 生成补丁新图 0105-r2.webp
    patch_order = 105
    patch_fname = f"{patch_order:04d}-r2.webp"
    patch_dst_path = main_images_dir / patch_fname
    patch_src_img = src_images[(patch_order + 7) % len(src_images)]
    convert_to_webp(patch_src_img, patch_dst_path, quality=90)
    patch_hash = compute_sha256(patch_dst_path)

    # 分卷 1: 101 ~ 110 (10 关)
    batch_001_levels = [main_levels_meta[o] for o in range(101, 111)]
    batch_001_data = {
        "batchId": "batch_001",
        "version": 101,
        "count": len(batch_001_levels),
        "startOrder": 101,
        "endOrder": 110,
        "items": batch_001_levels,
    }
    with open(main_batches_dir / "batch_001.json", "w", encoding="utf-8") as f:
        json.dump(batch_001_data, f, ensure_ascii=False, indent=2)

    # 分卷 2: 111 ~ 120 (10 关)
    batch_002_levels = [main_levels_meta[o] for o in range(111, 121)]
    batch_002_data = {
        "batchId": "batch_002",
        "version": 102,
        "count": len(batch_002_levels),
        "startOrder": 111,
        "endOrder": 120,
        "items": batch_002_levels,
    }
    with open(main_batches_dir / "batch_002.json", "w", encoding="utf-8") as f:
        json.dump(batch_002_data, f, ensure_ascii=False, indent=2)

    # 分卷 3 (补丁分卷): 修订 105 关
    batch_003_data = {
        "batchId": "batch_003",
        "patch": True,
        "version": 103,
        "levelsAffected": [105],
        "items": [
            {
                "id": f"main:{patch_order}",
                "order": patch_order,
                "url": f"../images/{patch_fname}",
                "hash": patch_hash,
                "tags": main_levels_meta[patch_order]["tags"] + ["retouched"],
                "addedAt": "2026-09-05T22:00:00Z",
            }
        ],
    }
    with open(main_batches_dir / "batch_003.json", "w", encoding="utf-8") as f:
        json.dump(batch_003_data, f, ensure_ascii=False, indent=2)

    # main/index.json
    main_index_data = {
        "module": "main",
        "version": 103,
        "totalCount": 20,
        "maxOrder": 120,
        "updatedAt": "2026-09-05T22:00:00Z",
        "items": [
            {
                "batchId": "batch_001",
                "version": 101,
                "count": 10,
                "startOrder": 101,
                "endOrder": 110,
                "url": "batches/batch_001.json",
            },
            {
                "batchId": "batch_002",
                "version": 102,
                "count": 10,
                "startOrder": 111,
                "endOrder": 120,
                "url": "batches/batch_002.json",
            },
            {
                "batchId": "batch_003",
                "patch": True,
                "version": 103,
                "levelsAffected": [105],
                "url": "batches/batch_003.json",
            },
        ],
    }
    main_index_file = main_dir / "index.json"
    with open(main_index_file, "w", encoding="utf-8") as f:
        json.dump(main_index_data, f, ensure_ascii=False, indent=2)
    main_index_hash = compute_sha256(main_index_file)
    print(f"  [OK] main/index.json (3 batches, 20 levels, patch on #105) deployed.")

    # ----------------------------------------------------
    # 2. 部署每日挑战 daily/
    # ----------------------------------------------------
    print("\n[2/5] Building daily module (Pure YYYYMMDD.webp inside ZIPs)...")
    daily_dir = BASE_DIR / "daily"
    daily_zips_dir = daily_dir / "zips"
    daily_zips_dir.mkdir(parents=True, exist_ok=True)

    def create_daily_zip(yyyy_mm: str, days: int, offset: int) -> tuple[Path, int, str]:
        zip_path = daily_zips_dir / f"{yyyy_mm}.zip"
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for day in range(1, days + 1):
                date_str = f"{yyyy_mm}{day:02d}"
                src_img = src_images[(day + offset) % len(src_images)]
                buf = io.BytesIO()
                with Image.open(src_img) as img:
                    if img.mode not in ("RGB", "RGBA"):
                        img = img.convert("RGB")
                    img.save(buf, format="WEBP", quality=85)
                zf.writestr(f"{date_str}.webp", buf.getvalue())
        return zip_path, zip_path.stat().st_size, compute_sha256(zip_path)

    z09_path, z09_size, z09_hash = create_daily_zip("202609", 30, 0)
    z08_path, z08_size, z08_hash = create_daily_zip("202608", 31, 5)
    z07_path, z07_size, z07_hash = create_daily_zip("202607", 31, 15)

    daily_index_data = {
        "module": "daily",
        "version": 12,
        "currentMonth": "202609",
        "updatedAt": "2026-09-05T21:45:00Z",
        "items": [
            {
                "month": "202609",
                "count": 30,
                "zipUrl": "zips/202609.zip",
                "zipSize": z09_size,
                "hash": z09_hash,
                "updatedAt": "2026-09-01T00:00:00Z",
            },
            {
                "month": "202608",
                "count": 31,
                "zipUrl": "zips/202608.zip",
                "zipSize": z08_size,
                "hash": z08_hash,
                "updatedAt": "2026-08-01T00:00:00Z",
            },
            {
                "month": "202607",
                "count": 31,
                "zipUrl": "zips/202607.zip",
                "zipSize": z07_size,
                "hash": z07_hash,
                "updatedAt": "2026-07-01T00:00:00Z",
            },
        ],
    }
    daily_index_file = daily_dir / "index.json"
    with open(daily_index_file, "w", encoding="utf-8") as f:
        json.dump(daily_index_data, f, ensure_ascii=False, indent=2)
    daily_index_hash = compute_sha256(daily_index_file)
    print(f"  [OK] daily/index.json (3 months) deployed.")

    # ----------------------------------------------------
    # 3. 部署活动中心 events/
    # ----------------------------------------------------
    print("\n[3/5] Building events module...")
    events_dir = BASE_DIR / "events"
    events_zips_dir = events_dir / "zips"
    events_covers_dir = events_dir / "covers"
    events_zips_dir.mkdir(parents=True, exist_ok=True)
    events_covers_dir.mkdir(parents=True, exist_ok=True)

    def create_event_zip(zip_name: str, count: int, offset: int) -> tuple[Path, str]:
        zpath = events_zips_dir / zip_name
        with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as zf:
            for i in range(1, count + 1):
                src_img = src_images[(i + offset) % len(src_images)]
                buf = io.BytesIO()
                with Image.open(src_img) as img:
                    if img.mode not in ("RGB", "RGBA"):
                        img = img.convert("RGB")
                    img.save(buf, format="WEBP", quality=85)
                zf.writestr(f"{i:02d}.webp", buf.getvalue())
        return zpath, compute_sha256(zpath)

    convert_to_webp(src_images[10 % len(src_images)], events_covers_dir / "cover_cyberpunk.webp")
    convert_to_webp(src_images[20 % len(src_images)], events_covers_dir / "cover_nature.webp")
    convert_to_webp(src_images[30 % len(src_images)], events_covers_dir / "cover_art.webp")
    convert_to_webp(src_images[40 % len(src_images)], events_covers_dir / "cover_animals.webp")
    convert_to_webp(src_images[50 % len(src_images)], events_covers_dir / "cover_arch.webp")

    z_cyber, hash_cyber = create_event_zip("cyberpunk_2026.zip", 6, 10)
    z_nature, hash_nature = create_event_zip("nature_wonders.zip", 8, 20)
    z_art, hash_art = create_event_zip("oil_art.zip", 6, 30)

    events_index_data = {
        "module": "events",
        "version": 5,
        "updatedAt": "2026-09-05T21:45:00Z",
        "items": [
            {
                "id": "cyberpunk_2026",
                "title": "未来赛博都市 · 霓虹幻夜",
                "desc": "挑战 6 张限定赛博朋克风拼图。",
                "coverUrl": "covers/cover_cyberpunk.webp",
                "status": "active",
                "type": "zip",
                "zipUrl": "zips/cyberpunk_2026.zip",
                "zipSha256": hash_cyber,
                "startTime": "2026-08-01T00:00:00Z",
                "endTime": "2026-09-10T00:00:00Z",
                "displayOrder": 1,
            },
            {
                "id": "nature_wonders",
                "title": "自然秘境 · 国家地理特辑",
                "desc": "包含 8 幅高清自然风光作品。",
                "coverUrl": "covers/cover_nature.webp",
                "status": "active",
                "type": "zip",
                "zipUrl": "zips/nature_wonders.zip",
                "zipSha256": hash_nature,
                "startTime": "2026-08-10T00:00:00Z",
                "endTime": "2026-09-20T00:00:00Z",
                "displayOrder": 2,
            },
            {
                "id": "cute_animals_party",
                "title": "世界萌宠狂欢派对",
                "desc": "萌宠大集合，在线流式即点即玩！",
                "coverUrl": "covers/cover_animals.webp",
                "status": "active",
                "type": "array",
                "levels": [
                    "../main/images/0101.webp",
                    "../main/images/0103.webp",
                    "../main/images/0104.webp",
                    "../main/images/0109.webp",
                    "../main/images/0114.webp",
                ],
                "startTime": "2026-08-15T00:00:00Z",
                "endTime": "2026-09-05T00:00:00Z",
                "displayOrder": 3,
            },
            {
                "id": "oil_art_gallery",
                "title": "卢浮宫印象 · 经典传世油画",
                "desc": "典藏莫奈、梵高与达芬奇不朽画作。",
                "coverUrl": "covers/cover_art.webp",
                "status": "active",
                "type": "zip",
                "zipUrl": "zips/oil_art.zip",
                "zipSha256": hash_art,
                "startTime": "2026-08-20T00:00:00Z",
                "endTime": "2026-09-30T00:00:00Z",
                "displayOrder": 4,
            },
            {
                "id": "ancient_architecture",
                "title": "东方古韵 · 亭台楼阁",
                "desc": "品味古建筑美学。",
                "coverUrl": "covers/cover_arch.webp",
                "status": "outdated",
                "type": "array",
                "levels": [
                    "../main/images/0107.webp",
                    "../main/images/0112.webp",
                    "../main/images/0118.webp",
                ],
                "startTime": "2026-07-01T00:00:00Z",
                "endTime": "2026-08-15T00:00:00Z",
                "displayOrder": 5,
            },
            {"id": "expired_cleanup_test", "status": "disabled"},
        ],
    }
    events_index_file = events_dir / "index.json"
    with open(events_index_file, "w", encoding="utf-8") as f:
        json.dump(events_index_data, f, ensure_ascii=False, indent=2)
    events_index_hash = compute_sha256(events_index_file)
    print(f"  [OK] events/index.json deployed.")

    # ----------------------------------------------------
    # 4. 部署合集中心 collections/
    # ----------------------------------------------------
    print("\n[4/5] Building collections module...")
    col_dir = BASE_DIR / "collections"
    col_zips_dir = col_dir / "zips"
    col_covers_dir = col_dir / "covers"
    col_zips_dir.mkdir(parents=True, exist_ok=True)
    col_covers_dir.mkdir(parents=True, exist_ok=True)

    def create_collection_zip(zip_name: str, count: int, offset: int) -> tuple[Path, int, str]:
        zpath = col_zips_dir / zip_name
        with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as zf:
            for i in range(1, count + 1):
                src_img = src_images[(i + offset) % len(src_images)]
                buf = io.BytesIO()
                with Image.open(src_img) as img:
                    if img.mode not in ("RGB", "RGBA"):
                        img = img.convert("RGB")
                    img.save(buf, format="WEBP", quality=85)
                zf.writestr(f"{i:02d}.webp", buf.getvalue())
        return zpath, zpath.stat().st_size, compute_sha256(zpath)

    def create_collection_array(dir_name: str, count: int, offset: int) -> list[str]:
        sub_dir = col_dir / dir_name
        sub_dir.mkdir(parents=True, exist_ok=True)
        levels = []
        for idx in range(count):
            fname = f"{idx + 1:02d}.webp"
            convert_to_webp(src_images[(offset + idx) % len(src_images)], sub_dir / fname)
            levels.append(f"{dir_name}/{fname}")
        return levels

    convert_to_webp(src_images[60 % len(src_images)], col_covers_dir / "cover_flowers.webp")
    convert_to_webp(src_images[65 % len(src_images)], col_covers_dir / "cover_city.webp")
    convert_to_webp(src_images[70 % len(src_images)], col_covers_dir / "cover_cat_art.webp")
    convert_to_webp(src_images[75 % len(src_images)], col_covers_dir / "cover_ocean.webp")

    z_flowers, s_flowers, h_flowers = create_collection_zip("spring_flowers.zip", 6, 60)
    city_levels = create_collection_array("city_landmarks", 5, 65)
    z_cats, s_cats, h_cats = create_collection_zip("cat_art_gallery.zip", 4, 70)
    ocean_levels = create_collection_array("ocean_adventure", 3, 75)

    collections_index_data = {
        "module": "collections",
        "version": 4,
        "updatedAt": "2026-09-05T21:45:00Z",
        "items": [
            {
                "id": "spring_flowers",
                "title": "春日花语 · 百花图鉴",
                "desc": "收录 6 幅春日花卉拼图合集。",
                "coverUrl": "covers/cover_flowers.webp",
                "displayOrder": 1,
                "type": "zip",
                "zipUrl": "zips/spring_flowers.zip",
                "totalCount": 6,
                "fileSizeBytes": s_flowers,
            },
            {
                "id": "city_landmarks",
                "title": "世界城市地标",
                "desc": "5 座经典城市地标拼图合集。",
                "coverUrl": "covers/cover_city.webp",
                "displayOrder": 2,
                "type": "array",
                "levels": city_levels,
                "totalCount": len(city_levels),
                "fileSizeBytes": 0,
            },
            {
                "id": "cat_art_gallery",
                "title": "猫咪美术馆",
                "desc": "4 幅治愈系插画拼图合集。",
                "coverUrl": "covers/cover_cat_art.webp",
                "displayOrder": 3,
                "type": "zip",
                "zipUrl": "zips/cat_art_gallery.zip",
                "totalCount": 4,
                "fileSizeBytes": s_cats,
            },
            {
                "id": "ocean_adventure",
                "title": "海洋探险",
                "desc": "3 幅海洋世界主题拼图，即点即玩。",
                "coverUrl": "covers/cover_ocean.webp",
                "displayOrder": 4,
                "type": "array",
                "levels": ocean_levels,
                "totalCount": len(ocean_levels),
                "fileSizeBytes": 0,
            },
        ],
    }
    collections_index_file = col_dir / "index.json"
    with open(collections_index_file, "w", encoding="utf-8") as f:
        json.dump(collections_index_data, f, ensure_ascii=False, indent=2)
    collections_index_hash = compute_sha256(collections_index_file)
    print(f"  [OK] collections/index.json deployed.")

    # ----------------------------------------------------
    # 5. 部署扩展测试图包 packs/ 与 根清单 manifest.json
    # ----------------------------------------------------
    print("\n[5/5] Deploying packs/ and Root manifest.json...")
    packs_dir = BASE_DIR / "packs"
    packs_dir.mkdir(parents=True, exist_ok=True)

    # 拷贝测试包
    src_packs = Path("X:/www/game/test/packs")
    if src_packs.exists():
        for p_file in src_packs.glob("*.zip"):
            shutil.copy2(p_file, packs_dir / p_file.name)
        print(f"  [OK] Copied existing packs from test/packs to test2/packs.")
    else:
        with zipfile.ZipFile(packs_dir / "cats_pure_images.zip", "w", zipfile.ZIP_DEFLATED) as zf:
            for idx in range(6):
                src_img = src_images[(idx + 3) % len(src_images)]
                buf = io.BytesIO()
                with Image.open(src_img) as img:
                    if img.mode not in ("RGB", "RGBA"):
                        img = img.convert("RGB")
                    img.save(buf, format="WEBP", quality=85)
                zf.writestr(f"cat_{idx + 1:02d}.webp", buf.getvalue())

    # Root Manifest
    root_manifest = {
        "schemaVersion": 4,
        "updatedAt": "2026-09-05T22:30:00Z",
        "appConfig": {
            "notice": "Universal Deterministic Content Architecture v2.3.0 Ready",
            "minAppVersion": "1.0.0",
        },
        "modules": {
            "main": {
                "url": "main/index.json",
                "version": 103,
                "totalCount": 20,
                "hash": main_index_hash,
            },
            "daily": {
                "url": "daily/index.json",
                "version": 12,
                "currentMonth": "202609",
                "hash": daily_index_hash,
            },
            "events": {
                "url": "events/index.json",
                "version": 5,
                "count": 5,
                "hash": events_index_hash,
            },
            "collections": {
                "url": "collections/index.json",
                "version": 4,
                "count": 4,
                "hash": collections_index_hash,
            },
        },
    }
    with open(BASE_DIR / "manifest.json", "w", encoding="utf-8") as f:
        json.dump(root_manifest, f, ensure_ascii=False, indent=2)

    print("\n>>> All test2 data generated successfully! <<<")


if __name__ == "__main__":
    main()
