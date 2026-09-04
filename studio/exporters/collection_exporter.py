#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.exporters.collection_exporter — 主题合集关卡导出器 (collections.json + zip/array)
"""

from __future__ import annotations

import json
import tempfile
import zipfile
from pathlib import Path
from typing import Any

from studio.core.image_proc import HAS_PIL, convert_image, make_rename
from studio.core.scanner import scan_images
from studio.exporters.base import BaseExporter, ExportResult
from studio.exporters.manifest_manager import ManifestManager


class CollectionExporter(BaseExporter):
    def validate(self) -> None:
        col_id = (self.data.get("collectionId") or "").strip()
        if not col_id:
            raise ValueError("必须指定合集 ID (collectionId)")
        if not self.src_p.exists() or not self.src_p.is_dir():
            raise ValueError(f"源目录不存在: {self.src_p}")

    def execute(self) -> ExportResult:
        col_id = (self.data.get("collectionId") or "").strip()
        title = self.data.get("title") or col_id
        desc = self.data.get("description", "")
        display_order = int(self.data.get("displayOrder", 1))
        output_mode = self.data.get("outputMode", "zip")

        images = scan_images(self.src_p)
        self.log(f"扫描到 {len(images)} 张图片，合集 ID: {col_id}，模式: {output_mode}", "info")
        if not images:
            raise ValueError("源目录中没有找到可导出的图片文件")

        cols_dir = self.out_p / "collections"
        cols_dir.mkdir(parents=True, exist_ok=True)
        files: list[str] = []

        cover_url = ""
        zip_url = ""
        level_urls: list[str] = []

        if output_mode == "zip":
            zip_path = cols_dir / f"{col_id}.zip"
            with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
                for idx, p in enumerate(images, start=1):
                    arc_name = make_rename(p.name, idx, self.rename_rule, self.fmt)
                    if self.fmt != "original" and HAS_PIL:
                        tmp_f = Path(tempfile.gettempdir()) / f"_col_{arc_name}"
                        ok, _ = convert_image(p, tmp_f, self.fmt)
                        if ok:
                            zf.write(tmp_f, arcname=arc_name)
                            tmp_f.unlink(missing_ok=True)
                            continue
                    zf.write(p, arcname=arc_name)

            zip_url = f"{self.http_base}/collections/{col_id}.zip"
            files.append(str(zip_path.resolve()))

            cover_dst = cols_dir / f"{col_id}_cover.webp"
            convert_image(images[0], cover_dst, "webp")
            cover_url = f"{self.http_base}/collections/{col_id}_cover.webp"
            files.append(str(cover_dst.resolve()))
            self.log(f"ZIP 打包与封面生成完毕: {zip_path.name}", "ok")
        else:
            item_dir = cols_dir / col_id
            item_dir.mkdir(parents=True, exist_ok=True)
            for idx, p in enumerate(images, start=1):
                new_name = make_rename(p.name, idx, self.rename_rule, self.fmt)
                dst = item_dir / new_name
                convert_image(p, dst, self.fmt)
                level_urls.append(f"{self.http_base}/collections/{col_id}/{new_name}")
            if level_urls:
                cover_url = level_urls[0]
            files.append(str(item_dir.resolve()))
            self.log(f"散图目录复制完毕: {len(level_urls)} 张", "ok")

        # 更新 collections.json
        cols_json = cols_dir / "collections.json"
        existing_items: list[dict[str, Any]] = []
        if cols_json.exists():
            try:
                loaded = json.loads(cols_json.read_text(encoding="utf-8"))
                if isinstance(loaded, list):
                    existing_items = loaded
            except Exception:
                existing_items = []

        item_entry: dict[str, Any] = {
            "id": col_id,
            "title": title,
            "desc": desc,
            "displayOrder": display_order,
            "type": output_mode,
        }
        if cover_url:
            item_entry["coverUrl"] = cover_url
        if output_mode == "zip":
            item_entry["zipUrl"] = zip_url
        else:
            item_entry["levels"] = level_urls

        found = False
        for i, it in enumerate(existing_items):
            if isinstance(it, dict) and it.get("id") == col_id:
                existing_items[i] = item_entry
                found = True
                break
        if not found:
            existing_items.append(item_entry)

        tmp_col = cols_json.with_suffix(".tmp")
        tmp_col.write_text(json.dumps(existing_items, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp_col.replace(cols_json)
        self.log(f"collections.json 已更新: 共 {len(existing_items)} 个合集", "ok")
        files.append(str(cols_json.resolve()))

        # 更新 manifest.json
        new_version = len(existing_items)
        m_file = ManifestManager.update_module(
            self.out_p,
            "collections",
            new_version,
            f"{self.http_base}/collections/collections.json",
            self.log,
        )
        if m_file:
            files.append(str(m_file.resolve()))

        return ExportResult(
            success=True,
            summary=f"已成功导出合集 {col_id} ({output_mode} 模式)",
            files=files,
        )
