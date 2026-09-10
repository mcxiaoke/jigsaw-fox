#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.core.workspace — 源素材库私有工作区管理器 (.studio/)
管理工作区目录拓扑、老版本元数据自动迁移、操作审计流水与两阶段发布镜像。
"""

from __future__ import annotations

import datetime as dt
import json
import os
from pathlib import Path
import shutil
import sys
import threading
from typing import Any
import logging

logger = logging.getLogger(__name__)


class StudioWorkspace:
    """
    源素材库私有工作区管理器 (.studio/)：
    - 统一收敛所有内部元数据、缓存、账本与构建快照至 src_dir/.studio/
    - 自动迁移旧版 tags.json, .studio.db, exported.json 至规范子目录
    - 提供线程安全的操作审计流水 (operations.jsonl & exports.jsonl)
    - 支持两阶段发布：release 镜像与最终 outDir 交付拷贝
    """

    _lock = threading.Lock()

    def __init__(self, src_dir: Path | str, read_only: bool = False) -> None:
        self.src_dir = Path(src_dir).resolve()
        self.studio_dir = self.src_dir / ".studio"
        self.cache_dir = self.studio_dir / "cache"
        self.db_file = self.cache_dir / "studio.db"
        self.tags_file = self.studio_dir / "tags.json"
        self.ledger_dir = self.studio_dir / "ledger"
        self.ledger_file = self.ledger_dir / "exports.json"
        self.logs_dir = self.studio_dir / "logs"
        self.operations_log = self.logs_dir / "operations.jsonl"
        self.exports_log = self.logs_dir / "exports.jsonl"
        self.staging_dir = self.studio_dir / "staging"
        self.release_dir = self.studio_dir / "release"
        self.thumbs_dir = self.cache_dir / "thumbs"
        self._read_only = bool(read_only)

        self.ensure_structure()

    @property
    def ledger(self) -> Any:
        from studio.core.exports_ledger import ExportsLedger
        return ExportsLedger(self.src_dir, read_only=self._read_only)

    def ensure_structure(self) -> None:
        """初始化 .studio/ 目录结构并执行向后兼容的数据迁移"""
        with self._lock:
            for d in (
                self.studio_dir,
                self.cache_dir,
                self.thumbs_dir,
                self.ledger_dir,
                self.logs_dir,
                self.staging_dir,
                self.release_dir,
            ):
                d.mkdir(parents=True, exist_ok=True)

            if not self._read_only:
                self._migrate_legacy_files()

    def _migrate_legacy_files(self) -> None:
        """平滑自动迁移根目录下的旧版元数据文件"""
        # 1. 迁移 tags.json -> .studio/tags.json
        legacy_tags = self.src_dir / "tags.json"
        if legacy_tags.exists() and legacy_tags.is_file() and not self.tags_file.exists():
            try:
                shutil.copy2(legacy_tags, self.tags_file)
            except Exception as e:
                logger.warning("[workspace] 迁移旧版 tags.json 失败: %s (%s)", legacy_tags, e)

        # 2. 迁移 .studio.db -> .studio/cache/studio.db (包含 WAL/SHM 文件)
        legacy_db = self.src_dir / ".studio.db"
        if legacy_db.exists() and legacy_db.is_file() and not self.db_file.exists():
            try:
                shutil.move(str(legacy_db), str(self.db_file))
                for ext in ("-wal", "-shm"):
                    leg_side = self.src_dir / f".studio.db{ext}"
                    if leg_side.exists():
                        shutil.move(str(leg_side), str(self.cache_dir / f"studio.db{ext}"))
            except Exception as e:
                logger.warning("[workspace] 迁移旧版 .studio.db 失败: %s (%s)", legacy_db, e)

    def log_operation(self, action: str, **kwargs: Any) -> None:
        """记录业务操作流水 (operations.jsonl)，如打标变更"""
        now_str = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
        clean_kwargs = {k: str(v) if isinstance(v, Path) else v for k, v in kwargs.items()}
        entry = {
            "timestamp": now_str,
            "action": action,
            **clean_kwargs,
        }
        line = json.dumps(entry, ensure_ascii=False) + "\n"
        with self._lock:
            try:
                with open(self.operations_log, "a", encoding="utf-8") as f:
                    f.write(line)
            except Exception as e:
                # 审计流水写失败绝不能静默吞掉：否则「没记录」与「记录失败」无法区分。
                # 审计属尽力而为，不向上抛（不阻断主流程），但必须告警到 stderr。
                print(
                    f"[workspace] 写入操作流水失败 {self.operations_log}: {e}",
                    file=sys.stderr,
                )

    def log_export(
        self,
        action: str,
        scope: str | None = None,
        entity: Any = None,
        before: Any = None,
        after: Any = None,
        result: str = "ok",
        error: Any = None,
        detail: str = "",
        **params: Any,
    ) -> None:
        """记录导出事件审计流水 (exports.jsonl)，结构化一行 JSON。"""
        self._append_structured(
            self.exports_log, action, scope, entity, before, after, result, error, detail, params
        )

    def record_audit(
        self,
        action: str,
        scope: str | None = None,
        entity: Any = None,
        before: Any = None,
        after: Any = None,
        result: str = "ok",
        error: Any = None,
        detail: str = "",
        **params: Any,
    ) -> None:
        """结构化操作审计 (operations.jsonl)，一行 JSON。"""
        self._append_structured(
            self.operations_log, action, scope, entity, before, after, result, error, detail, params
        )

    def _append_structured(
        self,
        log_path: Path,
        action: str,
        scope: str | None,
        entity: Any,
        before: Any,
        after: Any,
        result: str,
        error: Any,
        detail: str,
        params: dict[str, Any],
    ) -> None:
        """统一的结构化审计落盘：写入指定 log 文件一行 JSON。"""
        now_str = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
        entry: dict[str, Any] = {
            "ts": now_str,
            "action": action,
            "scope": scope,
            "entity": entity,
            "before": before,
            "after": after,
            "result": result,
            "error": error,
            "detail": detail,
        }
        for k, v in (params or {}).items():
            entry[k] = str(v) if isinstance(v, Path) else v
        line = json.dumps(entry, ensure_ascii=False) + "\n"
        with self._lock:
            try:
                with open(log_path, "a", encoding="utf-8") as f:
                    f.write(line)
            except Exception as e:
                # 同上：结构化审计（exports.jsonl / operations.jsonl）写失败必须可见。
                print(
                    f"[workspace] 写入结构化审计失败 {log_path}: {e}",
                    file=sys.stderr,
                )

    def promote_staging(self, module: str) -> None:
        """
        两阶段发布：将 .studio/staging/{module}/ 下构建通过的产物原子晋升至 .studio/release/{module}/，
        并清空 staging 暂存区。
        """
        staging_mod = self.staging_dir / module
        if not staging_mod.exists():
            return
        release_mod = self.release_dir / module
        release_mod.mkdir(parents=True, exist_ok=True)
        with self._lock:
            for root, _, files in os.walk(staging_mod):
                rel_root = Path(root).relative_to(staging_mod)
                target_root = release_mod / rel_root
                target_root.mkdir(parents=True, exist_ok=True)
                for f in files:
                    s_f = Path(root) / f
                    d_f = target_root / f
                    shutil.copy2(s_f, d_f)
            shutil.rmtree(staging_mod, ignore_errors=True)

    def copy_release_to_out(self, module: str, out_p: Path) -> list[str]:
        """
        将 .studio/release/{module}/ 的构建镜像原子投影交付至用户指定的 outDir/{module}/
        返回成功复制的文件列表
        """
        src_mod_dir = self.release_dir / module
        if not src_mod_dir.exists():
            return []

        dst_mod_dir = out_p / module
        dst_mod_dir.mkdir(parents=True, exist_ok=True)

        copied_files: list[str] = []
        for root, _, files in os.walk(src_mod_dir):
            rel_root = Path(root).relative_to(src_mod_dir)
            target_root = dst_mod_dir / rel_root
            target_root.mkdir(parents=True, exist_ok=True)
            for f in files:
                src_file = Path(root) / f
                dst_file = target_root / f
                shutil.copy2(src_file, dst_file)
                copied_files.append(str(dst_file.resolve()))

        return copied_files
