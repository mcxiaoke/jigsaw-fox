#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.exporters.main_exporter — 主线关卡导出器 (main.json + 图片转码 + 纯路由清单)
"""

from __future__ import annotations

import datetime as dt
import json
import urllib.parse
from pathlib import Path
from typing import Any

from studio.core.export_tracker import get_exported_hashes, record_exports
from studio.core.image_proc import convert_image, make_rename
from studio.core.scanner import compute_file_sha256, find_tags_file, scan_images
from studio.core.tags_manager import load_tags_file, normalize_records
from studio.exporters.base import BaseExporter, ExportResult
from studio.exporters.manifest_manager import ManifestManager
from studio.taxonomy import guess_tags_from_path, normalize_token


class MainExporter(BaseExporter):
    def validate(self) -> None:
        if not self.src_p.exists() or not self.src_p.is_dir():
            raise ValueError(f"源目录不存在: {self.src_p}")

    def execute(self) -> ExportResult:
        images = scan_images(self.src_p)
        self.log(f"扫描到 {len(images)} 张图片", "info")
        if not images:
            raise ValueError("源目录中没有找到可导出的图片文件")

        # 读取或使用前端传入的 tags 记录
        raw_records = self.data.get("tagsRecords")
        records: list[dict[str, Any]] = []
        if raw_records:
            records, _ = normalize_records(raw_records, self.src_p)
        else:
            tag_file = find_tags_file(self.src_p)
            if tag_file:
                raw, _ = load_tags_file(tag_file)
                records, _ = normalize_records(raw, self.src_p)

        tag_map: dict[str, list[str]] = {}
        hash_map: dict[str, str] = {}
        for r in records:
            key = (r.get("path") or r.get("file") or "").replace("\\", "/")
            tags = r.get("tags") or ["others"]
            norm_tags = [normalize_token(t) or t.lower() for t in tags]
            tag_map[key] = norm_tags
            tag_map[Path(key).name] = norm_tags
            if r.get("hash"):
                hash_map[key] = r["hash"]
                hash_map[Path(key).name] = r["hash"]

        # 防重复过滤 (如果开启了排除已导出)
        if self.data.get("excludeExported"):
            exported_hashes = get_exported_hashes(self.src_p)
            if exported_hashes:
                filtered_images = []
                excluded_cnt = 0
                for p in images:
                    rel = p.relative_to(self.src_p).as_posix().replace("\\", "/")
                    h = hash_map.get(rel) or hash_map.get(p.name) or compute_file_sha256(p)
                    if h in exported_hashes:
                        excluded_cnt += 1
                    else:
                        filtered_images.append(p)
                if excluded_cnt > 0:
                    self.log(f"已自动排除 {excluded_cnt} 张已导出的历史图片，剩余 {len(filtered_images)} 张待处理", "info")
                images = filtered_images
                if not images:
                    raise ValueError("所选范围内的图片均已在历史批次中导出，无新图片可供导出")

        # 计算版本号
        start_order = int(self.data.get("startOrder", 101))
        version_input = self.data.get("version")
        version = 0
        try:
            if version_input not in (None, ""):
                version = int(version_input)
        except Exception:
            version = 0

        existing_main = self.out_p / "main.json"
        if version <= 0:
            if existing_main.exists():
                try:
                    version = int(json.loads(existing_main.read_text(encoding="utf-8")).get("version", 0)) + 1
                except Exception:
                    version = 101
            else:
                version = 101

        # 图片转码与复制
        main_dir = self.out_p / "main"
        main_dir.mkdir(parents=True, exist_ok=True)
        levels: list[dict[str, Any]] = []
        exported_items: list[dict[str, Any]] = []
        converted_count = 0
        errors: list[str] = []

        for idx, p in enumerate(images):
            rel = p.relative_to(self.src_p).as_posix().replace("\\", "/")
            tags = tag_map.get(rel) or tag_map.get(p.name)
            if not tags or tags == ["others"]:
                guessed = guess_tags_from_path(p, root=self.src_p)
                if guessed:
                    tags = guessed
            if not tags:
                tags = ["others"]
            order = start_order + idx
            new_name = make_rename(p.name, order, self.rename_rule, self.fmt)
            dst = main_dir / new_name

            ok, err = convert_image(p, dst, self.fmt)
            if ok:
                converted_count += 1
            else:
                errors.append(f"{p.name}: {err}")

            encoded_name = urllib.parse.quote(new_name)
            levels.append({
                "url": f"{self.http_base}/main/{encoded_name}",
                "tags": tags,
                "order": order,
            })

            # 记录导出账本数据
            h = hash_map.get(rel) or hash_map.get(p.name) or compute_file_sha256(p)
            exported_items.append({
                "hash": h,
                "path": rel,
                "file_name": p.name,
                "file_size": p.stat().st_size if p.exists() else 0,
                "export_type": "main",
                "target": f"main/{new_name}",
                "order": order,
            })

        self.log(f"图片处理完成: {converted_count}/{len(images)}" + (f", {len(errors)} 失败" if errors else ""), "ok")

        now_str = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")

        # 写入 main.json
        payload = {
            "version": version,
            "count": len(levels),
            "updatedAt": now_str,
            "levels": levels,
        }
        tmp_json = existing_main.with_suffix(".tmp")
        tmp_json.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp_json.replace(existing_main)
        self.log(f"main.json 写入成功 (version={version}, count={len(levels)})", "ok")

        files = [str(existing_main.resolve())]

        # 更新 manifest.json
        m_file = ManifestManager.update_module(
            self.out_p,
            "main",
            version,
            f"{self.http_base}/main.json",
            self.log,
            count=len(levels),
        )
        if m_file:
            files.append(str(m_file.resolve()))

        # 写入源目录下的 exported.json 账本
        try:
            record_exports(self.src_p, exported_items)
            self.log(f"已成功将 {len(exported_items)} 张图片记入 exported.json 账本", "ok")
        except Exception as e:
            self.log(f"更新 exported.json 失败: {e}", "warn")

        return ExportResult(
            success=True,
            summary=f"已成功导出 {len(levels)} 个关卡至 main.json (version={version})",
            files=files,
        )
