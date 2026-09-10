#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.core.export_rollback — 导出操作回滚工具 (L1 Operation 回滚)

以账本中按 opId 聚合的"一次导出"为单位撤销记录：
- list      列出可撤销的导出操作（含 legacy 提示）
- undo      按 opId 撤销某次导出
- undo-last 撤销最近一次导出

撤销语义（L1.2 原子化，见 docs/rollback-plan-20260910.md）：
1. 撤销前自动快照 ledger 与涉及模块的 release index.json 到 .studio/ledger/backups/；
2. 先回退全部模块 release 镜像（index 回退 + 产物文件移入 .studio/ledger/backups/
   trashed-{op}/ 保留而非物理删除）；
3. 任一模块镜像回退失败 → 整体失败：从快照还原已回退模块的 index.json，
   账本不动，返回 ok: False；
4. 全部镜像回退成功 → 才执行 ledger.rollback_operation(op_id)：剔除该 op 全部
   records + 追加自包含 rollback 事件（损坏重建不复活）+ 原子保存；
   被 supersedes 的旧记录自动复活；
5. 撤销后经 workspace.log_export 追加一条 rollback_export 审计到 exports.jsonl。

命令行示例（仓库根目录执行）：
    python -m studio.core.export_rollback <srcDir> list
    python -m studio.core.export_rollback <srcDir> undo --op op_20260909_143000123 --dry-run
    python -m studio.core.export_rollback <srcDir> undo --op op_20260909_143000123 --yes
    python -m studio.core.export_rollback <srcDir> undo-last --module main --yes
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import shutil
from pathlib import Path
from typing import Any

from studio.core.exports_ledger import ExportsLedger
from studio.core.workspace import StudioWorkspace
from studio.core.exports_ledger import backup_ledger_snapshot


def list_ops(src_dir: Path | str) -> list[dict[str, Any]]:
    """列出账本中全部可撤销操作（按导出时间升序）。"""
    src = Path(src_dir).resolve()
    ledger = ExportsLedger(src, read_only=True)
    return ledger.get_ops_summary()


def _find_op(src_dir: Path, op_id: str) -> dict[str, Any] | None:
    ops = ExportsLedger(src_dir, read_only=True).get_ops_summary()
    for op in ops:
        if op.get("opId") == op_id:
            return op
    return None


def _snapshot_file(path: Path, backup_dir: Path) -> Path | None:
    """复制单文件到备份目录（带时间戳），失败返回 None。"""
    if not path.exists() or not path.is_file():
        return None
    try:
        backup_dir.mkdir(parents=True, exist_ok=True)
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        dest = backup_dir / f"{path.stem}-{stamp}{path.suffix}"
        shutil.copy2(path, dest)
        return dest
    except Exception as e:
        import logging

        logging.getLogger(__name__).warning("[rollback] 文件快照失败: %s (%s)", path, e)
        return None


def _cleanup_main_release(src_dir: Path, batch_ids: set[str], trash_dir: Path) -> dict[str, Any]:
    """
    main 模块 release 镜像投影回退（批次目录自包含组织）：
    - index.json 移除匹配 batchId 的 entry，重算 maxOrder/totalCount（version 不回退）；
    - batches/{batchId}/ 整目录移入回收站（trash_dir/main/batches/{batchId}），
      成功后物理不在 release 内；失败可整体还原。
    返回 {removedEntries, trashedFiles, indexPath, errors}。
    """
    result: dict[str, Any] = {"removedEntries": 0, "trashedFiles": [], "indexPath": None, "errors": []}
    safe_ids = {b for b in (str(x).strip() for x in batch_ids) if _safe_batch_id(b)}
    if not safe_ids:
        if batch_ids:
            result["errors"].append("batchId 含非法字符，拒绝回退")
        return result
    if not trash_dir:
        trash_dir = None
    batch_ids = safe_ids
    ws = StudioWorkspace(src_dir, read_only=True)
    index_p = ws.release_dir / "main" / "index.json"
    if index_p.exists():
        try:
            data = json.loads(index_p.read_text(encoding="utf-8"))
        except Exception as e:
            result["errors"].append(f"release/main/index.json 解析失败，跳过镜像回退: {e}")
            return result
        if isinstance(data, dict):
            items = data.get("items")
            if isinstance(items, list):
                kept = [
                    e
                    for e in items
                    if not (
                        isinstance(e, dict) and str(e.get("batchId") or "") in batch_ids
                    )
                ]
                removed = len(items) - len(kept)
                if removed:
                    end_orders = [
                        int(e.get("endOrder") or 0)
                        for e in kept
                        if isinstance(e, dict) and e.get("endOrder") is not None
                    ]
                    data["items"] = kept
                    data["maxOrder"] = max(end_orders, default=0)
                    data["totalCount"] = sum(
                        int(e.get("count") or 0)
                        for e in kept
                        if isinstance(e, dict) and not e.get("patch")
                    )
                    data["updatedAt"] = dt.datetime.now(dt.timezone.utc).isoformat().replace(
                        "+00:00", "Z"
                    )
                    try:
                        tmp_p = index_p.with_suffix(".tmp")
                        tmp_p.write_text(
                            json.dumps(data, ensure_ascii=False, indent=2),
                            encoding="utf-8",
                        )
                        tmp_p.replace(index_p)
                        result["indexPath"] = str(index_p)
                    except Exception as e:
                        result["errors"].append(f"index.json 回退写入失败: {e}")
                        return result
                    result["removedEntries"] = removed

    for bid in sorted(batch_ids):
        batch_dir = ws.release_dir / "main" / "batches" / bid
        if batch_dir.exists():
            if not trash_dir:
                result["errors"].append(f"批次目录 {bid}: 回收站不可用，跳过文件清理")
                continue
            ok, err = _move_to_trash(batch_dir, trash_dir / "main" / "batches", bid)
            if ok:
                result["trashedFiles"].append(f"main/batches/{bid}")
            else:
                result["errors"].append(f"批次目录移除失败 {bid}: {err}")
    return result


