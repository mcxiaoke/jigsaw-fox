#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.core.cache_db — Content Studio 基于 SQLite3 的底层算力与质检缓存引擎
单文件存储 (.studio.db)，开启 WAL 高并发模式，提供毫秒级增量读写与断点续算。
"""

from __future__ import annotations

import datetime as dt
import json
import sqlite3
import threading
from pathlib import Path
from typing import Any, Iterable

CACHE_DB_NAME = ".studio.db"


class CacheDB:
    """
    基于 SQLite3 的工作室技术算力缓存管理器：
    1. file_cache: (path, mtime, size) -> (hash, width, height, format)
    2. quality_cache: hash -> (score, grade, status, dead_zone_ratio, crop_suggestion, ...)
    """

    def __init__(self, src_dir: Path | str) -> None:
        self.src_dir = Path(src_dir).resolve()
        self.db_path = self.src_dir / CACHE_DB_NAME
        self._lock = threading.Lock()
        self._conn: sqlite3.Connection | None = None
        self._init_db()

    def _get_conn(self) -> sqlite3.Connection:
        if self._conn is None:
            self._conn = sqlite3.connect(
                str(self.db_path),
                timeout=30.0,
                check_same_thread=False,
            )
            self._conn.row_factory = sqlite3.Row
            # 开启 WAL 模式与繁忙重试
            self._conn.execute("PRAGMA journal_mode=WAL;")
            self._conn.execute("PRAGMA synchronous=NORMAL;")
            self._conn.execute("PRAGMA busy_timeout=10000;")
        return self._conn

    def _init_db(self) -> None:
        """初始化表结构与必要索引"""
        with self._lock:
            conn = self._get_conn()
            with conn:
                conn.executescript("""
                    CREATE TABLE IF NOT EXISTS file_cache (
                        path            TEXT PRIMARY KEY,
                        mtime           INTEGER NOT NULL,
                        size            INTEGER NOT NULL,
                        hash            TEXT NOT NULL,
                        width           INTEGER DEFAULT 0,
                        height          INTEGER DEFAULT 0,
                        format          TEXT DEFAULT '',
                        updated_at      TEXT NOT NULL
                    );
                    CREATE INDEX IF NOT EXISTS idx_file_hash ON file_cache(hash);

                    CREATE TABLE IF NOT EXISTS quality_cache (
                        hash                TEXT PRIMARY KEY,
                        score               INTEGER NOT NULL,
                        grade               TEXT NOT NULL,
                        status              TEXT NOT NULL,
                        dead_zone_ratio     REAL DEFAULT 0.0,
                        core_dead_ratio     REAL DEFAULT 0.0,
                        border_dead_ratio   REAL DEFAULT 0.0,
                        flat_zone_ratio     REAL DEFAULT 0.0,
                        crop_suggestion     TEXT DEFAULT '',
                        can_upgrade         INTEGER DEFAULT 0,
                        max_grid            TEXT DEFAULT '',
                        details_json        TEXT DEFAULT '',
                        evaluated_at        TEXT NOT NULL
                    );
                    CREATE INDEX IF NOT EXISTS idx_quality_status ON quality_cache(status, grade);
                """)

    def load_file_cache(self) -> dict[str, tuple[int, int, str, int, int, str]]:
        """
        读取所有文件的基础缓存元数据：
        返回: { rel_path: (mtime, size, hash, width, height, format) }
        """
        result: dict[str, tuple[int, int, str, int, int, str]] = {}
        with self._lock:
            conn = self._get_conn()
            cursor = conn.execute(
                "SELECT path, mtime, size, hash, width, height, format FROM file_cache"
            )
            for row in cursor:
                result[row["path"]] = (
                    int(row["mtime"]),
                    int(row["size"]),
                    str(row["hash"]),
                    int(row["width"]),
                    int(row["height"]),
                    str(row["format"]),
                )
        return result

    def upsert_files(self, items: list[dict[str, Any]]) -> int:
        """
        批量原子写入/更新文件缓存项。
        items 每项包含: path, mtime, size, hash, width, height, format
        """
        if not items:
            return 0
        now_iso = dt.datetime.now().isoformat(timespec="seconds")
        rows = [
            (
                it.get("path", "").replace("\\", "/"),
                int(it.get("mtime", 0)),
                int(it.get("size", 0)),
                (it.get("hash") or "").strip().lower(),
                int(it.get("width", 0)),
                int(it.get("height", 0)),
                (it.get("format") or "").upper(),
                now_iso,
            )
            for it in items
            if it.get("path")
        ]
        with self._lock:
            conn = self._get_conn()
            with conn:
                conn.executemany(
                    """
                    INSERT INTO file_cache (path, mtime, size, hash, width, height, format, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(path) DO UPDATE SET
                        mtime = excluded.mtime,
                        size = excluded.size,
                        hash = excluded.hash,
                        width = excluded.width,
                        height = excluded.height,
                        format = excluded.format,
                        updated_at = excluded.updated_at
                    """,
                    rows,
                )
        return len(rows)

    def prune_missing_files(self, active_paths: Iterable[str]) -> int:
        """
        清理在磁盘上已不存在的废弃路径缓存。
        active_paths 为当前实际扫描到的所有相对路径集合。
        """
        active_set = {p.replace("\\", "/") for p in active_paths if p}
        with self._lock:
            conn = self._get_conn()
            cursor = conn.execute("SELECT path FROM file_cache")
            cached_paths = [r["path"] for r in cursor]
            to_delete = [p for p in cached_paths if p not in active_set]
            if not to_delete:
                return 0
            with conn:
                # 分批执行删除，防止参数过多超限
                for i in range(0, len(to_delete), 500):
                    batch = to_delete[i : i + 500]
                    placeholders = ",".join("?" for _ in batch)
                    conn.execute(
                        f"DELETE FROM file_cache WHERE path IN ({placeholders})",
                        batch,
                    )
            return len(to_delete)

    def get_qualities(self, hashes: list[str]) -> dict[str, dict[str, Any]]:
        """
        根据内容 Hash 列表批量查询质检评分结果。
        返回: { hash: quality_dict }
        """
        if not hashes:
            return {}
        clean_hashes = list({h.strip().lower() for h in hashes if h})
        result: dict[str, dict[str, Any]] = {}

        with self._lock:
            conn = self._get_conn()
            for i in range(0, len(clean_hashes), 500):
                batch = clean_hashes[i : i + 500]
                placeholders = ",".join("?" for _ in batch)
                cursor = conn.execute(
                    f"""
                    SELECT hash, score, grade, status, dead_zone_ratio, core_dead_ratio,
                           border_dead_ratio, flat_zone_ratio, crop_suggestion, can_upgrade,
                           max_grid, details_json, evaluated_at
                    FROM quality_cache
                    WHERE hash IN ({placeholders})
                    """,
                    batch,
                )
                for row in cursor:
                    h = row["hash"]
                    details = {}
                    if row["details_json"]:
                        try:
                            details = json.loads(row["details_json"])
                        except Exception:
                            pass
                    result[h] = {
                        "score": row["score"],
                        "grade": row["grade"],
                        "status": row["status"],
                        "dead_zone_ratio": row["dead_zone_ratio"],
                        "core_dead_ratio": row["core_dead_ratio"],
                        "border_dead_ratio": row["border_dead_ratio"],
                        "flat_zone_ratio": row["flat_zone_ratio"],
                        "crop_suggestion": row["crop_suggestion"],
                        "can_upgrade": bool(row["can_upgrade"]),
                        "max_grid": row["max_grid"],
                        "evaluated_at": row["evaluated_at"],
                        "details": details,
                    }
        return result

    def get_quality(self, hash_val: str) -> dict[str, Any] | None:
        """单张根据 Hash 查询质检结果"""
        res = self.get_qualities([hash_val])
        return res.get(hash_val.strip().lower())

    def save_quality(self, hash_val: str, quality_data: dict[str, Any]) -> None:
        """保存单张图片的质检评分结果"""
        self.save_qualities_batch([(hash_val, quality_data)])

    def save_qualities_batch(self, items: list[tuple[str, dict[str, Any]]]) -> int:
        """
        批量保存质检评分结果。
        items 每项为: (hash, quality_dict)
        """
        if not items:
            return 0
        now_iso = dt.datetime.now().isoformat(timespec="seconds")
        rows = []
        for h, q in items:
            if not h:
                continue
            h_clean = h.strip().lower()
            details = q.get("details", {})
            details_s = json.dumps(details, ensure_ascii=False) if details else ""
            rows.append((
                h_clean,
                int(q.get("score", 0)),
                str(q.get("grade", "C")).upper(),
                str(q.get("status", "WARN")).upper(),
                float(q.get("dead_zone_ratio", 0.0)),
                float(q.get("core_dead_ratio", 0.0)),
                float(q.get("border_dead_ratio", 0.0)),
                float(q.get("flat_zone_ratio", 0.0)),
                str(q.get("crop_suggestion", "")),
                1 if q.get("can_upgrade") else 0,
                str(q.get("max_grid", "")),
                details_s,
                q.get("evaluated_at") or now_iso,
            ))

        with self._lock:
            conn = self._get_conn()
            with conn:
                conn.executemany(
                    """
                    INSERT INTO quality_cache (
                        hash, score, grade, status, dead_zone_ratio, core_dead_ratio,
                        border_dead_ratio, flat_zone_ratio, crop_suggestion, can_upgrade,
                        max_grid, details_json, evaluated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(hash) DO UPDATE SET
                        score = excluded.score,
                        grade = excluded.grade,
                        status = excluded.status,
                        dead_zone_ratio = excluded.dead_zone_ratio,
                        core_dead_ratio = excluded.core_dead_ratio,
                        border_dead_ratio = excluded.border_dead_ratio,
                        flat_zone_ratio = excluded.flat_zone_ratio,
                        crop_suggestion = excluded.crop_suggestion,
                        can_upgrade = excluded.can_upgrade,
                        max_grid = excluded.max_grid,
                        details_json = excluded.details_json,
                        evaluated_at = excluded.evaluated_at
                    """,
                    rows,
                )
        return len(rows)

    def get_unscored_items(self, limit: int = 100) -> list[tuple[str, str]]:
        """
        获取尚未进行质量评分的图片列表：
        返回: [(path, hash)]，最多返回 limit 条
        """
        with self._lock:
            conn = self._get_conn()
            cursor = conn.execute(
                """
                SELECT f.path, f.hash
                FROM file_cache f
                LEFT JOIN quality_cache q ON f.hash = q.hash
                WHERE q.hash IS NULL AND f.hash != ''
                ORDER BY f.path ASC
                LIMIT ?
                """,
                (limit,),
            )
            return [(r["path"], r["hash"]) for r in cursor]

    def get_stats(self) -> dict[str, Any]:
        """获取缓存状态与质检分布总览"""
        with self._lock:
            conn = self._get_conn()
            total_files = conn.execute("SELECT COUNT(*) FROM file_cache").fetchone()[0]
            total_scored = conn.execute("SELECT COUNT(*) FROM quality_cache").fetchone()[0]

            grades: dict[str, int] = {}
            for r in conn.execute("SELECT grade, COUNT(*) as c FROM quality_cache GROUP BY grade"):
                grades[r["grade"]] = r["c"]

            statuses: dict[str, int] = {}
            for r in conn.execute("SELECT status, COUNT(*) as c FROM quality_cache GROUP BY status"):
                statuses[r["status"]] = r["c"]

            return {
                "total_files": total_files,
                "total_scored": total_scored,
                "unscored": max(0, total_files - total_scored),
                "grades": grades,
                "statuses": statuses,
            }

    def close(self) -> None:
        with self._lock:
            if self._conn is not None:
                try:
                    self._conn.close()
                except Exception:
                    pass
                self._conn = None

    def __enter__(self) -> "CacheDB":
        return self

    def __exit__(self, exc_type: Any, exc_val: Any, exc_tb: Any) -> None:
        self.close()
