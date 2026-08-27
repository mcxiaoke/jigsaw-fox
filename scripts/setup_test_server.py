#!/usr/bin/env python3
"""
在测试服务器 X:\\www\\game\\test 下构建丰富的拼图内容测试数据。
包含：
1. manifest.json (Root Manifest)
2. main.json + main/ 关卡图片 (101~120，20关，多标签)
3. daily/202608.zip (每日挑战 8 月 31 天整包，20260801.jpg ~ 20260831.jpg)
4. events/ 包含 5 个不同类型的丰富活动 (Zip 与 Array 模式)
"""

import os
import shutil
import json
import zipfile
from pathlib import Path

BASE_DIR = Path("X:/www/game/test")
SRC_ANIMALS = Path("temp/animals-cropped")
SRC_TESTIMAGES = Path("temp/testimages")
HTTP_BASE = "http://192.168.1.118/data/www/game/test"

def main():
    print(f"Setting up rich test server data at {BASE_DIR}...")
    BASE_DIR.mkdir(parents=True, exist_ok=True)
    
    # 收集源图片
    src_images = []
    if SRC_ANIMALS.exists():
        src_images.extend(sorted(list(SRC_ANIMALS.glob("*.jpg")) + list(SRC_ANIMALS.glob("*.png"))))
    if SRC_TESTIMAGES.exists():
        src_images.extend(sorted(list(SRC_TESTIMAGES.glob("*.jpg")) + list(SRC_TESTIMAGES.glob("*.png"))))
        
    if not src_images:
        print("Error: No source images found!")
        return

    print(f"Found {len(src_images)} source images.")

    # 1. 部署首页主线 main/ (20 关: 101 ~ 120)
    main_dir = BASE_DIR / "main"
    main_dir.mkdir(exist_ok=True)
    
    predefined_tags = [
        ["animal", "ocean", "cute"],
        ["bird", "nature", "colorful"],
        ["animal", "bird", "cute"],
        ["animal", "panda", "cute"],
        ["insect", "nature", "macro"],
        ["landscape", "nature", "mountain"],
        ["architecture", "castle", "historic"],
        ["art", "oil_painting", "classic"],
        ["animal", "cat", "cute"],
        ["bird", "owl", "nature"],
        ["landscape", "sunset", "nature"],
        ["architecture", "city", "modern"],
        ["art", "abstract", "colorful"],
        ["animal", "dog", "cute"],
        ["nature", "forest", "green"],
        ["animal", "tiger", "wild"],
        ["landscape", "beach", "ocean"],
        ["architecture", "bridge", "night"],
        ["art", "watercolor", "flower"],
        ["animal", "rabbit", "cute"],
    ]
    
    main_levels = []
    for i in range(20):
        num = 101 + i
        src_img = src_images[i % len(src_images)]
        ext = src_img.suffix
        dst_name = f"{num}{ext}"
        dst_path = main_dir / dst_name
        shutil.copy2(src_img, dst_path)
        
        tags = predefined_tags[i % len(predefined_tags)]
        main_levels.append({
            "url": f"{HTTP_BASE}/main/{dst_name}",
            "tags": tags
        })
        
    main_json = {
        "version": 120,
        "updatedAt": "2026-08-27T06:00:00Z",
        "levels": main_levels
    }
    with open(BASE_DIR / "main.json", "w", encoding="utf-8") as f:
        json.dump(main_json, f, ensure_ascii=False, indent=2)
    print(f"[OK] main.json ({len(main_levels)} levels) and main/ images deployed.")

    # 2. 部署每日挑战 daily/ 202608.zip 和 202607.zip (各 31 天)
    daily_dir = BASE_DIR / "daily"
    daily_dir.mkdir(exist_ok=True)
    
    # 202608.zip
    daily_zip_path_08 = daily_dir / "202608.zip"
    with zipfile.ZipFile(daily_zip_path_08, "w", zipfile.ZIP_DEFLATED) as zf:
        for day in range(1, 32):
            date_str = f"202608{day:02d}"
            src_img = src_images[(day + 5) % len(src_images)]
            ext = src_img.suffix
            arcname = f"{date_str}{ext}"
            zf.write(src_img, arcname=arcname)
            
    # 202607.zip
    daily_zip_path_07 = daily_dir / "202607.zip"
    with zipfile.ZipFile(daily_zip_path_07, "w", zipfile.ZIP_DEFLATED) as zf:
        for day in range(1, 32):
            date_str = f"202607{day:02d}"
            src_img = src_images[(day + 15) % len(src_images)]
            ext = src_img.suffix
            arcname = f"{date_str}{ext}"
            zf.write(src_img, arcname=arcname)
            
    print(f"[OK] daily/202608.zip and daily/202607.zip (31 days each) created.")

    # 3. 部署丰富活动中心 events/
    events_dir = BASE_DIR / "events"
    events_dir.mkdir(exist_ok=True)
    
    # 辅助函数：创建活动 Zip
    def make_event_zip(zip_name, count, offset):
        zpath = events_dir / zip_name
        with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as zf:
            for i in range(1, count + 1):
                src_img = src_images[(i + offset) % len(src_images)]
                ext = src_img.suffix
                arcname = f"{i:02d}{ext}"
                zf.write(src_img, arcname=arcname)
        return zpath

    # 活动 1: 赛博幻夜 (Zip, 6 关)
    make_event_zip("cyberpunk_2026.zip", 6, 10)
    shutil.copy2(src_images[10 % len(src_images)], events_dir / "cover_cyberpunk.jpg")

    # 活动 2: 自然奇观 (Zip, 8 关)
    make_event_zip("nature_wonders.zip", 8, 20)
    shutil.copy2(src_images[20 % len(src_images)], events_dir / "cover_nature.jpg")

    # 活动 3: 传世油画名作 (Zip, 6 关)
    make_event_zip("oil_art.zip", 6, 30)
    shutil.copy2(src_images[30 % len(src_images)], events_dir / "cover_art.jpg")

    # 活动 4 封面 (Array 模式)
    shutil.copy2(src_images[40 % len(src_images)], events_dir / "cover_animals.jpg")
    
    # 活动 5 封面 (Array 模式)
    shutil.copy2(src_images[50 % len(src_images)], events_dir / "cover_arch.jpg")

    events_json = [
        {
            "id": "cyberpunk_2026",
            "title": "未来赛博都市 · 霓虹幻夜",
            "desc": "穿梭于流光溢彩的摩天楼群与雨夜街道，挑战 6 张限定赛博朋克风拼图。",
            "coverUrl": f"{HTTP_BASE}/events/cover_cyberpunk.jpg",
            "status": "active",
            "type": "zip",
            "zipUrl": f"{HTTP_BASE}/events/cyberpunk_2026.zip",
            "startTime": "2026-08-01T00:00:00Z",
            "endTime": "2026-09-10T00:00:00Z",
            "displayOrder": 1
        },
        {
            "id": "nature_wonders",
            "title": "自然秘境 · 国家地理特辑",
            "desc": "探索壮阔峡谷、极光雪原与热带雨林，包含 8 幅高清自然风光作品。",
            "coverUrl": f"{HTTP_BASE}/events/cover_nature.jpg",
            "status": "active",
            "type": "zip",
            "zipUrl": f"{HTTP_BASE}/events/nature_wonders.zip",
            "startTime": "2026-08-10T00:00:00Z",
            "endTime": "2026-09-20T00:00:00Z",
            "displayOrder": 2
        },
        {
            "id": "cute_animals_party",
            "title": "世界萌宠狂欢派对",
            "desc": "猫咪、熊猫、水獭与小柴犬的夏日大集合，在线流式即点即玩！",
            "coverUrl": f"{HTTP_BASE}/events/cover_animals.jpg",
            "status": "active",
            "type": "array",
            "levels": [
                f"{HTTP_BASE}/main/101.jpg",
                f"{HTTP_BASE}/main/103.jpg",
                f"{HTTP_BASE}/main/104.jpg",
                f"{HTTP_BASE}/main/109.jpg",
                f"{HTTP_BASE}/main/114.jpg"
            ],
            "startTime": "2026-08-15T00:00:00Z",
            "endTime": "2026-09-05T00:00:00Z",
            "displayOrder": 3
        },
        {
            "id": "oil_art_gallery",
            "title": "卢浮宫印象 · 经典传世油画",
            "desc": "典藏莫奈、梵高与达芬奇不朽画作，感受笔触间的艺术魅力。",
            "coverUrl": f"{HTTP_BASE}/events/cover_art.jpg",
            "status": "active",
            "type": "zip",
            "zipUrl": f"{HTTP_BASE}/events/oil_art.zip",
            "startTime": "2026-08-20T00:00:00Z",
            "endTime": "2026-09-30T00:00:00Z",
            "displayOrder": 4
        },
        {
            "id": "ancient_architecture",
            "title": "东方古韵 · 亭台楼阁",
            "desc": "品味千年古刹、江南园林与雄伟长城的建筑美学。",
            "coverUrl": f"{HTTP_BASE}/events/cover_arch.jpg",
            "status": "outdated",
            "type": "array",
            "levels": [
                f"{HTTP_BASE}/main/107.jpg",
                f"{HTTP_BASE}/main/112.jpg",
                f"{HTTP_BASE}/main/118.jpg"
            ],
            "startTime": "2026-07-01T00:00:00Z",
            "endTime": "2026-08-15T00:00:00Z",
            "displayOrder": 5
        },
        {
            "id": "expired_cleanup_test",
            "status": "disabled"
        }
    ]
    with open(events_dir / "events.json", "w", encoding="utf-8") as f:
        json.dump(events_json, f, ensure_ascii=False, indent=2)
    print(f"[OK] events/events.json ({len(events_json)} events) and zips created.")

    # 4. 部署根清单 manifest.json
    root_manifest = {
        "schemaVersion": 3,
        "updatedAt": "2026-08-27T14:50:00Z",
        "appConfig": {
            "minAppVersion": "1.0.0",
            "notice": "欢迎体验全动态活动与多标签关卡！"
        },
        "modules": {
            "main": {
                "url": f"{HTTP_BASE}/main.json",
                "version": 120
            },
            "daily": {
                "currentMonth": "202608",
                "zipUrlPattern": f"{HTTP_BASE}/daily/{{YYYYMM}}.zip",
                "listUrlPattern": f"{HTTP_BASE}/daily/{{YYYYMM}}.json",
                "version": 20260827
            },
            "events": {
                "url": f"{HTTP_BASE}/events/events.json",
                "version": 15
            }
        }
    }
    with open(BASE_DIR / "manifest.json", "w", encoding="utf-8") as f:
        json.dump(root_manifest, f, ensure_ascii=False, indent=2)
    print("[OK] manifest.json created at root.")

    # 5. 部署扩展测试图包 packs/
    packs_dir = BASE_DIR / "packs"
    packs_dir.mkdir(exist_ok=True)

    # 5.1 纯图片测试包 (零元数据) cats_pure_images.zip
    cats_zip_path = packs_dir / "cats_pure_images.zip"
    with zipfile.ZipFile(cats_zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for idx in range(6):
            src_img = src_images[(idx + 3) % len(src_images)]
            zf.write(src_img, arcname=f"cat_{idx+1:02d}.jpg")
    print("[OK] packs/cats_pure_images.zip (6 pure images) created.")

    # 5.2 创作者标准扩展包 (带 pack.json 元数据) cyberpunk_with_manifest.zip
    cyber_zip_path = packs_dir / "cyberpunk_with_manifest.zip"
    with zipfile.ZipFile(cyber_zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        # 封面图
        zf.write(src_images[5 % len(src_images)], arcname="cover.jpg")
        # 关卡图片
        for idx in range(6):
            src_img = src_images[(idx + 7) % len(src_images)]
            zf.write(src_img, arcname=f"level_{idx+1:02d}.jpg")
        # pack.json
        cyber_manifest = {
            "id": "cyberpunk_neon_2026",
            "title": "赛博霓虹·未来都市",
            "description": "流光溢彩的赛博朋克夜景拼图精选合辑",
            "author": "NeonArtist",
            "version": 1,
            "cover": "cover.jpg",
            "tags": ["科幻", "夜景", "建筑"]
        }
        zf.writestr("pack.json", json.dumps(cyber_manifest, ensure_ascii=False, indent=2))
    print("[OK] packs/cyberpunk_with_manifest.zip (with pack.json) created.")

    print("\nAll rich test server data successfully deployed to X:\\www\\game\\test !")

if __name__ == "__main__":
    main()