def _cleanup_daily_release(src_dir: Path, months: set[str], trash_dir: Path) -> dict[str, Any]:
    """
    daily 模块 release 镜像投影回退：
    - index.json 移除匹配 month 的 entry，currentMonth 重算（version 不回退）；
    - 被移除 entry 指向的 zips/{zip} 移入回收站（trash_dir/daily/zips/{zip}）。
    返回 {removedEntries, trashedFiles, indexPath, errors}。
    """
    result: dict[str, Any] = {"removedEntries": 0, "trashedFiles": [], "indexPath": None, "errors": []}
    if not months:
        return result
    ws = StudioWorkspace(src_dir, read_only=True)
    index_p = ws.release_dir / "daily" / "index.json"
    removed_entries: list[dict[str, Any]] = []
    if index_p.exists():
        try:
            data = json.loads(index_p.read_text(encoding="utf-8"))
        except Exception as e:
            result["errors"].append(f"release/daily/index.json 解析失败，跳过镜像回退: {e}")
            return result
        if isinstance(data, dict) and isinstance(data.get("items"), list):
            items = data["items"]
            kept = [
                e for e in items
                if not (isinstance(e, dict) and str(e.get("month") or "") in months)
            ]
            removed = len(items) - len(kept)
            if removed:
                removed_entries = [e for e in items if e not in kept]
                data["items"] = kept
                data["currentMonth"] = (
                    str(kept[-1].get("month") or "") if kept else ""
                )
                data["updatedAt"] = dt.datetime.now(dt.timezone.utc).isoformat().replace(
                    "+00:00", "Z"
                )
                try:
                    tmp_p = index_p.with_suffix(".tmp")
                    tmp_p.write_text(
                        json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8"
                    )
                    tmp_p.replace(index_p)
                    result["indexPath"] = str(index_p)
                except Exception as e:
                    result["errors"].append(f"daily index.json 回退写入失败: {e}")
                    return result
                result["removedEntries"] = removed

    for entry in removed_entries:
        zip_rel = entry.get("zipUrl")
        if not zip_rel:
            continue
        f = _safe_release_path(ws, "daily", zip_rel)
        if f is None:
            result["errors"].append(f"daily zip 路径非法，已跳过: {zip_rel}")
            continue
        if f.exists():
            if not trash_dir:
                result["errors"].append(f"daily zip {f.name}: 回收站不可用，跳过文件清理")
                continue
            ok, err = _move_to_trash(f, trash_dir / "daily" / "zips", f.name)
            if ok:
                result["trashedFiles"].append(f"daily/zips/{f.name}")
            else:
                result["errors"].append(f"daily zip 移除失败 {f.name}: {err}")
    return result


