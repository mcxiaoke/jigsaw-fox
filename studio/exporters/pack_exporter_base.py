#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.exporters.pack_exporter_base — Events 与 Collections 共享打包导出基类
纯净输出: index.json (items 数组) + packs/ + covers/，无 legacy 兼容包袱。
"""

from __future__ import annotations

from abc import abstractmethod
import datetime as dt
import json
from pathlib import Path
from typing import Any, Callable
import zipfile

from studio.core.exports_ledger import ExportsLedger
from studio.core.image_proc import (
    HAS_PIL,
    convert_images_parallel,
    convert_image,
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


class PackExporterBase(BaseExporter):
    """Events 与 Collections 模块共享的纯净 ZIP 归档与两阶段发布引擎"""

    module: str = ""  # 由子类定义: "events" 或 "collections"
    id_field: str = ""  # 由子类定义: "eventId" 或 "collectionId"

    def validate(self) -> None:
        pack_id = (self.data.get("id") or self.data.get(self.id_field) or "").strip()
        if not pack_id:
            raise ValueError(f"必须指定唯一标识 ID (id 或 {self.id_field})")
        title = (self.data.get("title") or "").strip()
        if not title:
            raise ValueError("必须填写标题 (title)")
        if not self.src_p.exists() or not self.src_p.is_dir():
            raise ValueError(f"源目录不存在: {self.src_p}")

    @abstractmethod
    def build_item_extra(self) -> dict[str, Any]:
        """子类扩展元数据字段 (如 startTime, unlockCoins, category 等)"""
        pass

    def execute(self) -> ExportResult:
        pack_id = (self.data.get("id") or self.data.get(self.id_field) or "").strip()
        title = (self.data.get("title") or "").strip() or pack_id
        desc = (self.data.get("description") or self.data.get("desc") or "").strip()
        title_zh = (self.data.get("titleZh") or "").strip()
        desc_zh = (self.data.get("descZh") or "").strip()
        status = self.data.get("status", "active")
        display_order = int(self.data.get("displayOrder", 1))

        ws = StudioWorkspace(self.src_p, read_only=self.is_trial)
        ledger = ExportsLedger(self.src_p, read_only=self.is_trial)
        build_root = self._write_root(ws)

        # 1. 扫描与选图过滤
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
                f"已按指定范围载入 {len(images)} 张待打包图片，目标 ID: {pack_id}",
                "info",
            )
        else:
            images = scan_images(self.src_p)
            self.log(f"扫描源目录获得 {len(images)} 张图片，目标 ID: {pack_id}", "info")

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
                raise ValueError("所有图片均已被手动剔除，无可导出内容")

        if not images:
            raise ValueError("源目录中没有找到可导出的图片文件")

        # 0. 排序：确定打包内序号顺序 (确定性)
        sort_by = (self.data.get("sortBy") or "name_asc").strip().lower()
        manual_order = build_manual_order(
            self.src_p, self.data.get("manualOrder") or selected_paths
        )
        images = sort_images(images, sort_by, manual_order=manual_order)
        self.log(f"已按排序策略 [{sort_by}] 排定 {len(images)} 张图片顺序", "info")

        # 2. 物理完整性与格式损坏校验 (3-p2-1)
        for p in images:
            is_valid, err_msg = validate_image(p)
            if not is_valid:
                rel_p = p.relative_to(self.src_p).as_posix()
                self.log(f"导出中止: 图片损坏或格式无效: {rel_p} ({err_msg})", "err")
                raise ValueError(
                    f"待导出图片中存在损坏或格式无效的文件: {rel_p} ({err_msg})"
                )

        # 2a. 规格化：长边 <2160 阻断（仅在规格化激活时生效，向后兼容旧调用）
        normalize_spec = resolve_normalize(self.data)
        if normalize_spec:
            assert_min_long(images, self.log)
            self.log(
                f"规格化开启: 长边={normalize_spec['long_target']}px, 比例族={normalize_spec['target_ratios']}, "
                f"裁切={normalize_spec['crop_mode']}, 去背景={'开' if normalize_spec['trim_background'] else '关'}",
                "info",
            )

        # 3. 排除已导出图片 (excludeExported)
        if self.data.get("excludeExported"):
            exported_hashes = ledger.get_exported_hashes()
            if exported_hashes:
                filtered_images = []
                excluded_cnt = 0
                for p in images:
                    h = compute_file_sha256(p).strip().lower()
                    if h in exported_hashes:
                        excluded_cnt += 1
                    else:
                        filtered_images.append(p)
                if excluded_cnt > 0:
                    self.log(
                        f"已自动排除 {excluded_cnt} 张已导出的历史图片，剩余 {len(filtered_images)} 张待打包",
                        "info",
                    )
                images = filtered_images
                if not images:
                    raise ValueError(
                        "所选范围内的图片均已在历史批次中导出，无新图片可供导出"
                    )

        # 4. 查重拦截：严禁同批次内部重复
        seen_hashes: dict[str, list[str]] = {}
        pack_hash_map: dict[str, str] = {}  # rel_path -> hash, 供 manual_box 查找
        for p in images:
            rel = p.relative_to(self.src_p).as_posix().replace("\\", "/")
            h = compute_file_sha256(p).strip().lower()
            pack_hash_map[rel] = h
            if h:
                seen_hashes.setdefault(h, []).append(rel)

        dup_groups = {h: paths for h, paths in seen_hashes.items() if len(paths) >= 2}
        if dup_groups:
            self.log(
                f"导出已被安全中止: 待导出列表中发现 {len(dup_groups)} 组完全相同的重复图片！",
                "err",
            )
            detail_lines = [
                f"  • 重复组 [Hash: {h[:12]}...]: {', '.join(paths)}"
                for h, paths in dup_groups.items()
            ]
            raise ValueError(
                f"待导出图片列表中存在 {len(dup_groups)} 组内容完全相同的重复图片，导出已被安全拦截！\n"
                + "\n".join(detail_lines)
            )

        # 5. 历史查重与跨模块预警 (细化至每个图片的 logicalId: module:pack_id:filename)
        for p in images:
            h = compute_file_sha256(p).strip().lower()
            conflict, msg, sev = ledger.check_history_duplicate(
                h,
                module=self.module,
                logical_id=f"{self.module}:{pack_id}:{p.name}",
            )
            if conflict:
                if sev == "error":
                    self.log(f"导出中止: {msg} (文件: {p.name})", "err")
                    raise ValueError(f"导出已被拦截: {msg}")
                elif sev == "warning":
                    self.log(f"注意: {msg} (文件: {p.name})", "warn")

        # 6. 构建输出目录拓扑 (写构建根：正式 ws.release_dir/{module}，试导出 _trial_{ts}/{module})
        src_mod_dir = ws.release_dir / self.module
        write_mod_dir = build_root / self.module
        packs_dir = write_mod_dir / "packs"
        covers_dir = write_mod_dir / "covers"
        packs_dir.mkdir(parents=True, exist_ok=True)
        covers_dir.mkdir(parents=True, exist_ok=True)

        # 读取现有 index.json 以检测是否同名重复导出 —— 从 release 状态源读
        src_index_path = src_mod_dir / "index.json"
        index_json_path = write_mod_dir / "index.json"
        existing_items: list[dict[str, Any]] = []
        existing_version = 0
        if src_index_path.exists():
            try:
                loaded = json.loads(src_index_path.read_text(encoding="utf-8"))
            except Exception as e:
                # index.json 损坏时严禁静默清零：会丢掉已有 pack 条目并导致
                # revision 判断错乱（重导可能覆盖历史 -rN 文件）。fail-fast。
                raise RuntimeError(
                    f"{self.module}/index.json 已存在但无法解析（{src_index_path}）: {e}\n"
                    f"为避免丢失历史条目与版本错乱，导出已中止。"
                    f"请先修复或从导出账本恢复该文件后重试。"
                ) from e
            if isinstance(loaded, dict):
                existing_items = loaded.get("items", [])
                existing_version = int(loaded.get("version", 0))
            else:
                raise RuntimeError(
                    f"{self.module}/index.json 内容不是合法的对象（{src_index_path}），导出已中止。"
                    f"请先修复或从导出账本恢复该文件后重试。"
                )

        prev_item = next(
            (
                it
                for it in existing_items
                if isinstance(it, dict) and it.get("id") == pack_id
            ),
            None,
        )

        # 预打包 ZIP 到临时文件以确定内容哈希 (图片并行转码，再顺序写 zip 保持确定性)
        # 临时文件必须与最终目标同卷：Path.replace() 在 Windows 上跨盘移动会抛
        # WinError 17 (OSError)，因此建在目标 packs_dir 内而非系统 Temp 目录。
        tmp_zip = packs_dir / f"_{self.module}_{pack_id}_tmp.zip"
        zip_quality = resolve_quality(self.data)
        self.log(
            f"开始转码 {len(images)} 张图片 → {self.fmt} (quality={zip_quality}) ...",
            "info",
        )

        zip_entries: list[
            tuple[Path, Path | None, str]
        ] = []  # (src, tmp_f|None, arc_name)
        zip_tasks: list[dict[str, Any]] = []
        manual_boxes = self.data.get("manual_boxes") or {}
        for idx, p in enumerate(images, start=1):
            arc_name = make_rename(p.name, idx, self.rename_rule, self.fmt)
            rel_p = p.relative_to(self.src_p).as_posix().replace("\\", "/")
            img_hash = pack_hash_map.get(rel_p, "")
            if self.fmt != "original" and HAS_PIL:
                # 转码中间文件同样落在 packs_dir（与 tmp_zip 同卷，失败时统一清理）
                tmp_f = packs_dir / f"_{self.module}_{pack_id}_{idx}_{arc_name}"
                zip_entries.append((p, tmp_f, arc_name))
                zip_tasks.append(
                    {
                        "src": str(p),
                        "dst": str(tmp_f),
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
                                        {"manual_box_pct": manual_boxes[img_hash]}
                                        if normalize_spec
                                        and img_hash
                                        and img_hash in manual_boxes
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
            for p, tmp_f, arc_name in zip_entries:
                if tmp_f is not None:
                    ok = (
                        bool(zip_results[res_i].get("ok"))
                        if res_i < len(zip_results)
                        else False
                    )
                    res_i += 1
                    if ok and tmp_f.exists():
                        zf.write(tmp_f, arcname=arc_name)
                        tmp_f.unlink(missing_ok=True)
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

        # CDN 不可变缓存防冲突：若重导且哈希变化则使用带 revision 的文件名
        rev = 1
        if prev_item:
            prev_hash = prev_item.get("zipSha256")
            prev_rev = int(prev_item.get("revision", 1) or 1)
            if prev_hash and prev_hash != zip_hash:
                rev = prev_rev + 1
            else:
                rev = prev_rev

        if rev > 1:
            zip_file_name = f"{pack_id}-r{rev}.zip"
            cover_file_name = f"{pack_id}-r{rev}.webp"
        else:
            zip_file_name = f"{pack_id}.zip"
            cover_file_name = f"{pack_id}.webp"

        zip_rel_url = f"packs/{zip_file_name}"
        cover_rel_url = f"covers/{cover_file_name}"
        zip_path = packs_dir / zip_file_name
        cover_path = covers_dir / cover_file_name

        tmp_zip.replace(zip_path)
        self.log(
            f"ZIP 归档生成完毕: {zip_path.name} ({zip_size:,} bytes, hash: {zip_hash[:8]}...)",
            "ok",
        )

        exported_items: list[dict[str, Any]] = []
        now_str = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")

        # 规格化元数据按源路径归档（zip 转码任务结果对齐 source 路径）
        norm_map: dict[str, dict[str, Any]] = {}
        for t, r in zip(zip_tasks, zip_results):
            if r.get("normalize"):
                norm_map[str(Path(t["src"]).resolve())] = r["normalize"]

        for idx, p in enumerate(images, start=1):
            arc_name = make_rename(p.name, idx, self.rename_rule, self.fmt)
            file_hash = compute_file_sha256(p)
            entry: dict[str, Any] = {
                "sourceHash": file_hash,
                "sourcePath": p.relative_to(self.src_p).as_posix().replace("\\", "/"),
                "sourceSize": p.stat().st_size if p.exists() else 0,
                "module": self.module,
                "logicalId": f"{self.module}:{pack_id}:{p.name}",
                "packId": pack_id,
                "targetFile": f"{self.module}/packs/{zip_file_name}#{arc_name}",
                "revision": rev,
            }
            norm = norm_map.get(str(p.resolve()))
            if norm:
                entry["normalize"] = norm
            exported_items.append(entry)

        # 生成封面图并双重校验完整性
        ok_cov, err_cov = convert_image(
            images[0], cover_path, "webp", quality=zip_quality
        )
        if not ok_cov:
            self.log(f"封面生成失败: {err_cov}", "err")
            raise ValueError(f"封面图生成失败 ({images[0].name}): {err_cov}")
        ok_val, err_val = validate_image(cover_path)
        if not ok_val:
            self.log(f"封面校验未通过: {err_val}", "err")
            raise ValueError(f"封面图校验未通过 ({cover_path.name}): {err_val}")
        self.log(f"封面生成完毕: {cover_path.name}", "ok")

        # 7. 更新模块总索引 index.json (统一数组容器键 items，无 legacy 兼容冗余)
        item_entry: dict[str, Any] = {
            "id": pack_id,
            "type": "zip",
            "title": title,
            "desc": desc,
            "status": status,
            "displayOrder": display_order,
            "coverUrl": cover_rel_url,
            "zipUrl": zip_rel_url,
            "fileSizeBytes": zip_size,
            "zipSha256": zip_hash,
            "totalCount": len(images),
            "revision": rev,
            "createdAt": now_str,
            "updatedAt": now_str,
            **self.build_item_extra(),
        }
        if title_zh:
            item_entry["titleZh"] = title_zh
        if desc_zh:
            item_entry["descZh"] = desc_zh

        # 查找替换或追加（替换时保留首次 createdAt）
        found = False
        for i, it in enumerate(existing_items):
            if isinstance(it, dict) and it.get("id") == pack_id:
                old_created = it.get("createdAt")
                if old_created:
                    item_entry["createdAt"] = old_created
                existing_items[i] = item_entry
                found = True
                break
        if not found:
            existing_items.append(item_entry)

        new_version = (
            existing_version + 1 if existing_version > 0 else len(existing_items)
        )
        index_payload = {
            "module": self.module,
            "version": new_version,
            "updatedAt": now_str,
            "items": existing_items,
        }

        tmp_idx = index_json_path.with_suffix(".tmp")
        tmp_idx.write_text(
            json.dumps(index_payload, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        tmp_idx.replace(index_json_path)
        self.log(
            f"{self.module}/index.json 写入成功 (version={new_version}, items={len(existing_items)})",
            "ok",
        )

        # 8. 记录权威账本与导出流水 (仅正式导出) —— 先记账后交付：release 镜像完成后立即落账
        if self._commit():
            try:
                ledger.append_records(exported_items)
                ws.log_export(
                    f"export_{self.module}",
                    scope=self.module,
                    entity=pack_id,
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
                # 否则该 pack 内容会绕过防重账本被重复发布。
                # index.json 已写但 outDir 未交付，账本幂等，直接重试即可续跑。
                self.log(f"更新权威账本失败，导出中止（未交付至输出目录，可直接重试）: {e}", "err")
                raise RuntimeError(f"权威账本写入失败，导出已中止: {e}") from e

        # 9. 两阶段发布：正式导出才拷贝 release 镜像至 outDir；试导出时转录已直接写入构建根
        copied_files: list[str] = []
        if self._commit():
            copied_files = ws.copy_release_to_out(self.module, self.out_p)
        else:
            copied_files = [
                str(p.resolve()) for p in build_root.rglob("*") if p.is_file()
            ]

        # 9. 更新根 manifest.json (试导出只写构建根内快照，传 ws=None 掐断 release 镜像)
        index_hash = compute_file_sha256(index_json_path)
        rel_mod_url = f"{self.module}/index.json"
        manifest_file = ManifestManager.update_module(
            self.out_p,
            self.module,
            new_version,
            rel_mod_url,
            self.log,
            count=len(existing_items),
            module_hash=index_hash,
            ws=None if self.is_trial else ws,
        )
        if manifest_file:
            copied_files.append(str(manifest_file.resolve()))

        # 11. 试导出元数据包
        if self.is_trial:
            source_map: dict[str, Any] = {}
            for it in exported_items:
                entry: dict[str, Any] = {
                    "sourceHash": it["sourceHash"],
                    "sourceSize": it["sourceSize"],
                    "targetFile": it["targetFile"],
                    "logicalId": it["logicalId"],
                    "revision": it.get("revision", 1),
                    "packId": pack_id,
                    "fmt": self.fmt,
                    "quality": zip_quality,
                    "rename": self.rename_rule,
                }
                if it.get("normalize"):
                    entry["normalize"] = it["normalize"]
                source_map[it["sourcePath"]] = entry
            self._write_trial_meta(source_map, exported_items, logs=[])

        if self.is_trial:
            self._would_commit = {
                "module": self.module,
                "packId": pack_id,
                "count": len(images),
                "version": new_version,
                "zipUrl": zip_rel_url,
            }
            summary = f"[试导出] 未提交 {self.module} 模块包 {pack_id}（{len(images)} 张）[正式将写 version={new_version}]"
        else:
            summary = f"已成功导出 {self.module} 模块包 {pack_id} (count={len(images)})"

        return ExportResult(
            success=True,
            summary=summary,
            files=copied_files,
        )
