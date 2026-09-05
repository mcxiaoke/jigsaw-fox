#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.exporters.collection_exporter — 主题合集关卡导出器 (collections.json + zip/array)
"""

from __future__ import annotations

import datetime as dt
import json
import tempfile
import zipfile
from pathlib import Path
from typing import Any

from studio.core.export_tracker import get_exported_hashes, record_exports
from studio.core.image_proc import HAS_PIL, convert_image, make_rename
from studio.core.scanner import compute_file_sha256, scan_images
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

        # 防重复过滤 (如果开启了排除已导出)
        if self.data.get("excludeExported"):
            exported_hashes = get_exported_hashes(self.src_p)
            if exported_hashes:
                filtered_images = []
                excluded_cnt = 0
                for p in images:
                    h = compute_file_sha256(p)
                    if h in exported_hashes:
                        excluded_cnt += 1
                    else:
                        filtered_images.append(p)
                if excluded_cnt > 0:
                    self.log(f"已自动排除 {excluded_cnt} 张已导出的历史图片，剩余 {len(filtered_images)} 张待处理", "info")
                images = filtered_images
                if not images:
                    raise ValueError("所选范围内的图片均已在历史批次中导出，无新图片可供导出")

        cols_dir = self.out_p / "collections"
        cols_dir.mkdir(parents=True, exist_ok=True)
        files: list[str] = []

        cover_url = ""
        zip_url = ""
        level_urls: list[str] = []
        exported_items: list[dict[str, Any]] = []

        if output_mode == "zip":
            zip_path = cols_dir / f"{col_id}.zip"
            with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
                for idx, p in enumerate(images, start=1):
                    arc_name = make_rename(p.name, idx, self.rename_rule, self.fmt)
                    file_hash = compute_file_sha256(p)
                    exported_items.append({
                        "hash": file_hash,
                        "path": p.relative_to(self.src_p).as_posix().replace("\\", "/"),
                        "file_name": p.name,
                        "file_size": p.stat().st_size if p.exists() else 0,
                        "export_type": "collection",
                        "target": f"collections/{col_id}.zip#{arc_name}",
                        "collection_id": col_id,
                    })
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

                file_hash = compute_file_sha256(p)
                exported_items.append({
                    "hash": file_hash,
                    "path": p.relative_to(self.src_p).as_posix().replace("\\", "/"),
                    "file_name": p.name,
                    "file_size": p.stat().st_size if p.exists() else 0,
                    "export_type": "collection",
                    "target": f"collections/{col_id}/{new_name}",
                    "collection_id": col_id,
                })
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

        now_str = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
        item_entry: dict[str, Any] = {
            "id": col_id,
            "title": title,
            "desc": desc,
            "displayOrder": display_order,
            "type": output_mode,
            "count": len(images),
            "totalCount": len(images),
            "updatedAt": now_str,
        }
        if cover_url:
            item_entry["coverUrl"] = cover_url
        if output_mode == "zip":
            item_entry["zipUrl"] = zip_url
            if zip_path.exists():
                item_entry["fileSizeBytes"] = zip_path.stat().st_size
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
        self.log(f"collections.json 已更新: 共 {len(existing_items)} 个合集 (当前合集 count={len(images)})", "ok")
        files.append(str(cols_json.resolve()))

        # 更新 manifest.json
        new_version = len(existing_items)
        m_file = ManifestManager.update_module(
            self.out_p,
            "collections",
            new_version,
            f"{self.http_base}/collections/collections.json",
            self.log,
            count=len(existing_items),
        )
        if m_file:
            files.append(str(m_file.resolve()))

        # 记录导出账本
        try:
            record_exports(self.src_p, exported_items)
            self.log(f"已成功将 {len(exported_items)} 张图片记入 exported.json 账本", "ok")
        except Exception as e:
            self.log(f"更新 exported.json 失败: {e}", "warn")

        return ExportResult(
            success=True,
            summary=f"已成功导出合集 {col_id} ({output_mode} 模式)",
            files=files,
        )