def _cleanup_pack_release(
    src_dir: Path, module: str, pack_ids: set[str], trash_dir: Path
) -> dict[str, Any]:
    """
    events/collections 模块 release 镜像投影回退：
    - index.json 移除匹配 id 的 entry（version 不回退）；
    - 被移除 entry 指向的 packs/{zip} 与 covers/{cover} 移入回收站。
    module 形如 "events" / "collections"。
    返回 {removedEntries, trashedFiles, indexPath, errors}。
    """
    result: dict[str, Any] = {"removedEntries": 0, "trashedFiles": [], "indexPath": None, "errors": []}
    if not pack_ids:
        return result
    ws = StudioWorkspace(src_dir, read_only=True)
    index_p = ws.release_dir / module / "index.json"
    removed_entries: list[dict[str, Any]] = []
    if index_p.exists():
        try:
            data = json.loads(index_p.read_text(encoding="utf-8"))
        except Exception as e:
            result["errors"].append(f"release/{module}/index.json 解析失败，跳过镜像回退: {e}")
            return result
        if isinstance(data, dict) and isinstance(data.get("items"), list):
            items = data["items"]
            kept = [
                e for e in items
                if not (isinstance(e, dict) and str(e.get("id") or "") in pack_ids)
            ]
            removed = len(items) - len(kept)
            if removed:
                removed_entries = [e for e in items if e not in kept]
                data["items"] = kept
                data["updatedAt"] = dt.datetime.now(dt.timezone.utc).isoformat().replace(
                    "+00:00", "Z"
                )
                try:
                    tmp_p = index_p.with_suffix(".tmp")
                    tmp_p.write_text(
                        json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8"
                    )
                    tmp_p.replace(index_p)
                    result["indexPath"] = str(index_p)
                except Exception as e:
                    result["errors"].append(f"{module} index.json 回退写入失败: {e}")
                    return result
                result["removedEntries"] = removed

    for entry in removed_entries:
        for key in ("zipUrl", "coverUrl"):
            rel = entry.get(key)
            if not rel:
                continue
            f = _safe_release_path(ws, module, rel)
            if f is None:
                result["errors"].append(f"{module} 产物路径非法，已跳过: {rel}")
                continue
            if f.exists():
                if not trash_dir:
                    result["errors"].append(f"{module} 产物 {f.name}: 回收站不可用，跳过文件清理")
                    continue
                ok, err = _move_to_trash(f, trash_dir / module / f.name, f.name)
                if ok:
                    result["trashedFiles"].append(f"{module}/{f.name}")
                else:
                    result["errors"].append(f"{module} 产物移除失败 {f.name}: {err}")
    return result


def _cleanup_release_for_module(
    src_dir: Path,
    module: str,
    targets: list[dict[str, Any]],
    trash_dir: Path | None = None,
) -> dict[str, Any]:
    """按模块路由 release 镜像投影回退。"""
    if module == "main":
        batch_ids = {
            str(r.get("batchId"))
            for r in targets
            if r.get("batchId") is not None
        }
        return _cleanup_main_release(src_dir, batch_ids, trash_dir)
    if module == "daily":
        months = {str(r["month"]) for r in targets if r.get("month") is not None}
        return _cleanup_daily_release(src_dir, months, trash_dir)
    if module in ("events", "collections"):
        pack_ids = {
            str(r.get("packId"))
            for r in targets
            if r.get("packId") is not None
        }
        return _cleanup_pack_release(src_dir, module, pack_ids, trash_dir)
    return {"removedEntries": 0, "trashedFiles": [], "errors": [], "skipped": True}


