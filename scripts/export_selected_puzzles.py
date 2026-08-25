#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
🧩 Jigsaw Puzzle Asset Exporter & Level Packager (拼图关卡素材自动归档与导出工具)

功能特性:
1. 自动读取网页导出的 `puzzle_selection.json` 或质检报告 `puzzle_quality_report.json`。
2. 自动按语义主题（anime/nature/animals/architecture/art/plants/cozy_life 等）在目标目录创建分类子文件夹。
3. 严格遵循人工精选原则：不自动生成 featured 分类（已注释，由人工后续从各主题精选）。
4. 纯净可选参数控制：智能裁切 (--auto-crop)、WebP转码 (--webp)、生成清单 (--manifest) 均为可选开关。

使用环境: Python 3.10+, pillow, opencv-python, numpy
"""

import argparse
import io
import json
import os
from pathlib import Path
import re
import shutil
import sys
import time
from typing import Any, Dict, List, Optional

# 解决 Windows 控制台 UTF-8
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

import cv2
import numpy as np
from PIL import Image

THEME_DIR_MAP = {
    "动漫": "anime",
    "萌宠": "animals",
    "风光": "nature",
    "建筑": "architecture",
    "名画": "art",
    "植物": "plants",
    "生活": "cozy_life",
    "机械": "vehicles",
    "奇幻": "fantasy",
    # "精选": "featured",  # 注释掉：featured 必须由人工从各个分类中精挑细选，不作自动归类
}


def sanitize_filename(name: str) -> str:
    """清理文件名中的非法字符"""
    return re.sub(r'[\\/*?:"<>| ]', '_', name)


def map_theme_to_dir_name(theme_category: str) -> str:
    """将语义主题映射为英文标准目录名 (无匹配时归入 others，不生成 featured)"""
    for key, val in THEME_DIR_MAP.items():
        if key in theme_category:
            return val
    return "nature"  # 默认回退为自然风光或 others，不生成 featured


def read_image_safely(image_path: Path) -> Optional[np.ndarray]:
    """跨平台安全读取图片，自动校正 EXIF 旋转方向"""
    try:
        with open(image_path, "rb") as f:
            file_bytes = f.read()
        pil_img = Image.open(io.BytesIO(file_bytes))
        from PIL import ImageOps
        pil_img = ImageOps.exif_transpose(pil_img)
        if pil_img.mode != "RGB":
            pil_img = pil_img.convert("RGB")
        rgb_arr = np.array(pil_img)
        return cv2.cvtColor(rgb_arr, cv2.COLOR_RGB2BGR)
    except Exception:
        try:
            with open(image_path, "rb") as f:
                file_bytes = np.frombuffer(f.read(), dtype=np.uint8)
                return cv2.imdecode(file_bytes, cv2.IMREAD_COLOR)
        except Exception:
            return None


def apply_smart_crop_if_needed(img: np.ndarray, crop_suggestion: str) -> np.ndarray:
    """根据建议执行边缘死区裁切"""
    if not crop_suggestion or "建议" not in crop_suggestion:
        return img
    
    h, w = img.shape[:2]
    top_cut = 0
    bottom_cut = 0
    left_cut = 0
    right_cut = 0
    
    if "顶部裁切" in crop_suggestion:
        top_cut = int(h * 0.12)
    if "底部裁切" in crop_suggestion:
        bottom_cut = int(h * 0.10)
    if "左右两侧微裁" in crop_suggestion:
        left_cut = int(w * 0.08)
        right_cut = int(w * 0.08)
        
    y1, y2 = top_cut, h - bottom_cut
    x1, x2 = left_cut, w - right_cut
    
    if y2 > y1 + 100 and x2 > x1 + 100:
        return img[y1:y2, x1:x2]
    return img


def export_selected_images(
    manifest_path: Path,
    target_dir: Path,
    min_grade: Optional[str] = None,
    auto_crop: bool = False,
    convert_webp: bool = False,
    webp_quality: int = 90,
    generate_manifest: bool = False
):
    if not manifest_path.exists():
        print(f"❌ 错误: 清单文件不存在: {manifest_path}")
        sys.exit(1)
        
    with open(manifest_path, "r", encoding="utf-8") as f:
        data = json.load(f)
        
    images_list = data.get("images", []) if isinstance(data, dict) else data
    if not images_list:
        print(f"⚠️ 清单中未包含任何图片条目: {manifest_path}")
        sys.exit(0)
        
    target_dir.mkdir(parents=True, exist_ok=True)
    
    grade_hierarchy = {"S": 5, "A": 4, "B": 3, "C": 2, "F": 1}
    min_weight = grade_hierarchy.get(min_grade.upper(), 0) if min_grade else 0
    
    exported_count = 0
    skipped_count = 0
    manifest_levels = []
    
    print("\n" + "=" * 62)
    print("  🧩 Jigsaw Puzzle 素材提取与分类归档管线")
    print("==============================================================")
    print(f"  📄 读取清单: {manifest_path.resolve()}")
    print(f"  📁 导出目标: {target_dir.resolve()}")
    print(f"  🖼️ 待选数量: {len(images_list)} 张")
    print(f"  ✂️ 智能裁切: {'已开启 (--auto-crop)' if auto_crop else '未开启 (原图直拷)'}")
    print(f"  📦 格式转码: {'开启 WebP 转码 (--webp, 质量 ' + str(webp_quality) + ')' if convert_webp else '未开启 (保留原始文件格式)'}")
    print(f"  📑 生成索引: {'已开启 levels_manifest.json (--manifest)' if generate_manifest else '未开启'}\n")
    
    for idx, item in enumerate(images_list, 1):
        src_path_str = item.get("file_path", "")
        file_name = item.get("file_name", Path(src_path_str).name)
        grade = item.get("grade", "A")
        theme = item.get("theme_category", "自然风光")
        crop_sug = item.get("crop_suggestion", "")
        
        # 评级过滤
        if min_weight > 0 and grade_hierarchy.get(grade, 0) < min_weight:
            skipped_count += 1
            continue
            
        src_file = Path(src_path_str)
        if not src_file.exists():
            print(f"  ⚠️ [跳过] 原始文件不存在: {src_file}")
            skipped_count += 1
            continue
            
        # 确定目标分类子目录 (严格不生成 featured)
        sub_dir_name = map_theme_to_dir_name(theme)
        category_dir = target_dir / sub_dir_name
        category_dir.mkdir(parents=True, exist_ok=True)
        
        # 目标文件名
        base_stem = sanitize_filename(src_file.stem)
        target_ext = ".webp" if convert_webp else src_file.suffix.lower()
        dst_file = category_dir / f"{base_stem}{target_ext}"
        
        # 处理图片读取、裁切与保存
        try:
            if auto_crop or convert_webp:
                img_bgr = read_image_safely(src_file)
                if img_bgr is not None:
                    if auto_crop:
                        img_bgr = apply_smart_crop_if_needed(img_bgr, crop_sug)
                    
                    if convert_webp:
                        encode_param = [int(cv2.IMWRITE_WEBP_QUALITY), webp_quality]
                        cv2.imencode(".webp", img_bgr, encode_param)[1].tofile(str(dst_file))
                    else:
                        cv2.imwrite(str(dst_file), img_bgr)
                else:
                    shutil.copy2(src_file, dst_file)
            else:
                shutil.copy2(src_file, dst_file)
                
            exported_count += 1
            print(f"  ✅ [{exported_count:3d}] 已归档至 [{sub_dir_name}/]: {dst_file.name} (评级: {grade} | {theme})")
            
            # 构造关卡元数据条目
            if generate_manifest:
                manifest_levels.append({
                    "id": f"{sub_dir_name}_{base_stem}",
                    "name": file_name,
                    "category": theme,
                    "category_dir": sub_dir_name,
                    "relative_path": f"assets/images/levels/{sub_dir_name}/{dst_file.name}",
                    "aspect_ratio": item.get("best_matching_aspect", "1:1 (正方形)"),
                    "recommended_difficulty": item.get("recommended_difficulty", "36~64块"),
                    "max_recommended_grid": item.get("max_recommended_grid", "100 块"),
                    "subject_summary": item.get("subject_summary", ""),
                    "art_style": item.get("art_style", ""),
                    "palette_colors": item.get("palette_hex_colors", []),
                    "playability_score": item.get("playability_score", 85),
                    "curator_note": item.get("curator_note", "")
                })
            
        except Exception as e:
            print(f"  ❌ 处理失败 {src_file.name}: {e}")
            skipped_count += 1

    # 可选生成游戏关卡 Manifest
    if generate_manifest and manifest_levels:
        game_manifest_file = target_dir / "levels_manifest.json"
        manifest_data = {
            "version": 1,
            "generated_at": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime()),
            "total_levels": len(manifest_levels),
            "categories": list(set(lvl["category"] for lvl in manifest_levels)),
            "levels": manifest_levels
        }
        with open(game_manifest_file, "w", encoding="utf-8") as f:
            json.dump(manifest_data, f, ensure_ascii=False, indent=2)
        print(f"\n📑 已生成游戏关卡清单索引: {game_manifest_file.resolve()}")

    print("\n" + "=" * 62)
    print(f"🎉 归档完成！成功导出: {exported_count} 张素材 (跳过: {skipped_count} 张)")
    print(f"📁 目标目录: {target_dir.resolve()}")
    print("=" * 62 + "\n")


def main():
    parser = argparse.ArgumentParser(
        description="🧩 Jigsaw Puzzle Asset Exporter (拼图关卡素材自动归档与导出工具)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""示例用法:
  # 1. 基础用法: 原图原格式直接复制并按分类建目录 (默认不裁切、不压缩、不生成manifest)
  python scripts/export_selected_puzzles.py -i puzzle_selection.json -o ./assets/images/levels
  
  # 2. 完整管线: 开启智能裁切 + 转换为 WebP + 生成游戏 manifest
  python scripts/export_selected_puzzles.py -i puzzle_selection.json -o ./assets/images/levels --auto-crop --webp --manifest
  
  # 3. 从全量报告中直接过滤 S/A 级并导出
  python scripts/export_selected_puzzles.py -i temp/puzzle_quality_report/puzzle_quality_report.json -o ./assets/images/levels --min-grade A --webp
        """
    )
    parser.add_argument("-i", "--input-json", type=str, required=True, help="输入的 JSON 清单路径 (如 puzzle_selection.json 或 puzzle_quality_report.json)")
    parser.add_argument("-o", "--output-dir", type=str, default="./assets/images/levels", help="导出的目标素材目录 (默认: ./assets/images/levels)")
    parser.add_argument("--min-grade", type=str, choices=["S", "A", "B", "C"], default=None, help="最低准入评级 (可选: S/A/B/C)")
    
    # 纯净可选开关
    parser.add_argument("--auto-crop", action="store_true", help="可选：自动按智能裁剪建议裁掉单侧纯色天空/暗部 (默认: 关闭)")
    parser.add_argument("--webp", action="store_true", help="可选：将图片压缩转码为 WebP 格式 (默认: 关闭，保持原图原格式)")
    parser.add_argument("--quality", type=int, default=90, help="WebP 编码质量 1~100 (默认: 90，仅在开启 --webp 时生效)")
    parser.add_argument("--manifest", action="store_true", help="可选：在目标目录生成 levels_manifest.json (默认: 关闭)")
    
    args = parser.parse_args()
    
    export_selected_images(
        manifest_path=Path(args.input_json),
        target_dir=Path(args.output_dir),
        min_grade=args.min_grade,
        auto_crop=args.auto_crop,
        convert_webp=args.webp,
        webp_quality=args.quality,
        generate_manifest=args.manifest
    )


if __name__ == "__main__":
    main()
