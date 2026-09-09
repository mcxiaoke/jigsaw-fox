#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.core.exports_ledger — 源素材库唯一权威导出总账本 (.studio/ledger/exports.json)
基于 Append-Only 列表设计，记录原图 SHA-256、逻辑 ID、版本修订与交付归属。
支持历史防重拦截、同模块排重、跨模块预警与旧版 exported.json 自动迁移。
"""

from __future__ import annotations

import datetime as dt
import json
import shutil
from pathlib import Path
import threading
from typing import Any
import logging

logger = logging.getLogger(__name__)

from studio.core.workspace import StudioWorkspace


class ExportsLedger:
    """
    源侧权威导出总账本管理器：
    - 持久化路径: srcDir/.studio/ledger/exports.json (schemaVersion: 2)
    - 列表设计 (Append-Only): 绝不覆盖，完整记录修图、版本更迭与回滚历史
    - 内存倒排索引: sourceHash -> list[record], logicalId -> record
    """

    def __init__(self, src_dir: Path | str, read_only: bool = False) -> None:
        self.src_dir = Path(src_dir).resolve()
        self.workspace = StudioWorkspace(self.src_dir, read_only=read_only)
        self.ledger_file = self.workspace.ledger_file
        self.events_file = self.ledger_file.parent / "exports_events.jsonl"
        self._read_only = bool(read_only)
        self._lock = threading.Lock()

        self.schema_version = 2
        self.updated_at = ""
        self.records: list[dict[str, Any]] = []

        # 内存倒排索引
        self._by_source_hash: dict[str, list[dict[str, Any]]] = {}
        self._by_logical_id: dict[str, list[dict[str, Any]]] = {}
        self._superseded_ids: set[str] = set()

        self.load()

    def load(self) -> None:
        """加载账本数据，若不存在或损坏则依次尝试 legacy 迁移 / 事件流重建"""
        with self._lock:
            if not self.ledger_file.exists() or not self.ledger_file.is_file():
                if self._try_migrate_legacy():
                    return
                if self._try_rebuild_from_events():
                    return
                self.schema_version = 2
                self.updated_at = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
                self.records = []
                self._rebuild_indices()
                return

            try:
                data = json.loads(self.ledger_file.read_text(encoding="utf-8"))
                if isinstance(data, dict):
                    self.schema_version = int(data.get("schemaVersion", 2))
                    self.updated_at = str(data.get("updatedAt", ""))
                    self.records = list(data.get("records", []))
                else:
                    self.records = []
            except Exception as e:
                logger.error("[ledger] 账本解析失败，尝试事件流重建: %s (%s)", self.ledger_file, e)
                try:
                    corrupt_backup = self.ledger_file.with_suffix(".corrupt")
                    shutil.copy2(self.ledger_file, corrupt_backup)
                except Exception as e:
                    logger.warning("[ledger] 账本损坏副本备份失败: %s (%s)", self.ledger_file, e)
                if self._try_rebuild_from_events():
                    return
                self.records = []

            self._rebuild_indices()

    def _try_rebuild_from_events(self) -> bool:
        """
        从 append-only 事件流 exports_events.jsonl 全量重放，重建账本记录。
        成功且非只读时会把重建结果物化回 exports.json。
        """
        if not self.events_file.exists() or not self.events_file.is_file():
            return False
        try:
            records: list[dict[str, Any]] = []
            with open(self.events_file, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        ev = json.loads(line)
                    except Exception:
                        continue
                    if ev.get("action") != "append":
                        continue
                    r = ev.get("record")
                    if isinstance(r, dict):
                        records.append(r)
            if not records:
                return False
            self.records = records
            self._rebuild_indices()
            if not self._read_only:
                self._save_unlocked()
            logger.info("[ledger] 已从事件流重建账本: %d 条记录", len(records))
            return True
        except Exception as e:
            logger.warning("[ledger] 事件流重建失败: %s (%s)", self.events_file, e)
            return False

    def _append_events(self, records: list[dict[str, Any]]) -> None:
        """向 append-only 账本事件流追加记录事件（一份数据两用：可重建账本 + 操作审计）。"""
        if not records:
            return
        try:
            self.events_file.parent.mkdir(parents=True, exist_ok=True)
            lines = []
            ts = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
            for rec in records:
                ev = {
                    "v": self.schema_version,
                    "ts": ts,
                    "action": "append",
                    "record": rec,
                }
                lines.append(json.dumps(ev, ensure_ascii=False))
            with open(self.events_file, "a", encoding="utf-8") as f:
                f.write("\n".join(lines) + "\n")
        except Exception as e:
            logger.warning("[ledger] 事件流追加失败: %s (%s)", self.events_file, e)

    def _try_migrate_legacy(self) -> bool:
        """从旧版 exported.json (1.0.0 字典格式) 自动迁移"""
        candidates = [
            self.src_dir / "exported.json",
            self.workspace.studio_dir / "exported.json",
        ]
        legacy_file = None
        for cand in candidates:
            if cand.exists() and cand.is_file():
                legacy_file = cand
                break

        if not legacy_file:
            return False

        try:
            raw = json.loads(legacy_file.read_text(encoding="utf-8"))
            if not isinstance(raw, dict) or "hashes" not in raw:
                return False

            hashes_dict = raw.get("hashes", {})
            migrated_records: list[dict[str, Any]] = []
            idx = 1

            for h, item in hashes_dict.items():
                if not isinstance(item, dict):
                    continue
                exp_type = item.get("export_type", "main")
                order = item.get("order")
                month = item.get("month")
                event_id = item.get("event_id")
                col_id = item.get("collection_id")

                if exp_type == "main" and order:
                    logical_id = f"main:{order}"
                elif exp_type == "daily" and month:
                    logical_id = f"daily:{month}"
                elif exp_type == "event" and event_id:
                    logical_id = f"event:{event_id}"
                elif exp_type == "collection" and col_id:
                    logical_id = f"collection:{col_id}"
                else:
                    logical_id = f"{exp_type}:{Path(item.get('path', '')).stem}"

                rec = {
                    "recordId": f"rec_{idx:04d}",
                    "sourceHash": (item.get("hash") or h).strip().lower(),
                    "sourcePath": item.get("path", "").replace("\\", "/"),
                    "sourceSize": int(item.get("file_size", 0)),
                    "module": exp_type,
                    "logicalId": logical_id,
                    "order": order,
                    "batchId": None,
                    "targetFile": item.get("target", ""),
                    "targetHash": "",
                    "revision": 1,
                    "supersedes": None,
                    "cropInfo": None,
                    "exportedAt": item.get("exported_at") or dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
                }
                migrated_records.append(rec)
                idx += 1

            self.schema_version = 2
            self.updated_at = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
            self.records = migrated_records
            self._rebuild_indices()
            if not self._read_only:
                self._save_unlocked()
            return True
        except Exception as e:
            logger.warning("[ledger] 旧版 exported.json 迁移失败，跳过: %s", e)
            return False

    def _rebuild_indices(self) -> None:
        """重构内存倒排索引"""
        self._by_source_hash.clear()
        self._by_logical_id.clear()
        self._superseded_ids.clear()

        for rec in self.records:
            h = (rec.get("sourceHash") or "").strip().lower()
            if h:
                self._by_source_hash.setdefault(h, []).append(rec)

            lid = rec.get("logicalId")
            if lid:
                self._by_logical_id.setdefault(lid, []).append(rec)

            sup = rec.get("supersedes")
            if sup:
                self._superseded_ids.add(sup)

    def _save_unlocked(self) -> tuple[bool, str]:
        """无锁保存 (内部调用)"""
        import time

        now_str = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
        self.updated_at = now_str
        payload = {
            "schemaVersion": self.schema_version,
            "updatedAt": self.updated_at,
            "totalExports": len(self.records),
            "records": self.records,
        }
        try:
            self.ledger_file.parent.mkdir(parents=True, exist_ok=True)
            tmp_file = self.ledger_file.with_name(f"{self.ledger_file.name}.tmp")
            content = json.dumps(payload, ensure_ascii=False, indent=2)
            tmp_file.write_text(content, encoding="utf-8")
            # Windows 下防瞬时文件锁冲突重试
            for attempt in range(3):
                try:
                    tmp_file.replace(self.ledger_file)
                    break
                except PermissionError:
                    if attempt == 2:
                        raise
                    time.sleep(0.05)
            return True, str(self.ledger_file)
        except Exception as e:
            if "tmp_file" in locals():
                tmp_file.unlink(missing_ok=True)
            return False, str(e)

    def save(self) -> tuple[bool, str]:
        """原子保存 exports.json 账本"""
        if self._read_only:
            return False, "账本处于只读模式，禁止写入"
        with self._lock:
            return self._save_unlocked()

    def get_exported_hashes(self) -> set[str]:
        """获取所有已导出图片的原图 SHA-256 集合"""
        with self._lock:
            return set(self._by_source_hash.keys())

    def get_exported_map(self) -> dict[str, dict[str, Any]]:
        """获取路径和哈希到导出记录的映射 (保持对老代码的最大兼容)"""
        with self._lock:
            out: dict[str, dict[str, Any]] = {}
            for rec in self.records:
                h = (rec.get("sourceHash") or "").strip().lower()
                p = (rec.get("sourcePath") or "").replace("\\", "/")
                legacy_view = {
                    "hash": h,
                    "path": p,
                    "export_type": rec.get("module"),
                    "target": rec.get("targetFile"),
                    "order": rec.get("order"),
                    "exported_at": rec.get("exportedAt"),
                    "logicalId": rec.get("logicalId"),
                    "recordId": rec.get("recordId"),
                }
                if h:
                    out[h] = legacy_view
                if p:
                    out[p] = legacy_view
            return out

    def check_history_duplicate(
        self,
        source_hash: str,
        module: str,
        logical_id: str | None = None,
    ) -> tuple[bool, str, str | None]:
        """
        根据账本历史核对是否存在重复素材：
        返回: (has_conflict: bool, message: str, severity: 'error' | 'warning' | None)
        - 同模块已使用过且并非同一 logicalId 的修图替换: 严重冲突 (error)，坚决拦截；
        - 跨模块复用 (例如 daily 已用过，main 又要用): 醒目预警 (warning)，提醒运营注意；
        - 同一 logicalId 的补丁修订 (如 main:105 修图换图): 合法修订 (None)。
        """
        with self._lock:
            h = (source_hash or "").strip().lower()
            if not h or h not in self._by_source_hash:
                return False, "", None

            existing_records = self._by_source_hash[h]
            # 过滤掉已被废弃的历史版本
            active_records = [r for r in existing_records if r.get("recordId") not in self._superseded_ids]
            if not active_records:
                return False, "", None

            # 1. 检查同模块历史占用
            same_mod_records = [r for r in active_records if r.get("module") == module]
            if same_mod_records:
                for r in same_mod_records:
                    if logical_id and r.get("logicalId") == logical_id:
                        # 是同一个逻辑 ID 的重放/修图，属于合法补丁
                        continue
                    # 发生了同模块不同关卡/日期的素材重复使用！
                    ident = r.get("logicalId") or r.get("targetFile") or r.get("order")
                    msg = f"素材内容已在同模块 [{module}] 的关卡/条目 ({ident}) 中使用过，禁止重复使用相同图片！"
                    return True, msg, "error"

            # 2. 检查跨模块占用
            diff_mod_records = [r for r in active_records if r.get("module") != module]
            if diff_mod_records:
                used_in = [f"{r.get('module')} ({r.get('logicalId')})" for r in diff_mod_records]
                msg = f"素材内容此前已在其他模块导出使用: {', '.join(used_in)}。若为跨模块复用请注意辨识。"
                return True, msg, "warning"

            return False, "", None

    def append_records(self, new_records: list[dict[str, Any]]) -> int:
        """
        向账本中追加新导出记录 (Append-Only) 并同步原子落盘与写入日志
        """
        if not new_records:
            return 0
        if self._read_only:
            return 0

        with self._lock:
            now_iso = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
            # 幂等：以 (module, logicalId, revision) 为唯一键，已存在则跳过，
            # 同一批次中断后重跑不会产生重复记账记录
            existing_keys = {
                (str(r.get("module") or ""), r.get("logicalId"), r.get("revision"))
                for r in self.records
            }
            added_count = 0
            cur_max_idx = len(self.records)
            appended: list[dict[str, Any]] = []

            for item in new_records:
                cur_max_idx += 1
                rec_id = item.get("recordId") or f"rec_{cur_max_idx:04d}"
                rec = {
                    "recordId": rec_id,
                    "sourceHash": (item.get("sourceHash") or item.get("hash") or "").strip().lower(),
                    "sourcePath": (item.get("sourcePath") or item.get("path") or "").replace("\\", "/"),
                    "sourceSize": int(item.get("sourceSize") or item.get("file_size") or 0),
                    "module": str(item.get("module") or item.get("export_type") or "main"),
                    "logicalId": str(item.get("logicalId") or ""),
                    "order": item.get("order"),
                    "batchId": item.get("batchId"),
                    "targetFile": str(item.get("targetFile") or item.get("target") or ""),
                    "targetHash": str(item.get("targetHash") or ""),
                    "revision": int(item.get("revision") or 1),
                    "supersedes": item.get("supersedes"),
                    "cropInfo": item.get("cropInfo"),
                    "exportedAt": item.get("exportedAt") or now_iso,
                }
                key = (rec["module"], rec["logicalId"], rec["revision"])
                if key in existing_keys:
                    continue
                self.records.append(rec)
                existing_keys.add(key)
                appended.append(rec)
                added_count += 1

            if appended:
                self._rebuild_indices()
                self._append_events(appended)
                self._save_unlocked()
            logger.info("[ledger] 已追加 %d 条导出记录到账本(幂等去重后)", added_count)

        return added_count

    def get_max_order(self, module: str = "main") -> int:
        """获取指定模块当前已分配的最大 order 序号"""
        with self._lock:
            max_o = 0
            for r in self.records:
                if r.get("module") == module and r.get("order") is not None:
                    try:
                        o = int(r["order"])
                        if o > max_o:
                            max_o = o
                    except Exception as e:
                        logger.warning("[ledger] order 解析异常，已跳过: %s (%s)", r.get("recordId"), e)
            return max_o

    def get_active_record(self, logical_id: str) -> dict[str, Any] | None:
        """获取指定 logicalId 当前有效的活跃记录 (未被后续修订废弃)"""
        with self._lock:
            candidates = self._by_logical_id.get(logical_id, [])
            active = [r for r in candidates if r.get("recordId") not in self._superseded_ids]
            if active:
                return active[-1]
            return candidates[-1] if candidates else None

    def get_next_revision(self, logical_id: str) -> int:
        """获取指定 logicalId 下一次修图更新的版本位 (revision)"""
        with self._lock:
            candidates = self._by_logical_id.get(logical_id, [])
            if not candidates:
                return 1
            max_rev = 1
            for r in candidates:
                rev = int(r.get("revision", 1) or 1)
                if rev > max_rev:
                    max_rev = rev
            return max_rev + 1


# 账本快照默认保留份数（超出按文件名时间顺序裁剪最旧）
LEDGER_BACKUP_KEEP = 30


def backup_ledger_snapshot(
    src_dir: Path | str, keep: int = LEDGER_BACKUP_KEEP
) -> Path | None:
    """
    将当前权威账本 .studio/ledger/exports.json 复制为带日期时间后缀的快照，
    存放于 .studio/ledger/backups/exports-YYYYMMDD-HHMMSS.json，并仅保留最近 keep 份。

    用途：账本 JSON 一旦损坏被重置后，可手工用某份快照 copy 覆盖回滚历史。
    返回备份文件路径；账本不存在或无快照差异时返回 None。
    """
    src = Path(src_dir).resolve()
    ws = StudioWorkspace(src, read_only=True)
    if not ws.ledger_file.exists() or not ws.ledger_file.is_file():
        return None
    backup_dir = ws.ledger_dir / "backups"
    try:
        backup_dir.mkdir(parents=True, exist_ok=True)
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        dest = backup_dir / f"exports-{stamp}.json"
        shutil.copy2(ws.ledger_file, dest)
    except Exception as e:
        logger.warning("[ledger] 账本快照备份失败: %s (%s)", ws.ledger_file, e)
        return None

    # 裁剪：只保留最近 keep 份，防止无界累积
    try:
        backups = sorted(backup_dir.glob("exports-*.json"))
        for old in backups[:-keep] if keep > 0 else []:
            try:
                old.unlink()
            except Exception:
                pass
    except Exception:
        pass

    logger.info("[ledger] 已备份账本快照: %s", dest.name)
    return dest