def undo_op(
    src_dir: Path | str,
    op_id: str,
    dry_run: bool = False,
    clean_release: bool = True,
    reason: str = "",
) -> dict[str, Any]:
    """
    撤销一次导出。dry_run=True 只预览不落盘。
    返回摘要 dict：{ok, msg, ...}

    各模块镜像投影回退（L1.2 原子撤销，产物移入回收站而非物理删除）：
      main        release/main/index.json 移除批次 + 批次目录移入回收站
      daily       release/daily/index.json 移除月份 + zips/{zip} 移入回收站
      events/collections  release/{module}/index.json 移除条目 + packs/covers 移入回收站
    """
    src = Path(src_dir).resolve()
    # 读取目标 records 明细（撤销前取，含 module/batchId/month/packId 等投影定位字段）
    ledger_ro = ExportsLedger(src, read_only=True)
    targets = [r for r in ledger_ro.records if r.get("opId") == op_id]
    if not targets:
        return {"ok": False, "msg": f"未找到 opId={op_id} 的导出操作（可能已撤销）"}

    modules = sorted({str(r.get("module") or "") for r in targets})
    modules = [m for m in modules if m]
    count = len(targets)
    batch_ids = {str(r.get("batchId")) for r in targets if r.get("batchId") is not None}
    min_order = None
    max_order = None
    for r in targets:
        o = r.get("order")
        if o is None:
            continue
        try:
            io = int(o)
        except Exception:
            continue
        min_order = io if min_order is None else min(min_order, io)
        max_order = io if max_order is None else max(max_order, io)

    preview_lines = [
        f"撤销操作 {op_id}: 将剔除 {count} 条记账记录",
        f"  模块: {', '.join(modules) or '未知'}",
    ]
    if min_order is not None:
        preview_lines.append(
            f"  关卡区间: {min_order} ~ {max_order} (批次: {', '.join(sorted(batch_ids)) or '-'})"
        )
    if targets and targets[0].get("exportedAt"):
        preview_lines.append(f"  最后导出时间: {targets[0].get('exportedAt')}")
    for m in modules:
        if m == "main":
            preview_lines.append("  main 镜像: 回退 release/main/index.json + 删除批次文件")
        elif m == "daily":
            preview_lines.append(
                "  daily 镜像: 回退 release/daily/index.json + 删除对应 zips/*.zip"
            )
        elif m in ("events", "collections"):
            preview_lines.append(
                f"  {m} 镜像: 回退 release/{m}/index.json + 删除对应 packs/covers 产物"
            )
        else:
            preview_lines.append(f"  {m}: 仅撤销 ledger 记录（无镜像回退逻辑）")

    if dry_run:
        return {"ok": True, "dryRun": True, "msg": "\n".join(preview_lines)}

    # 1. 撤销前自动快照：账本 + 涉及模块的 index.json
    snap_ledger = backup_ledger_snapshot(src)
    ws = StudioWorkspace(src, read_only=False)
    backups_dir = ws.ledger_dir / "backups"
    snapshots: dict[str, Path] = {}
    for m in modules:
        if m in ("main", "daily", "events", "collections"):
            snap = _snapshot_file(
                ws.release_dir / m / "index.json", backups_dir
            )
            if snap:
                snapshots[m] = snap

    # 2. 先回退各模块 release 镜像（产物移入回收站；任一失败则整体还原、账本不动）
    release_res: dict[str, Any] = {}
    mirror_errors: list[str] = []
    trash_dir = backups_dir / f"trashed-{op_id}"
    if clean_release:
        for m in modules:
            res = _cleanup_release_for_module(src, m, targets, trash_dir)
            release_res[m] = res
            mirror_errors.extend(f"{m}: {e}" for e in (res.get("errors") or []))
        if mirror_errors:
            restored_idx: list[str] = []
            for m, snap in snapshots.items():
                try:
                    idx_p = ws.release_dir / m / "index.json"
                    tmp_p = idx_p.with_suffix(".tmp")
                    shutil.copy2(snap, tmp_p)
                    tmp_p.replace(idx_p)
                    restored_idx.append(f"{m}/index.json")
                except Exception:
                    pass
            restored_files = _restore_trash(trash_dir, ws, modules)
            try:
                shutil.rmtree(trash_dir, ignore_errors=True)
            except Exception:
                pass
            try:
                ws.log_export(
                    "rollback_export",
                    scope=",".join(modules) or "unknown",
                    entity=op_id,
                    after={
                        "removedRecords": 0,
                        "reason": reason or "",
                        "srcDir": str(src),
                        "error": "; ".join(mirror_errors)[:500],
                    },
                    result="fail",
                )
            except Exception:
                pass
            return {
                "ok": False,
                "msg": (
                    f"回滚失败，已整体还原，账本未改动。失败原因: {'; '.join(mirror_errors)}"
                    + (f"；已还原 index: {', '.join(restored_idx)}" if restored_idx else "")
                    + (f"；已还原文件: {', '.join(restored_files)}" if restored_files else "")
                ),
                "errors": mirror_errors,
                "restoredIndex": restored_idx,
                "restoredFiles": restored_files,
                "snapshotLedger": (snap_ledger.name if snap_ledger else None),
                "snapshotIndex": [p.name for p in snapshots.values()],
            }

    # 3. 镜像全部回退成功 → 才回滚账本记录
    ledger = ExportsLedger(src, read_only=False)
    ok, msg = ledger.rollback_operation(op_id, reason=reason)
    if not ok:
        return {
            "ok": False,
            "msg": f"镜像已回退但账本回滚失败，请人工核查（可从快照恢复镜像）: {msg}",
            "errors": [msg],
            "snapshotLedger": (snap_ledger.name if snap_ledger else None),
            "snapshotIndex": [p.name for p in snapshots.values()],
        }

    # 4. 追加 rollback_export 审计流水
    try:
        ws.log_export(
            "rollback_export",
            scope=",".join(modules) or "unknown",
            entity=op_id,
            after={
                "removedRecords": count,
                "reason": reason or "",
                "srcDir": str(src),
            },
            result="ok",
        )
    except Exception:
        pass

    detail = "\n".join(preview_lines)
    extra_parts = []
    for m, res in release_res.items():
        if res.get("skipped"):
            continue
        extra_parts.append(
            f"{m} 镜像回退 index({res.get('removedEntries', 0)} 条) 移除 {len(res.get('trashedFiles') or [])} 个文件"
        )
    if extra_parts:
        extra = "；" + "；".join(extra_parts)
    else:
        extra = ""
    if snap_ledger:
        extra += f"；快照: {snap_ledger.name}"
    if snapshots:
        extra += f" index 快照: {','.join(p.name for p in snapshots.values())}"
    return {
        "ok": True,
        "msg": f"{msg}{extra}",
        "detail": detail,
        "removedRecords": count,
        "modules": modules,
        "trashedFiles": [
            f for res in release_res.values() for f in (res.get("trashedFiles") or [])
        ],
        "snapshotLedger": (snap_ledger.name if snap_ledger else None),
        "snapshotIndex": [p.name for p in snapshots.values()],
    }


