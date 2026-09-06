#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.exporters.main_exporter — 主线关卡导出器 (自包含、不可变 batches/、纯数字命名、权威账本)
符合规范: v2.3.0 Universal Deterministic Content Architecture
"""

from __future__ import annotations

import datetime as dt
import json
from pathlib import Path
from typing import Any

from studio.core.exports_ledger import ExportsLedger
from studio.core.image_proc import convert_image, make_rename, validate_image
from studio.core.scanner import compute_file_sha256, find_tags_file, scan_images
from studio.core.tags_manager import load_tags_file, normalize_records
from studio.core.workspace import StudioWorkspace
from studio.exporters.base import BaseExporter, ExportResult
from studio.exporters.manifest_manager import ManifestManager
from studio.taxonomy import guess_tags_from_path, normalize_token


class MainExporter(BaseExporter):
    def validate(self) -> None:
        if not self.src_p.exists() or not self.src_p.is_dir():
            raise ValueError(f"源目录不存在: {self.src_p}")

    def execute(self) -> ExportResult:
        ws = StudioWorkspace(self.src_p)
        ledger = ExportsLedger(self.src_p)

        selected_paths = self.data.get("selectedPaths")
        if selected_paths and isinstance(selected_paths, list) and len(selected_paths) > 0:
            selected_set = {str(p).replace("\\", "/").strip().lower() for p in selected_paths}
            images = [
                p for p in scan_images(self.src_p)
                if p.relative_to(self.src_p).as_posix().lower() in selected_set
            ]
            self.log(f"已按指定范围载入 {len(images)} 张待导出图片", "info")
        else:
            images = scan_images(self.src_p)
            self.log(f"扫描源目录获得 {len(images)} 张图片", "info")

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
            tags = r.get("tags") or ["Others"]
            norm_tags = [normalize_token(t) for t in tags if normalize_token(t)] or ["Others"]
            tag_map[key] = norm_tags
            tag_map[Path(key).name] = norm_tags
            if r.get("hash"):
                hash_map[key] = r["hash"]
                hash_map[Path(key).name] = r["hash"]

        # 防重复过滤 (如果开启了排除已导出)
        if self.data.get("excludeExported"):
            exported_hashes = ledger.get_exported_hashes()
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

        # 0. 待导出图片格式与完整性硬拦截校验 (损坏/0字节立即中止)
        for p in images:
            valid, err_msg = validate_image(p)
            if not valid:
                self.log(f"导出中止: 待导出图片损坏或无效: {p.name} ({err_msg})", "err")
                raise ValueError(f"待导出图片损坏或无效: {p.name} ({err_msg})")

        # 1. 重复图片校验拦截：严禁同批次包含重复素材 (防止主线关卡重复)，检测到重复直接报错中止！
        seen_hashes: dict[str, list[str]] = {}
        for p in images:
            rel = p.relative_to(self.src_p).as_posix().replace("\\", "/")
            h = (hash_map.get(rel) or hash_map.get(p.name) or compute_file_sha256(p) or "").strip().lower()
            if h:
                seen_hashes.setdefault(h, []).append(rel)

        dup_groups = {h: paths for h, paths in seen_hashes.items() if len(paths) >= 2}
        if dup_groups:
            self.log(f"导出已被安全中止: 待导出图片列表中发现 {len(dup_groups)} 组内容完全相同的重复文件！", "err")
            detail_lines = [f"  • 重复组 [Hash: {h[:12]}...]: {', '.join(paths)}" for h, paths in dup_groups.items()]
            raise ValueError(
                f"待导出图片列表中存在 {len(dup_groups)} 组内容完全相同的重复图片，导出已被安全拦截！\n"
                f"为避免主线关卡重复，请先在素材库中清理或替换重复文件后再执行导出。\n"
                + "\n".join(detail_lines)
            )

        # 2. 输出目录拓扑准备 (.studio/release/main)
        release_main_dir = ws.release_dir / "main"
        batches_dir = release_main_dir / "batches"
        images_dir = release_main_dir / "images"
        batches_dir.mkdir(parents=True, exist_ok=True)
        images_dir.mkdir(parents=True, exist_ok=True)

        # 读取已有 index.json 获取版本与批次信息 (统一 items 键)
        index_json_path = release_main_dir / "index.json"
        existing_index: dict[str, Any] = {}
        existing_batches: list[dict[str, Any]] = []
        existing_version = 0
        existing_total_count = 0
        existing_max_order = ledger.get_max_order("main")

        if index_json_path.exists():
            try:
                existing_index = json.loads(index_json_path.read_text(encoding="utf-8"))
                if isinstance(existing_index, dict):
                    existing_batches = existing_index.get("items") or existing_index.get("batches") or []
                    existing_version = int(existing_index.get("version", 0))
                    existing_total_count = int(existing_index.get("totalCount", 0))
                    existing_max_order = max(existing_max_order, int(existing_index.get("maxOrder", 0)))
            except Exception:
                pass

        # 计算版本与起始序号
        start_order_input = self.data.get("startOrder")
        if start_order_input is not None and str(start_order_input).strip() != "":
            start_order = int(start_order_input)
        else:
            start_order = (existing_max_order + 1) if existing_max_order > 0 else 101

        version_input = self.data.get("version")
        if version_input not in (None, ""):
            version = int(version_input)
        elif existing_version > 0:
            version = existing_version + 1
        else:
            version = 101

        batch_id = self.data.get("batchId") or f"batch_{len(existing_batches) + 1:03d}"

        # 3. 历史查重与跨模块预警 (允许补丁修订同一个 logicalId，但严禁主线关卡互斥重复)
        is_patch = bool(self.data.get("isPatch", False))
        for idx, p in enumerate(images):
            rel = p.relative_to(self.src_p).as_posix().replace("\\", "/")
            h = (hash_map.get(rel) or hash_map.get(p.name) or compute_file_sha256(p) or "").strip().lower()
            order = start_order + idx
            logical_id = f"main:{order}"
            conflict, msg, sev = ledger.check_history_duplicate(h, module="main", logical_id=logical_id)
            if conflict:
                if sev == "error":
                    self.log(f"导出中止: {msg} (文件: {p.name})", "err")
                    raise ValueError(f"导出已被拦截: {msg}")
                elif sev == "warning":
                    self.log(f"注意: {msg} (文件: {p.name})", "warn")

        # 4. 图片转码与复制 (存放到 images/)
        batch_levels: list[dict[str, Any]] = []
        exported_items: list[dict[str, Any]] = []
        converted_count = 0
        errors: list[str] = []
        now_str = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")

        for idx, p in enumerate(images):
            rel = p.relative_to(self.src_p).as_posix().replace("\\", "/")
            tags = tag_map.get(rel) or tag_map.get(p.name)
            if not tags or tags == ["Others"] or tags == ["others"]:
                guessed = guess_tags_from_path(p, root=self.src_p)
                if guessed:
                    tags = guessed
            if not tags:
                tags = ["Others"]

            order = start_order + idx
            logical_id = f"main:{order}"

            if is_patch:
                rev = ledger.get_next_revision(logical_id)
                img_name = f"{order:04d}-r{rev}.{self.fmt}"
                prev_record = ledger.get_active_record(logical_id)
                supersedes_id = prev_record.get("recordId") if prev_record else None
            else:
                rev = 1
                img_name = make_rename(p.name, order, self.rename_rule, self.fmt)
                supersedes_id = None

            dst = images_dir / img_name
            ok, err = convert_image(p, dst, self.fmt)
            if ok:
                converted_count += 1
            else:
                errors.append(f"{p.name}: {err}")

            img_hash = compute_file_sha256(dst) if dst.exists() else ""

            batch_levels.append({
                "id": logical_id,
                "order": order,
                "url": f"../images/{img_name}",
                "tags": tags,
                "hash": img_hash,
                "addedAt": now_str,
            })

            h = hash_map.get(rel) or hash_map.get(p.name) or compute_file_sha256(p)
            exported_items.append({
                "sourceHash": h,
                "sourcePath": rel,
                "sourceSize": p.stat().st_size if p.exists() else 0,
                "module": "main",
                "logicalId": logical_id,
                "order": order,
                "batchId": batch_id,
                "targetFile": f"main/images/{img_name}",
                "targetHash": img_hash,
                "revision": rev,
                "supersedes": supersedes_id,
            })

        self.log(f"图片处理完成: {converted_count}/{len(images)}" + (f", {len(errors)} 失败" if errors else ""), "ok")

        # 5. 写入不可变批次文件 batches/batch_xxx.json (统一 items 键)
        batch_payload: dict[str, Any] = {
            "batchId": batch_id,
            "version": version,
            "count": len(batch_levels),
            "startOrder": start_order,
            "endOrder": start_order + len(batch_levels) - 1,
            "items": batch_levels,
        }
        if is_patch:
            batch_payload["patch"] = True
            batch_payload["levelsAffected"] = [lvl["order"] for lvl in batch_levels]

        batch_file = batches_dir / f"{batch_id}.json"
        tmp_batch = batch_file.with_suffix(".tmp")
        tmp_batch.write_text(json.dumps(batch_payload, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp_batch.replace(batch_file)
        self.log(f"分卷批次已写入: {batch_id}.json ({len(batch_levels)} 个关卡)", "ok")

        # 6. 更新主线分卷索引 index.json (统一 items 键)
        batch_entry: dict[str, Any] = {
            "batchId": batch_id,
            "version": version,
            "count": len(batch_levels),
            "startOrder": start_order,
            "endOrder": start_order + len(batch_levels) - 1,
            "url": f"batches/{batch_id}.json",
        }
        if is_patch:
            batch_entry["patch"] = True
            batch_entry["levelsAffected"] = batch_payload["levelsAffected"]

        existing_batches.append(batch_entry)
        new_total_count = existing_total_count + len(batch_levels) if not is_patch else existing_total_count
        new_max_order = max(existing_max_order, start_order + len(batch_levels) - 1)

        index_payload = {
            "module": "main",
            "version": version,
            "totalCount": new_total_count,
            "maxOrder": new_max_order,
            "updatedAt": now_str,
            "items": existing_batches,
        }
        tmp_idx = index_json_path.with_suffix(".tmp")
        tmp_idx.write_text(json.dumps(index_payload, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp_idx.replace(index_json_path)
        self.log(f"主线索引 index.json 已更新: version={version}, batches={len(existing_batches)}", "ok")

        # 7. 两阶段发布：拷贝 release 镜像至用户指定的 outDir (纯净发布，无 legacy 兼容文件)
        copied_files = ws.copy_release_to_out("main", self.out_p)

        # 8. 更新根 manifest.json (同时同步镜像至 ws.release_dir)
        index_hash = compute_file_sha256(index_json_path)
        rel_mod_url = "main/index.json"
        m_file = ManifestManager.update_module(
            self.out_p,
            "main",
            version,
            rel_mod_url,
            self.log,
            count=new_total_count,
            module_hash=index_hash,
            ws=ws,
        )
        if m_file:
            copied_files.append(str(m_file.resolve()))

        # 9. 记录源侧权威账本与导出流水
        try:
            ws.ledger.append_records(exported_items)
            ws.log_export(
                "export_main",
                batchId=batch_id,
                module="main",
                count=len(images),
                version=version,
                startOrder=start_order,
                endOrder=start_order + len(images) - 1,
                outDir=str(self.out_p),
            )
            self.log(f"已将 {len(exported_items)} 张图片记入源侧权威账本", "ok")
        except Exception as e:
            self.log(f"更新源侧权威账本失败: {e}", "warn")

        return ExportResult(
            success=True,
            summary=f"已成功导出 {len(images)} 个关卡至分卷 {batch_id} (version={version})",
            files=copied_files,
        )
