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
from studio.core.image_proc import (
    HAS_PIL,
    convert_images_parallel,
    make_rename,
    validate_image,
)
from studio.core.scanner import (
    build_manual_order,
    compute_file_sha256,
    scan_images,
    sort_images,
)
from studio.core.workspace import StudioWorkspace
from studio.exporters.base import (
    BaseExporter,
    ExportResult,
    assert_min_long,
    resolve_excluded,
    resolve_normalize,
    resolve_quality,
)
from studio.exporters.manifest_manager import ManifestManager


class DailyExporter(BaseExporter):
    def validate(self) -> None:
        month = (self.data.get("month") or self.data.get("YYYYMM") or "").strip()
        if not re.match(r"^\d{6}$", month):
            raise ValueError(
                f"月份格式必须为 6 位数字 YYYYMM，例如 202609，当前为: {month}"
            )
        if not self.src_p.exists() or not self.src_p.is_dir():
            raise ValueError(f"源目录不存在: {self.src_p}")

    def execute(self) -> ExportResult:
        month = (self.data.get("month") or self.data.get("YYYYMM") or "").strip()
        ws = StudioWorkspace(self.src_p, read_only=self.is_trial)
        ledger = ExportsLedger(self.src_p, read_only=self.is_trial)
        build_root = self._write_root(ws)

        selected_paths = self.data.get("selectedPaths")
        if (
            selected_paths
            and isinstance(selected_paths, list)
            and len(selected_paths) > 0
        ):
            selected_set = {
                str(p).replace("\\", "/").strip().lower() for p in selected_paths
            }
            images = [
                p
                for p in scan_images(self.src_p)
                if p.relative_to(self.src_p).as_posix().lower() in selected_set
            ]
            self.log(
                f"已按指定范围载入 {len(images)} 张待打包图片，目标月份: {month}",
                "info",
            )
        else:
            images = scan_images(self.src_p)
            self.log(f"扫描源目录获得 {len(images)} 张图片，目标月份: {month}", "info")

        # 剔除第②步 ✕ 移除的图片（预览与导出必须同口径）
        excluded = resolve_excluded(self.data)
        if excluded:
            before = len(images)
            images = [
                p
                for p in images
                if p.relative_to(self.src_p).as_posix().lower() not in excluded
            ]
            self.log(
                f"已剔除 {before - len(images)} 张在第②步手动移除的图片，剩余 {len(images)} 张",
                "info",
            )
            if not images:
                raise ValueError("所有图片均已被手动剔除，无可打包内容")

        if not images:
            raise ValueError("源目录中没有找到可打包的图片文件")

        # 0. 排序：确定打包/分配日期的顺序
        sort_by = (self.data.get("sortBy") or "name_asc").strip().lower()
        manual_order = build_manual_order(
            self.src_p, self.data.get("manualOrder") or selected_paths
        )
        images = sort_images(images, sort_by, manual_order=manual_order)
        self.log(f"已按排序策略 [{sort_by}] 排定 {len(images)} 张图片顺序", "info")

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

            logical_id = (
                f"daily:{arc_name[:8]}"
                if re.match(r"^\d{8}", arc_name)
                else f"daily:{month}_{idx:02d}"
            )

            rel = p.relative_to(self.src_p).as_posix().replace("\\", "/")
            h = compute_file_sha256(p).strip().lower()
            if h:
                seen_hashes.setdefault(h, []).append(rel)

            target_items.append((p, arc_name, logical_id, h))

        dup_groups = {h: paths for h, paths in seen_hashes.items() if len(paths) >= 2}
        if dup_groups:
            self.log(
                f"导出已被安全中止: 待导出图片列表中发现 {len(dup_groups)} 组内容完全相同的重复文件！",
                "err",
            )
            detail_lines = [
                f"  • 重复组 [Hash: {h[:12]}...]: {', '.join(paths)}"
                for h, paths in dup_groups.items()
            ]
            raise ValueError(
                f"待导出图片列表中存在 {len(dup_groups)} 组内容完全相同的重复图片，导出已被安全拦截！\n"
                f"每日挑战必须保持日历天数完整，请先在素材库中清理或替换重复文件后再执行导出。\n"
                + "\n".join(detail_lines)
            )

        # 0a. 规格化：长边 <2160 阻断（仅在规格化激活时生效，向后兼容旧调用）
        normalize_spec = resolve_normalize(self.data)
        if normalize_spec:
            assert_min_long(images, self.log)
            self.log(
                f"规格化开启: 长边={normalize_spec['long_target']}px, 比例族={normalize_spec['target_ratios']}, "
                f"裁切={normalize_spec['crop_mode']}, 去背景={'开' if normalize_spec['trim_background'] else '关'}",
                "info",
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

        # 3. 两阶段发布：写构建根 (正式 ws.release_dir/daily，试导出 _trial_{ts}/daily)
        src_daily_dir = ws.release_dir / "daily"
        write_daily_dir = build_root / "daily"
        zips_dir = write_daily_dir / "zips"
        zips_dir.mkdir(parents=True, exist_ok=True)
        # 读取现有 daily/index.json 以检测是否同月重复导出 (统一规范容器键 items) —— 从 release 状态源读
        src_index_path = src_daily_dir / "index.json"
        index_json_path = write_daily_dir / "index.json"
        existing_months: list[dict[str, Any]] = []
        existing_version = 0
        if src_index_path.exists():
            try:
                loaded = json.loads(src_index_path.read_text(encoding="utf-8"))
            except Exception as e:
                # index.json 损坏时严禁静默清零：会丢掉已有月份条目并导致
                # 同月重导时 revision 判断错乱。fail-fast。
                raise RuntimeError(
                    f"daily/index.json 已存在但无法解析（{src_index_path}）: {e}\n"
                    f"为避免丢失历史条目与版本错乱，导出已中止。"
                    f"请先修复或从导出账本恢复该文件后重试。"
                ) from e
            if isinstance(loaded, dict):
                existing_months = loaded.get("items", [])
                existing_version = int(loaded.get("version", 0))
            else:
                raise RuntimeError(
                    f"daily/index.json 内容不是合法的对象（{src_index_path}），导出已中止。"
                    f"请先修复或从导出账本恢复该文件后重试。"
                )

        prev_month = next(
            (
                m
                for m in existing_months
                if isinstance(m, dict) and m.get("month") == month
            ),
            None,
        )

        # 预打包 ZIP 至临时文件以计算内容哈希 (图片并行转码，顺序写 zip 保持确定性)
        tmp_zip = Path(tempfile.gettempdir()) / f"_daily_{month}_tmp.zip"
        zip_quality = resolve_quality(self.data)
        self.log(
            f"开始转码 {len(target_items)} 张图片 → {self.fmt} (quality={zip_quality}) ...",
            "info",
        )

        zip_entries: list[
            tuple[Path, Path | None, str]
        ] = []  # (src, tmp_f|None, arc_name)
        zip_tasks: list[dict[str, Any]] = []
        manual_boxes = self.data.get("manual_boxes") or {}
        for idx, (p, arc_name, logical_id, file_hash) in enumerate(
            target_items, start=1
        ):
            if self.fmt != "original" and HAS_PIL:
                tmp_conv = (
                    Path(tempfile.gettempdir()) / f"_daily_{month}_{idx:03d}_{arc_name}"
                )
                zip_entries.append((p, tmp_conv, arc_name))
                zip_tasks.append(
                    {
                        "src": str(p),
                        "dst": str(tmp_conv),
                        "label": arc_name,  # 进度日志展示用（避免暴露临时文件名）
                        "fmt": self.fmt,
                        "quality": zip_quality,
                        "need_src_hash": False,
                        "need_dst_hash": False,
                        **(
                            {
                                "normalize": {
                                    **normalize_spec,
                                    **(
                                        {"manual_box_pct": manual_boxes[file_hash]}
                                        if normalize_spec
                                        and file_hash
                                        and file_hash in manual_boxes
                                        else {}
                                    ),
                                }
                            }
                            if normalize_spec
                            else {}
                        ),
                    }
                )
            else:
                zip_entries.append((p, None, arc_name))
        zip_results = convert_images_parallel(
            zip_tasks, on_progress=self.report_progress
        )

        with zipfile.ZipFile(tmp_zip, "w", zipfile.ZIP_DEFLATED) as zf:
            res_i = 0
            convert_failures: list[str] = []
            for p, tmp_conv, arc_name in zip_entries:
                if tmp_conv is not None:
                    ok = (
                        bool(zip_results[res_i].get("ok"))
                        if res_i < len(zip_results)
                        else False
                    )
                    res_i += 1
                    if ok and tmp_conv.exists():
                        zf.write(tmp_conv, arcname=arc_name)
                        tmp_conv.unlink(missing_ok=True)
                        continue
                    # 转码失败严禁静默回退写入未转码原图：客户端会拿到体积/尺寸/
                    # 格式不合规的图片且无任何报错。fail-fast 中止整批导出。
                    convert_failures.append(f"{p.name} → {arc_name}")
                    continue
                zf.write(p, arcname=arc_name)
        if convert_failures:
            tmp_zip.unlink(missing_ok=True)
            detail_lines = [f"  • {line}" for line in convert_failures]
            raise RuntimeError(
                f"{len(convert_failures)} 张图片转码失败，ZIP 导出已中止（未写入索引/账本，可排除问题素材后重试）:\n"
                + "\n".join(detail_lines)
            )

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
        self.log(
            f"ZIP 归档生成完成: {zip_path.name} ({zip_size:,} bytes, hash: {zip_hash[:8]}...)",
            "ok",
        )

        exported_items: list[dict[str, Any]] = []
        # 规格化元数据按源路径归档（zip 转码任务结果对齐 source 路径）
        norm_map: dict[str, dict[str, Any]] = {}
        for t, r in zip(zip_tasks, zip_results):
            if r.get("normalize"):
                norm_map[str(Path(t["src"]).resolve())] = r["normalize"]
        for p, arc_name, logical_id, file_hash in target_items:
            entry: dict[str, Any] = {
                "sourceHash": file_hash,
                "sourcePath": p.relative_to(self.src_p).as_posix().replace("\\", "/"),
                "sourceSize": p.stat().st_size if p.exists() else 0,
                "module": "daily",
                "logicalId": logical_id,
                "targetFile": f"daily/zips/{zip_file_name}#{arc_name}",
                "month": month,
                "revision": rev,
            }
            norm = norm_map.get(str(p.resolve()))
            if norm:
                entry["normalize"] = norm
            exported_items.append(entry)

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

        new_version = (
            existing_version + 1 if existing_version > 0 else len(existing_months)
        )
        index_payload = {
            "module": "daily",
            "version": new_version,
            "currentMonth": month,
            "updatedAt": now_str,
            "items": existing_months,
        }

        tmp_idx = index_json_path.with_suffix(".tmp")
        tmp_idx.write_text(
            json.dumps(index_payload, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        tmp_idx.replace(index_json_path)
        self.log(
            f"daily/index.json 写入成功 (version={new_version}, count={len(images)})",
            "ok",
        )

        # 4. 记录权威账本与导出流水 (仅正式导出) —— 先记账后交付：release 镜像完成后立即落账
        if self._commit():
            try:
                ledger.append_records(exported_items)
                ws.log_export(
                    "export_daily",
                    scope="daily",
                    entity=month,
                    after={
                        "count": len(images),
                        "version": new_version,
                        "zipSize": zip_size,
                        "zipHash": zip_hash,
                        "outDir": str(self.out_p),
                    },
                    result="ok",
                )
                self.log(f"已将 {len(exported_items)} 张图片记入源侧权威账本", "ok")
            except Exception as e:
                # 账本是防重复发布的唯一权威，写失败时严禁继续交付，
                # 否则该月日历包会绕过防重账本被重复发布。
                # index.json 已写但 outDir 未交付，账本幂等，直接重试即可续跑。
                self.log(f"更新权威账本失败，导出中止（未交付至输出目录，可直接重试）: {e}", "err")
                raise RuntimeError(f"权威账本写入失败，导出已中止: {e}") from e

        # 5. 两阶段发布：正式导出才拷贝 release 镜像至 outDir；试导出时转录已直接写入构建根
        copied_files: list[str] = []
        if self._commit():
            copied_files = ws.copy_release_to_out("daily", self.out_p)
        else:
            copied_files = [
                str(p.resolve()) for p in build_root.rglob("*") if p.is_file()
            ]

        # 6. 更新 manifest.json (试导出只写构建根内快照，传 ws=None 掐断 release 镜像)
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
            ws=None if self.is_trial else ws,
        )
        if m_file:
            copied_files.append(str(m_file.resolve()))

        # 7a. 试导出元数据包
        if self.is_trial:
            source_map: dict[str, Any] = {}
            for p, arc_name, logical_id, file_hash in target_items:
                entry = {
                    "sourceHash": file_hash,
                    "sourceSize": p.stat().st_size if p.exists() else 0,
                    "targetFile": f"daily/zips/{zip_file_name}#{arc_name}",
                    "logicalId": logical_id,
                    "month": month,
                    "revision": rev,
                    "fmt": self.fmt,
                    "quality": zip_quality,
                    "rename": self.rename_rule,
                }
                norm = norm_map.get(str(p.resolve()))
                if norm:
                    entry["normalize"] = norm
                source_map[p.relative_to(self.src_p).as_posix().replace("\\", "/")] = (
                    entry
                )
            self._write_trial_meta(source_map, exported_items, logs=[])

        if self.is_trial:
            self._would_commit = {
                "module": "daily",
                "month": month,
                "count": len(images),
                "version": new_version,
                "zipUrl": f"zips/{zip_file_name}",
            }
            summary = f"[试导出] 未提交 daily 月份 {month}（{len(images)} 张）[正式将写 version={new_version}]"
        else:
            summary = f"已成功打包 {len(images)} 张图片至 {month}.zip 并更新 daily 模块"

        return ExportResult(
            success=True,
            summary=summary,
            files=copied_files,
        )