def undo_last(
    src_dir: Path | str,
    module: str | None = None,
    dry_run: bool = False,
    clean_release: bool = True,
    reason: str = "",
) -> dict[str, Any]:
    """撤销最近一次导出（可按模块过滤）。"""
    ops = list_ops(src_dir)
    candidates = [o for o in ops if o.get("opId")]
    if module:
        candidates = [
            o for o in candidates if module.lower() in [m.lower() for m in o.get("modules") or []]
        ]
    if not candidates:
        return {"ok": False, "msg": "没有可撤销的导出操作"}
    return undo_op(
        src_dir,
        candidates[-1]["opId"],
        dry_run=dry_run,
        clean_release=clean_release,
        reason=reason,
    )


_BATCH_ID_RE = re.compile(r"^[A-Za-z0-9_\-]+$")


def _safe_batch_id(batch_id: str) -> str | None:
    """batchId 白名单校验：仅允许字母数字下划线连字符，防止路径拼接越界。"""
    bid = str(batch_id or "").strip()
    if not bid or not _BATCH_ID_RE.match(bid) or bid in (".", ".."):
        return None
    return bid


def _safe_release_path(ws: "StudioWorkspace", module: str, rel: str) -> Path | None:
    """
    规范化 release/{module}/ 下的相对路径，限制在 release/{module} 目录内。
    防御 '..' 等越界拼接；越界或异常返回 None。
    """
    try:
        base = (ws.release_dir / module).resolve()
        p = (base / str(rel or "").lstrip("/\\")).resolve()
        if p != base and not str(p).startswith(str(base) + "\\") and not str(p).startswith(str(base) + "/"):
            return None
        return p
    except Exception:
        return None


def _move_to_trash(src: Path, trash_dir: Path, rel: str) -> tuple[bool, str]:
    """
    将 release 内产物移入回收站目录（trash_dir/rel），保留结构以便失败还原。
    返回 (成功, 错误消息)。
    """
    try:
        dest = trash_dir / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(src), str(dest))
        return True, ""
    except Exception as e:
        return False, f"{src.name}: {e}"


def _restore_trash(trash_dir: Path, ws: "StudioWorkspace", modules: list[str]) -> list[str]:
    """
    失败还原：把回收站内 {module}/ 相对结构下的文件移回 release/{module}/。
    返回还原的文件相对路径列表。
    """
    restored: list[str] = []
    for m in modules:
        mdir = trash_dir / m
        if not mdir.exists():
            continue
        for f in sorted(mdir.rglob("*")):
            if not f.is_file():
                continue
            rel = f.relative_to(mdir)
            dest = ws.release_dir / m / rel
            try:
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(f), str(dest))
                restored.append(f"{m}/{rel.as_posix()}")
            except Exception:
                continue
    return restored


def _fmt_ts(iso: str | None) -> str:
    if not iso:
        return "-"
    try:
        return dt.datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone().strftime(
            "%Y-%m-%d %H:%M:%S"
        )
    except Exception:
        return iso


