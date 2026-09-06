#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.exporters.daily_exporter — 日历关卡导出器 (daily/index.json + zips/YYYYMM.zip + 权威账本)
"""

from __future__ import annotations

import datetime as dt
import json
from pathlib import Path
import re
import tempfile
from typing import Any
import zipfile

from studio.core.exports_ledger import ExportsLedger
from studio.core.image_proc import HAS_PIL, convert_image, make_rename, validate_image
from studio.core.scanner import compute_file_sha256, scan_images
from studio.core.workspace import StudioWorkspace
from studio.exporters.base import BaseExporter, ExportResult
from studio.exporters.manifest_manager import ManifestManager


class DailyExporter(BaseExporter):
    def validate(self) -> None:
        month = (self.data.get("month") or self.data.get("YYYYMM") or "").strip()
        if not re.match(r"^\d{6}$", month):
            raise ValueError(f"月份格式必须为 6 位数字 YYYYMM，例如 202609，当前为: {month}")
        if not self.src_p.exists() or not self.src_p.is_dir():
            raise ValueError(f"源目录不存在: {self.src_p}")

    def execute(self) -> ExportResult:
        month = (self.data.get("month") or self.data.get("YYYYMM") or "").strip()
        ws = StudioWorkspace(self.src_p)
        ledger = ExportsLedger(self.src_p)

        selected_paths = self.data.get("selectedPaths")
        if selected_paths and isinstance(selected_paths, list) and len(selected_paths) > 0:
            selected_set = {str(p).replace("\\", "/").strip().lower() for p in selected_paths}
            images = [
                p for p in scan_images(self.src_p)
                if p.relative_to(self.src_p).as_posix().lower() in selected_set
            ]
            self.log(f"已按指定范围载入 {len(images)} 张待打包图片，目标月份: {month}", "info")
        else:
            images = scan_images(self.src_p)
            self.log(f"扫描源目录获得 {len(images)} 张图片，目标月份: {month}", "info")

        if not images:
            raise ValueError("源目录中没有找到可打包的图片文件")

        # 1. 图片格式与完整性校验 + 重复图片校验拦截
        seen_hashes: dict[str, list[str]] = {}
        target_items: list[tuple[Path, str, str, str]] = []
        for idx, p in enumerate(images, start=1):
            valid, err_msg = validate_image(p)
            if not valid:
                self.log(f"导出中止: 待导出图片损坏或无效: {p.name} ({err_msg})", "err")
                raise ValueError(f"待导出图片损坏或无效: {p.name} ({err_msg})")

            # 已经是标准日期命名的图片优先保留
            if re.match(r"^\d{8}\.", p.name) and self.rename_rule != "sequence":
                arc_name = p.name
                if self.fmt != "original":
                    arc_name = f"{Path(p.name).stem}.{self.fmt}"
            else:
                arc_name = make_rename(p.name, idx, self.rename_rule, self.fmt, month)

            logical_id = f"daily:{arc_name[:8]}" if re.match(r"^\d{8}", arc_name) else f"daily:{month}_{idx:02d}"

            rel = p.relative_to(self.src_p).as_posix().replace("\\", "/")
            h = compute_file_sha256(p).strip().lower()
            if h:
                seen_hashes.setdefault(h, []).append(rel)

            target_items.append((p, arc_name, logical_id, h))

        dup_groups = {h: paths for h, paths in seen_hashes.items() if len(paths) >= 2}
        if dup_groups:
            self.log(f"导出已被安全中止: 待导出图片列表中发现 {len(dup_groups)} 组内容完全相同的重复文件！", "err")
            detail_lines = [f"  • 重复组 [Hash: {h[:12]}...]: {', '.join(paths)}" for h, paths in dup_groups.items()]
            raise ValueError(
                f"待导出图片列表中存在 {len(dup_groups)} 组内容完全相同的重复图片，导出已被安全拦截！\n"
                f"每日挑战必须保持日历天数完整，请先在素材库中清理或替换重复文件后再执行导出。\n"
                + "\n".join(detail_lines)
            )

        # 2. 历史查重与跨模块预警 (对齐 logical_id 到日级)
        for p, arc_name, logical_id, h in target_items:
            conflict, msg, sev = ledger.check_history_duplicate(
                h,
                module="daily",
                logical_id=logical_id,
            )
            if conflict:
                if sev == "error":
                    self.log(f"导出中止: {msg} (文件: {p.name})", "err")
                    raise ValueError(f"导出已被拦截: {msg}")
                elif sev == "warning":
                    self.log(f"注意: {msg} (文件: {p.name})", "warn")

        # 3. 两阶段发布：输出目录拓扑 (.studio/release/daily)
        release_daily_dir = ws.release_dir / "daily"
        zips_dir = release_daily_dir / "zips"
        zips_dir.mkdir(parents=True, exist_ok=True)
        # 读取现有 daily/index.json 以检测是否同月重复导出 (统一规范容器键 items)
        index_json_path = release_daily_dir / "index.json"
        existing_months: list[dict[str, Any]] = []
        existing_version = 0
        if index_json_path.exists():
            try:
                loaded = json.loads(index_json_path.read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    existing_months = loaded.get("items", [])
                    existing_version = int(loaded.get("version", 0))
            except Exception:
                existing_months = []

        prev_month = next((m for m in existing_months if isinstance(m, dict) and m.get("month") == month), None)

        # 预打包 ZIP 至临时文件以计算内容哈希
        tmp_zip = Path(tempfile.gettempdir()) / f"_daily_{month}_tmp.zip"
        with zipfile.ZipFile(tmp_zip, "w", zipfile.ZIP_DEFLATED) as zf:
            for p, arc_name, logical_id, file_hash in target_items:
                if self.fmt != "original" and HAS_PIL:
                    tmp_conv = Path(tempfile.gettempdir()) / f"_daily_{arc_name}"
                    ok, _ = convert_image(p, tmp_conv, self.fmt)
                    if ok:
                        zf.write(tmp_conv, arcname=arc_name)
                        tmp_conv.unlink(missing_ok=True)
                        continue
                zf.write(p, arcname=arc_name)

        zip_size = tmp_zip.stat().st_size
        zip_hash = compute_file_sha256(tmp_zip)

        # CDN 不可变缓存防冲突：若重导且内容哈希变化则使用带 revision 的文件名
        rev = 1
        if prev_month:
            prev_hash = prev_month.get("zipSha256")
            prev_rev = int(prev_month.get("revision", 1) or 1)
            if prev_hash and prev_hash != zip_hash:
                rev = prev_rev + 1
            else:
                rev = prev_rev

        zip_file_name = f"{month}-r{rev}.zip" if rev > 1 else f"{month}.zip"
        zip_path = zips_dir / zip_file_name
        tmp_zip.replace(zip_path)
        self.log(f"ZIP 归档生成完成: {zip_path.name} ({zip_size:,} bytes, hash: {zip_hash[:8]}...)", "ok")

        exported_items: list[dict[str, Any]] = []
        for p, arc_name, logical_id, file_hash in target_items:
            exported_items.append({
                "sourceHash": file_hash,
                "sourcePath": p.relative_to(self.src_p).as_posix().replace("\\", "/"),
                "sourceSize": p.stat().st_size if p.exists() else 0,
                "module": "daily",
                "logicalId": logical_id,
                "targetFile": f"daily/zips/{zip_file_name}#{arc_name}",
                "month": month,
                "revision": rev,
            })

        now_str = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
        month_entry = {
            "month": month,
            "totalCount": len(images),
            "zipUrl": f"zips/{zip_file_name}",
            "fileSizeBytes": zip_size,
            "zipSha256": zip_hash,
            "revision": rev,
            "updatedAt": now_str,
        }

        # 查找替换或插入顶部
        found = False
        for i, m in enumerate(existing_months):
            if isinstance(m, dict) and m.get("month") == month:
                existing_months[i] = month_entry
                found = True
                break
        if not found:
            existing_months.insert(0, month_entry)

        new_version = existing_version + 1 if existing_version > 0 else len(existing_months)
        index_payload = {
            "module": "daily",
            "version": new_version,
            "currentMonth": month,
            "updatedAt": now_str,
            "items": existing_months,
        }

        tmp_idx = index_json_path.with_suffix(".tmp")
        tmp_idx.write_text(json.dumps(index_payload, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp_idx.replace(index_json_path)
        self.log(f"daily/index.json 写入成功 (version={new_version}, count={len(images)})", "ok")

        # 5. 两阶段发布：拷贝 release 目录文件至 outDir (纯净发布，无 legacy 兼容文件)
        copied_files = ws.copy_release_to_out("daily", self.out_p)

        # 6. 更新 manifest.json (同时镜像到 ws.release_dir)
        index_hash = compute_file_sha256(index_json_path)
        rel_mod_url = "daily/index.json"
        m_file = ManifestManager.update_module(
            self.out_p,
            "daily",
            new_version,
            rel_mod_url,
            self.log,
            count=len(images),
            module_hash=index_hash,
            extra_fields={"currentMonth": month},
            ws=ws,
        )
        if m_file:
            copied_files.append(str(m_file.resolve()))

        # 7. 记录权威账本与导出流水
        try:
            ledger.append_records(exported_items)
            ws.log_export(
                "export_daily",
                month=month,
                module="daily",
                count=len(images),
                version=new_version,
                zipSize=zip_size,
                zipHash=zip_hash,
                outDir=str(self.out_p),
            )
            self.log(f"已将 {len(exported_items)} 张图片记入源侧权威账本", "ok")
        except Exception as e:
            self.log(f"更新权威账本失败: {e}", "warn")

        return ExportResult(
            success=True,
            summary=f"已成功打包 {len(images)} 张图片至 {month}.zip 并更新 daily 模块",
            files=copied_files,
        )
