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
import logging

logger = logging.getLogger(__name__)

from studio.core.workspace import StudioWorkspace

CACHE_DB_NAME = "studio.db"


class CacheDB:
    """
    基于 SQLite3 的工作室技术算力缓存管理器：
    1. file_cache: (path, mtime, size) -> (hash, width, height, format)
    2. quality_cache: hash -> (score, grade, status, dead_zone_ratio, crop_suggestion, ...)
    3. user_overrides: hash -> (manual crop box %, tags, extras)  用户手动覆盖项
    """

    def __init__(self, src_dir: Path | str) -> None:
        self.src_dir = Path(src_dir).resolve()
        self.workspace = StudioWorkspace(self.src_dir)
        self.db_path = self.workspace.db_file
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

                    CREATE TABLE IF NOT EXISTS user_overrides (
                        hash            TEXT PRIMARY KEY,
                        crop_x0         REAL,
                        crop_y0         REAL,
                        crop_x1         REAL,
                        crop_y1         REAL,
                        crop_ratio      TEXT DEFAULT '',
                        tags_json       TEXT DEFAULT '',
                        extras_json     TEXT DEFAULT '',
                        created_at      TEXT NOT NULL,
                        updated_at      TEXT NOT NULL
                    );
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

    def delete_files(self, paths: Iterable[str]) -> list[str]:
        """
        按相对路径删除文件缓存条目 (素材被移入 Deleted/ 后的数据侧同步)。

        返回被删除条目所关联的内容 hash 列表 (小写、已去重)，
        供调用方进一步判断是否要清理失去引用的用户覆盖记录。
        """
        targets = [p.replace("\\", "/") for p in paths if p]
        if not targets:
            return []

        removed_hashes: list[str] = []
        with self._lock:
            conn = self._get_conn()
            with conn:
                # 分批执行，防止 SQL 参数数量超限
                for i in range(0, len(targets), 500):
                    batch = targets[i : i + 500]
                    placeholders = ",".join("?" for _ in batch)
                    cursor = conn.execute(
                        f"SELECT hash FROM file_cache WHERE path IN ({placeholders})",
                        batch,
                    )
                    for row in cursor:
                        h = (row["hash"] or "").strip().lower()
                        if h:
                            removed_hashes.append(h)
                    conn.execute(
                        f"DELETE FROM file_cache WHERE path IN ({placeholders})",
                        batch,
                    )
        return list(dict.fromkeys(removed_hashes))

    def cleanup_orphan_hash_data(self, hashes: Iterable[str]) -> dict[str, int]:
        """
        清理指定 hash 的按内容寻址附属数据（用户覆盖记录 + 质检评分缓存）。

        仅当该 hash 在 file_cache 中已无任何文件引用时才删除，
        避免误删同内容副本（重复图）仍在使用中的覆盖数据或评分。

        返回: {"overrides": n, "qualities": n}
        """
        clean = list({(h or "").strip().lower() for h in hashes if h})
        result = {"overrides": 0, "qualities": 0}
        if not clean:
            return result

        with self._lock:
            conn = self._get_conn()
            with conn:
                for i in range(0, len(clean), 500):
                    batch = clean[i : i + 500]
                    placeholders = ",".join("?" for _ in batch)
                    rows = conn.execute(
                        f"SELECT hash FROM user_overrides WHERE hash IN ({placeholders})",
                        batch,
                    ).fetchall()
                    rows += conn.execute(
                        f"SELECT hash FROM quality_cache WHERE hash IN ({placeholders})",
                        batch,
                    ).fetchall()
                    for row in rows:
                        h = (row["hash"] or "").strip().lower()
                        if not h:
                            continue
                        still_used = conn.execute(
                            "SELECT 1 FROM file_cache WHERE hash = ? LIMIT 1", (h,)
                        ).fetchone()
                        if still_used:
                            continue
                        c1 = conn.execute(
                            "DELETE FROM user_overrides WHERE hash = ?", (h,)
                        )
                        result["overrides"] += 1 if c1.rowcount else 0
                        c2 = conn.execute(
                            "DELETE FROM quality_cache WHERE hash = ?", (h,)
                        )
                        if c2.rowcount:
                            result["qualities"] += 1
        return result

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
                        except Exception as e:
                            logger.warning(
                                "[cache_db] 质检详情 JSON 解析失败，跳过: %s", e
                            )
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
            rows.append(
                (
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
                )
            )

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

    def get_all_items(self, limit: int = 0) -> list[tuple[str, str]]:
        """
        获取全部已索引文件列表（含已评分），供 force 模式使用：
        返回: [(path, hash)]，limit<=0 时返回全量
        """
        with self._lock:
            conn = self._get_conn()
            if limit > 0:
                cursor = conn.execute(
                    "SELECT path, hash FROM file_cache WHERE hash != '' ORDER BY path ASC LIMIT ?",
                    (limit,),
                )
            else:
                cursor = conn.execute(
                    "SELECT path, hash FROM file_cache WHERE hash != '' ORDER BY path ASC"
                )
            return [(r["path"], r["hash"]) for r in cursor]

    def get_all_quality_scores(self) -> dict[str, dict[str, Any]]:
        """
        一次性 JOIN 返回 {path: quality_dict}，纯 SQLite 查询不碰文件系统。
        供质检完成后的前端轻量刷新使用，避免全量 rescan。
        """
        result: dict[str, dict[str, Any]] = {}
        with self._lock:
            conn = self._get_conn()
            cursor = conn.execute(
                """
                SELECT f.path, q.hash AS qhash, q.score, q.grade, q.status,
                       q.dead_zone_ratio, q.core_dead_ratio, q.border_dead_ratio,
                       q.flat_zone_ratio, q.crop_suggestion, q.can_upgrade,
                       q.max_grid, q.details_json, q.evaluated_at
                FROM file_cache f
                LEFT JOIN quality_cache q ON f.hash = q.hash
                WHERE f.hash != ''
                """,
            )
            for row in cursor:
                if not row["qhash"]:
                    continue
                details = {}
                if row["details_json"]:
                    try:
                        details = json.loads(row["details_json"])
                    except Exception:
                        pass
                result[row["path"]] = {
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

    # ------------------------------------------------------------------
    # user_overrides: 用户手动覆盖项 (裁切框 / tags / 扩展字段)
    # ------------------------------------------------------------------

    def get_user_override(self, hash_val: str) -> dict[str, Any] | None:
        """查询单张图片的用户覆盖项 (手动裁切框等)"""
        h = (hash_val or "").strip().lower()
        if not h:
            return None
        with self._lock:
            conn = self._get_conn()
            row = conn.execute(
                """SELECT hash, crop_x0, crop_y0, crop_x1, crop_y1, crop_ratio,
                          tags_json, extras_json, created_at, updated_at
                   FROM user_overrides WHERE hash = ?""",
                (h,),
            ).fetchone()
            if not row:
                return None
            return self._row_to_override(row)

    def get_all_user_overrides(self) -> dict[str, dict[str, Any]]:
        """批量返回 {hash: override_dict}，供前端 scan 后 merge"""
        result: dict[str, dict[str, Any]] = {}
        with self._lock:
            conn = self._get_conn()
            cursor = conn.execute(
                """SELECT hash, crop_x0, crop_y0, crop_x1, crop_y1, crop_ratio,
                          tags_json, extras_json, created_at, updated_at
                   FROM user_overrides"""
            )
            for row in cursor:
                h = row["hash"]
                result[h] = self._row_to_override(row)
        return result

    def set_user_override(
        self,
        hash_val: str,
        crop_box: tuple[float, float, float, float] | None = None,
        crop_ratio: str = "",
        tags: list[str] | None = None,
        extras: dict[str, Any] | None = None,
    ) -> bool:
        """
        插入或更新用户覆盖项 (REPLACE INTO 语义)。
        crop_box: (x0, y0, x1, y1) 百分比 0.0~1.0，None 表示不设置裁切框
        tags: 用户显式 tags 列表
        extras: 预留扩展字段 dict
        """
        h = (hash_val or "").strip().lower()
        if not h:
            return False
        now_iso = dt.datetime.now().isoformat(timespec="seconds")

        # 读取已有行（保留未更新的字段）
        existing = self.get_user_override(h) or {}

        cx0, cy0, cx1, cy1 = (
            crop_box
            if crop_box
            else (
                existing.get("crop_x0"),
                existing.get("crop_y0"),
                existing.get("crop_x1"),
                existing.get("crop_y1"),
            )
        )
        cr = (
            crop_ratio if crop_ratio is not None else (existing.get("crop_ratio") or "")
        )
        tags_s = (
            json.dumps(tags, ensure_ascii=False)
            if tags is not None
            else (existing.get("tags_json") or "")
        )
        extras_s = (
            json.dumps(extras, ensure_ascii=False)
            if extras is not None
            else (existing.get("extras_json") or "")
        )
        created = existing.get("created_at") or now_iso

        with self._lock:
            conn = self._get_conn()
            with conn:
                conn.execute(
                    """INSERT INTO user_overrides
                       (hash, crop_x0, crop_y0, crop_x1, crop_y1, crop_ratio,
                        tags_json, extras_json, created_at, updated_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                       ON CONFLICT(hash) DO UPDATE SET
                           crop_x0 = excluded.crop_x0,
                           crop_y0 = excluded.crop_y0,
                           crop_x1 = excluded.crop_x1,
                           crop_y1 = excluded.crop_y1,
                           crop_ratio = excluded.crop_ratio,
                           tags_json = excluded.tags_json,
                           extras_json = excluded.extras_json,
                           updated_at = excluded.updated_at""",
                    (h, cx0, cy0, cx1, cy1, cr, tags_s, extras_s, created, now_iso),
                )
        return True

    def delete_user_override(self, hash_val: str) -> bool:
        """删除单条用户覆盖项 (清除手动裁切框)"""
        h = (hash_val or "").strip().lower()
        if not h:
            return False
        with self._lock:
            conn = self._get_conn()
            with conn:
                conn.execute("DELETE FROM user_overrides WHERE hash = ?", (h,))
        return True

    @staticmethod
    def _row_to_override(row: sqlite3.Row) -> dict[str, Any]:
        """将数据库行转换为前端友好的 dict"""
        tags = []
        if row["tags_json"]:
            try:
                tags = json.loads(row["tags_json"])
            except Exception:
                pass
        extras = {}
        if row["extras_json"]:
            try:
                extras = json.loads(row["extras_json"])
            except Exception:
                pass
        has_crop = (
            row["crop_x0"] is not None
            and row["crop_y0"] is not None
            and row["crop_x1"] is not None
            and row["crop_y1"] is not None
        )
        return {
            "hash": row["hash"],
            "crop_x0": row["crop_x0"],
            "crop_y0": row["crop_y0"],
            "crop_x1": row["crop_x1"],
            "crop_y1": row["crop_y1"],
            "crop_ratio": row["crop_ratio"] or "",
            "has_crop": has_crop,
            "tags": tags,
            "extras": extras,
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    def get_stats(self) -> dict[str, Any]:
        """获取缓存状态与质检分布总览"""
        with self._lock:
            conn = self._get_conn()
            total_files = conn.execute("SELECT COUNT(*) FROM file_cache").fetchone()[0]
            total_scored = conn.execute(
                "SELECT COUNT(*) FROM quality_cache"
            ).fetchone()[0]

            grades: dict[str, int] = {}
            for r in conn.execute(
                "SELECT grade, COUNT(*) as c FROM quality_cache GROUP BY grade"
            ):
                grades[r["grade"]] = r["c"]

            statuses: dict[str, int] = {}
            for r in conn.execute(
                "SELECT status, COUNT(*) as c FROM quality_cache GROUP BY status"
            ):
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