def cmd_list(args: argparse.Namespace) -> int:
    ops = list_ops(args.src)
    if not ops:
        print("账本为空，无任何导出记录。")
        return 0
    if args.module:
        ops = [
            o
            for o in ops
            if args.module.lower() in [m.lower() for m in o.get("modules") or []]
        ]
    legacy = [o for o in ops if not o.get("opId")]
    normal = [o for o in ops if o.get("opId")]
    if normal:
        print(f"可撤销的导出操作 ({len(normal)} 个，按时间升序):")
        for o in normal:
            mods = ",".join(o.get("modules") or ["?"])
            rng = ""
            if o.get("minOrder") is not None:
                rng = f" [order {o['minOrder']}~{o['maxOrder']}]"
            b = ""
            if o.get("batchIds"):
                b = f" (batch: {','.join(o['batchIds'])})"
            print(
                f"  {o['opId']}  {mods}{rng}{b}  记录数={o['count']}  "
                f"导出时间={_fmt_ts(o.get('maxExportedAt'))}"
            )
    if legacy:
        print(f"\nlegacy 记录（无 opId，不支持按操作撤销）: {len(legacy)} 组")
        for o in legacy:
            print(
                f"  (legacy)  {','.join(o.get('modules') or ['?'])}  记录数={o['count']}  "
                f"导出时间={_fmt_ts(o.get('maxExportedAt'))}"
            )
    return 0


def cmd_undo(args: argparse.Namespace) -> int:
    if not args.dry_run and not args.yes:
        preview = undo_op(
            args.src,
            args.op,
            dry_run=True,
            clean_release=not args.no_release,
            reason=args.reason,
        )
        print(preview["msg"])
        print("（以上为预览。确认撤销请加 --yes 执行，或加 --dry-run 仅预览不落盘）")
        return 1
    res = undo_op(
        args.src,
        args.op,
        dry_run=args.dry_run,
        clean_release=not args.no_release,
        reason=args.reason,
    )
    print(res["msg"])
    if not res.get("ok"):
        return 1
    if res.get("dryRun"):
        print("（预览模式，未写入任何文件。确认后加 --yes 执行）")
        return 0
    return 0


def cmd_undo_last(args: argparse.Namespace) -> int:
    if not args.dry_run and not args.yes:
        preview = undo_last(
            args.src,
            module=args.module,
            dry_run=True,
            clean_release=not args.no_release,
            reason=args.reason,
        )
        print(preview["msg"])
        print("（以上为预览。确认撤销请加 --yes 执行，或加 --dry-run 仅预览不落盘）")
        return 1
    res = undo_last(
        args.src,
        module=args.module,
        dry_run=args.dry_run,
        clean_release=not args.no_release,
        reason=args.reason,
    )
    print(res["msg"])
    if not res.get("ok"):
        return 1
    if res.get("dryRun"):
        print("（预览模式，未写入任何文件。确认后加 --yes 执行）")
        return 0
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m studio.core.export_rollback",
        description="撤销某次导出（操作日志模型 L1 回滚工具）",
    )
    parser.add_argument("src", help="源素材库目录（含 .studio/ledger）")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_list = sub.add_parser("list", help="列出可撤销的导出操作")
    p_list.add_argument("--module", help="仅显示指定模块 (main/daily/event/collection)")
    p_list.set_defaults(func=cmd_list)

    p_undo = sub.add_parser("undo", help="按 opId 撤销一次导出")
    p_undo.add_argument("--op", required=True, help="导出操作 ID (见 list)")
    p_undo.add_argument("--dry-run", action="store_true", help="只预览，不写入")
    p_undo.add_argument("--yes", action="store_true", help="跳过预览直接执行")
    p_undo.add_argument("--no-release", action="store_true", help="跳过 main 镜像投影回退")
    p_undo.add_argument("--reason", default="", help="撤销原因（写入事件与审计）")
    p_undo.set_defaults(func=cmd_undo)

    p_last = sub.add_parser("undo-last", help="撤销最近一次导出")
    p_last.add_argument("--module", help="仅撤销指定模块的最近一次导出")
    p_last.add_argument("--dry-run", action="store_true", help="只预览，不写入")
    p_last.add_argument("--yes", action="store_true", help="跳过预览直接执行")
    p_last.add_argument("--no-release", action="store_true", help="跳过 main 镜像投影回退")
    p_last.add_argument("--reason", default="", help="撤销原因（写入事件与审计）")
    p_last.set_defaults(func=cmd_undo_last)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
