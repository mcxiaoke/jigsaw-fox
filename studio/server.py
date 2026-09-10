#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.server — Content Studio 本地打包工作台 HTTP 服务端
纯标准库实现 (无需额外 pip 安装第三方 web 框架)，轻量秒启。
"""

from __future__ import annotations

import argparse
import contextvars
import datetime as dt
import hashlib
import json
import logging
import mimetypes
import os
import shutil
import socket
import sys
import threading
import time
import urllib.parse
import uuid
import webbrowser
from concurrent.futures import ThreadPoolExecutor as _Pool
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

# 确保以独立脚本执行时 (如 python studio/server.py)，项目根目录在 sys.path 中
_pkg_dir = Path(__file__).resolve().parent
_root_dir = _pkg_dir.parent
if str(_root_dir) not in sys.path:
    sys.path.insert(0, str(_root_dir))

from studio.core.cache_db import CacheDB
from studio.core.export_rollback import list_ops, undo_op
from studio.core.export_tracker import get_exported_map, load_exported_ledger
from studio.core.exports_ledger import ExportsLedger
from studio.core.git_guard import (
    commit_after_export,
    commit_after_rollback,
    describe_status,
    ensure_repo,
    guard_export,
    load_mode,
)
from studio.core.image_proc import HAS_PIL, generate_thumbnail_bytes
from studio.core.quality_evaluator import evaluate_image, evaluate_images_batch
from studio.core.scanner import (
    build_manual_order,
    compute_file_sha256,
    find_duplicate_groups,
    find_tags_file,
    get_image_info,
    scan_image_infos,
    scan_images,
    sort_images,
)
from studio.core.tags_manager import (
    load_tags_file,
    merge_scanned_images,
    normalize_records,
    save_tags_file,
)
from studio.core.workspace import StudioWorkspace
from studio.exporters import get_exporter
from studio.exporters.base import (
    EXPORT_IMAGE_LIMITS,
    MAX_EXPORT_IMAGES_PER_JOB,
    resolve_export_limit,
)
from studio.taxonomy import (
    ALL_CANONICAL_TAGS,
    CATALOG_DEFS,
    CATALOG_TO_TAGS_MAP,
    MAIN_TAGS,
    MAIN_TAG_IDS,
    OTHERS_TAG,
    SPECIFIC_TAG_DEFS,
    TAG_TO_CATALOGS,
    TAG_ZH,
    guess_tags_from_path,
    normalize_token,
)

STATIC_DIR = Path(__file__).parent / "static"

# 导出类型 (前端 type) → 导出器 module 名（用于按类型解析数量上限等按模块维度的配置）
_EXPORT_MODULE_OF_TYPE = {
    "main": "main",
    "daily": "daily",
    "event": "events",
    "collection": "collections",
}

# 素材删除回收目录名：删除 = 把文件移入 <SourceDir>/.deleted/（软删除，可手工找回）。
# 以点开头，避免与正常素材目录在资源管理器中混在一起；scanner 对隐藏目录（. 开头）天然忽略，
# 故该目录不会被后续扫描重新纳入。
# LEGACY_DELETED_DIR_NAMES：历史版本曾使用 "Deleted"，一并视为回收目录（拒绝二次删除/不被扫描）。
DELETED_DIR_NAME = ".deleted"
LEGACY_DELETED_DIR_NAMES = ("Deleted",)


def _default_log_file() -> Path:
    """默认日志文件按日期命名 (temp/studio-YYYYMMDD.log)，每天一个新文件，不做大小轮转。"""
    stamp = dt.date.today().strftime("%Y%m%d")
    return _root_dir / "temp" / f"studio-{stamp}.log"


DEFAULT_LOG_FILE = _default_log_file()

logger = logging.getLogger("studio")


def _audit(root: Path | str | None, action: str, **fields: Any) -> None:
    """写入源库操作审计流水 (<src>/.studio/logs/operations.jsonl)。

    与导出审计 (exports.jsonl) 分离：这里记的是「人对素材库做了什么」
    （删除素材、手动裁切、质检、试导出确认等）。此前这些操作只在 HTTP
    访问行里留一个 URL，业务语义全丢，出问题无法回溯。

    尽力而为：写失败只告警，绝不打断主流程——审计不应导致操作失败。
    """
    if not root:
        return
    try:
        StudioWorkspace(Path(root)).record_audit(action, **fields)
    except Exception as e:
        logger.warning("[AUDIT] 写入操作审计失败 action=%s: %s", action, e)


def _estimate_ratio(fmt: str, quality: int) -> float:
    """按输出格式与压缩质量粗估「预计产物体积 / 原图体积」比例。

    仅用于导出前预览的诚实标注，不追求精确：
      webp  — 基准 0.20 (quality=70 时)，随 quality 幂次缩放
      jpg   — 基准 0.35 (quality=70 时)，随 quality 幂次缩放
      其他  — png / original 不转码，按原图计 1.0
    """
    f = (fmt or "").strip().lower()
    if f in ("jpg", "jpeg"):
        base = 0.35
    elif f == "webp":
        base = 0.20
    else:
        return 1.0
    try:
        q = max(1, min(100, int(quality)))
    except (TypeError, ValueError):
        q = 70
    return max(0.04, min(1.0, base * ((q / 70.0) ** 1.35)))


# ---------------------------------------------------------------------------
# 源库日志上下文：给日志行加 [src=库名] 前缀
# ---------------------------------------------------------------------------
# 单文件运行日志里同时混着「服务自身」与「对某个源库的操作」，出问题时无法一眼
# 分辨这行属于哪个库。这里用 contextvar 把当前请求绑定的源库记下来，由格式化器
# 输出 [src=库名] 前缀（库名取源目录末级目录名）。
#
# 已知边界：contextvar 默认不跨线程传播，因此线程池里产生的日志没有前缀。
# 目前只有质检 worker 是独立线程，已在 _quality_worker 内显式重新绑定。
_SRC_CTX: contextvars.ContextVar[str] = contextvars.ContextVar(
    "studio_src_label", default=""
)


def _src_label(root: Any) -> str:
    """把源库路径折算为日志前缀用的库名（末级目录名）；空值返回空串。"""
    if not root:
        return ""
    try:
        name = Path(str(root)).name
    except Exception:
        return ""
    return name or str(root)


def _bind_src(value: Any) -> None:
    """把某次请求/任务关联的源库绑定到当前上下文；无参数时显式清空，避免跨请求串味。"""
    _SRC_CTX.set(_src_label(value))


class _SrcContextFilter(logging.Filter):
    """把当前上下文的库名挂到 LogRecord 上，供 _SrcAwareFormatter 渲染前缀。"""

    def filter(self, record: logging.LogRecord) -> bool:
        record.src = _SRC_CTX.get() or ""
        return True


class _SrcAwareFormatter(logging.Formatter):
    """级别之后动态插入 [src=库名] 前缀；无源库上下文时不插入，避免噪音。"""

    def format(self, record: logging.LogRecord) -> str:
        src = getattr(record, "src", "")
        record.src_tag = f"[src={src}] " if src else ""
        return super().format(record)


def setup_logger(
    level_name: str = "INFO",
    logfile: Path | str | None = DEFAULT_LOG_FILE,
) -> logging.Logger:
    """
    配置 Content Studio 服务端日志：
    - 控制台输出：遵循请求级别 (默认为 INFO，启用 --debug 时为 DEBUG)
    - 文件日志输出：默认保存到 temp/studio-YYYYMMDD.log（按日期命名，每天一个新文件）
    - 级别策略：文件与控制台同一级别，默认 INFO；DEBUG（逐张缩略图、thumb 访问行等）
      只在 --debug 时落盘，否则单日日志会被缩略图噪音淹没
    - 前缀：日志行自动带 [src=库名]，标明该操作作用于哪个源库
    """
    level = getattr(logging, str(level_name).upper(), logging.INFO)
    logger.setLevel(logging.DEBUG)
    for h in list(logger.handlers):
        try:
            h.close()
        except Exception:
            pass
    logger.handlers.clear()

    # 1. 控制台 Handler
    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setLevel(level)
    console_fmt = _SrcAwareFormatter(
        "[%(asctime)s] [%(levelname)s] %(src_tag)s%(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    console_handler.setFormatter(console_fmt)
    console_handler.addFilter(_SrcContextFilter())
    logger.addHandler(console_handler)

    # 2. 文件日志 Handler (保存在 temp/ 目录)
    if logfile and str(logfile).strip().lower() not in ("none", "off", "false", ""):
        log_path = Path(logfile).resolve()
        try:
            log_path.parent.mkdir(parents=True, exist_ok=True)
            file_handler = logging.FileHandler(str(log_path), encoding="utf-8")
            file_handler.setLevel(level)
            file_fmt = _SrcAwareFormatter(
                "[%(asctime)s] [%(levelname)s] %(src_tag)s(%(filename)s:%(lineno)d) %(message)s",
                datefmt="%Y-%m-%d %H:%M:%S",
            )
            file_handler.setFormatter(file_fmt)
            file_handler.addFilter(_SrcContextFilter())
            logger.addHandler(file_handler)
        except Exception as e:
            logger.warning(f"无法创建日志文件 {log_path}: {e}")

    return logger


# 模块加载时默认初始化
setup_logger("INFO", DEFAULT_LOG_FILE)


# ---------------------------------------------------------------------------
# 导出任务状态注册表 (Export JobStore) — 仅服务「进度感知」只读观测通道
# ---------------------------------------------------------------------------
# 设计约束：
#   - 不带 clientTaskId 的导出不注册，整条导出路径与旧版完全一致；
#   - 所有读写持同一把锁；快照返回拷贝，绝无共享可变迭代；
#   - 本表任何故障都不影响导出主流程 (写入口被调用方 try 保护/内部判空)。
_JOB_LOCK = threading.Lock()
_JOBS: dict[str, dict[str, Any]] = {}
_JOB_MAX_KEEP = 50  # 最多保留最近 N 个任务
_JOB_TTL_SECONDS = 300.0  # 终态任务保留时长 (惰性清理，无定时器)

# 任务类型前缀约定：客户端生成 clientTaskId 时必须带类型前缀（见 _job_kind_of）。
# 前缀决定了并发互斥的粒度——同类任务互斥，异类任务互不阻塞。
_JOB_KIND_LABELS = {
    "quality": "质检",
    "export": "导出",
    "rollback": "回滚",
    "unknown": "未知类型",
}


def _job_kind_of(task_id: str) -> str:
    """从 taskId 前缀推断任务类型：'quality-*' / 'export-*'，无法识别时返回 unknown。"""
    t = (task_id or "").strip().lower()
    for kind in _JOB_KIND_LABELS:
        if kind == "unknown":
            continue
        if t.startswith(f"{kind}-") or t.startswith(f"{kind}_"):
            return kind
    return "unknown"


def _job_kind_label(kind: str) -> str:
    return _JOB_KIND_LABELS.get(kind, _JOB_KIND_LABELS["unknown"])


def _job_find_running(kind: str | None = None) -> list[str]:
    """列出处于 running 状态的任务 id；指定 kind 时只统计该类型。"""
    with _JOB_LOCK:
        return [
            k
            for k, v in _JOBS.items()
            if v.get("state") == "running"
            and (kind is None or v.get("kind") == kind)
        ]


def _job_cleanup_locked(now: float) -> None:
    """惰性清理：终态且超时的记录剔除；仍超上限时保留最近 N 条。须持锁调用。"""
    if len(_JOBS) <= _JOB_MAX_KEEP:
        return
    expired = [
        k
        for k, v in _JOBS.items()
        if v.get("state") in ("done", "error")
        and (now - float(v.get("created_at", 0))) >= _JOB_TTL_SECONDS
    ]
    for k in expired:
        _JOBS.pop(k, None)
    if len(_JOBS) > _JOB_MAX_KEEP:
        overflow = len(_JOBS) - _JOB_MAX_KEEP
        for k in sorted(_JOBS, key=lambda x: _JOBS[x].get("created_at", 0))[:overflow]:
            _JOBS.pop(k, None)


def _job_register(task_id: str, kind: str | None = None, exclusive: bool = True) -> bool:
    """注册任务；返回 False 表示已有同类型任务在跑（注册被拒）。

    「检查同类无 running」与「写入本任务」在同一把锁内完成，避免两个并发请求
    同时通过检查、双双注册而绕过互斥。
    """
    if not task_id:
        return True
    now = time.time()
    with _JOB_LOCK:
        k = kind or _job_kind_of(task_id)
        if exclusive:
            for v in _JOBS.values():
                if v.get("state") == "running" and v.get("kind") == k:
                    return False
        _job_cleanup_locked(now)
        _JOBS[task_id] = {
            "state": "running",
            "kind": k,
            "logs": [],
            "done": 0,
            "total": 0,
            "failed": 0,
            "summary": None,
            "error": None,
            "created_at": now,
        }
        return True


def _job_append_log(task_id: str, entry: dict[str, str]) -> None:
    if not task_id:
        return
    with _JOB_LOCK:
        job = _JOBS.get(task_id)
        if job is not None and job.get("state") == "running":
            job["logs"].append(entry)


def _job_progress(task_id: str, done: int, total: int, failed: int = 0) -> None:
    if not task_id:
        return
    with _JOB_LOCK:
        job = _JOBS.get(task_id)
        if job is not None:
            job["done"] = int(done)
            job["total"] = int(total)
            if failed:
                job["failed"] = int(failed)


def _job_finish(
    task_id: str,
    summary: str | None = None,
    error: str | None = None,
    cancelled: bool = False,
) -> None:
    if not task_id:
        return
    with _JOB_LOCK:
        job = _JOBS.get(task_id)
        if job is None:
            return
        if cancelled:
            # 用户主动取消是正常终态，与失败区分：前端据此显示"已取消"而非红色报错
            job["state"] = "cancelled"
        elif error is not None:
            job["state"] = "error"
            job["error"] = str(error)
        else:
            job["state"] = "done"
            job["summary"] = summary or ""


def _job_snapshot(task_id: str) -> dict[str, Any] | None:
    """返回任务状态快照 (拷贝)；未知任务返回 None。"""
    if not task_id:
        return None
    with _JOB_LOCK:
        job = _JOBS.get(task_id)
        if job is None:
            return None
        return {
            "state": job.get("state", "running"),
            "kind": job.get("kind", "unknown"),
            "logs": list(job.get("logs", [])),
            "done": job.get("done", 0),
            "total": job.get("total", 0),
            "failed": job.get("failed", 0),
            "summary": job.get("summary"),
            "error": job.get("error"),
        }


def _job_ensure_finished(task_id: str, error: str = "任务状态未知，已强制结束") -> None:
    """兜底收口：任务仍为 running 时强制置为 error，防止互斥锁被永久占用。"""
    if not task_id:
        return
    with _JOB_LOCK:
        job = _JOBS.get(task_id)
        if job is not None and job.get("state") == "running":
            job["state"] = "error"
            job["error"] = error


def _job_cancel(task_id: str) -> bool:
    """标记任务为取消；worker 在子批间检查并退出。返回是否成功标记。"""
    if not task_id:
        return False
    with _JOB_LOCK:
        job = _JOBS.get(task_id)
        if job is None:
            return False
        if job.get("state") != "running":
            return False
        job["cancel"] = True
        return True


def _job_is_cancelled(task_id: str) -> bool:
    """检查任务是否被取消。"""
    if not task_id:
        return False
    with _JOB_LOCK:
        job = _JOBS.get(task_id)
        return bool(job and job.get("cancel"))


# ---------------------------------------------------------------------------
# 质检后台 worker
# ---------------------------------------------------------------------------

_QUALITY_SUB_BATCH = 50  # 子批大小


def _run_quality_job(
    root: Path,
    targets: list[tuple[Path, str, str]],
    task_id: str,
    max_workers: int | None = None,
) -> None:
    """
    质检后台 worker：子批循环 -> evaluate_images_batch -> 落库 -> 进度回写。
    targets: [(full_path, rel_path, hash)]
    """
    total = len(targets)
    if total == 0:
        _job_finish(task_id, summary="无待质检图片")
        return

    _job_progress(task_id, 0, total)
    workers = max_workers or max(4, (os.cpu_count() or 8) - 4)
    done = 0
    failed = 0  # 评估异常导致整批丢失的图片数（进度照走但数据缺失，必须可见）
    consecutive_batch_failures = 0  # 连续整批失败计数（≥2 视为环境故障，中止任务）

    logger.info("[QUALITY] %s 开始: 共 %d 张, %d 线程", task_id, total, workers)

    with CacheDB(root) as db:
        for i in range(0, total, _QUALITY_SUB_BATCH):
            if _job_is_cancelled(task_id):
                _job_finish(task_id, cancelled=True)
                logger.info("[QUALITY] %s 已取消: %d/%d", task_id, done, total)
                return

            sub = targets[i : i + _QUALITY_SUB_BATCH]
            sub_paths = [t[0] for t in sub]

            logger.info(
                "[QUALITY] %s 进度: %d/%d (剩余 %d)",
                task_id,
                done,
                total,
                total - done,
            )

            try:
                results = evaluate_images_batch(sub_paths, max_workers=workers)
            except Exception as e:
                logger.error("[QUALITY] %s 子批异常: %s", task_id, e)
                results = []

            if not results:
                # 整批评估失败（环境故障如 venv/cv2 崩溃）：进度照走，但计入失败
                # 并累计连续失败；连续 2 个整批全失败即中止，绝不伪装成"质检完成"
                failed += len(sub)
                consecutive_batch_failures += 1
                _job_append_log(
                    task_id,
                    {
                        "t": dt.datetime.now().strftime("%H:%M:%S"),
                        "level": "warn",
                        "msg": f"警告: 本批 {len(sub)} 张评估全部失败 (连续第 {consecutive_batch_failures} 批), 累计失败 {failed} 张",
                    },
                )
                if consecutive_batch_failures >= 2:
                    logger.error(
                        "[QUALITY] %s 连续 %d 个子批全部失败，中止质检任务",
                        task_id,
                        consecutive_batch_failures,
                    )
                    _job_finish(
                        task_id,
                        error=f"质检环境异常: 连续 {consecutive_batch_failures} 个批次评估全部失败 (累计 {failed} 张)，任务已中止。请检查 OpenCV/Pillow 环境后重试。",
                    )
                    return
                done += len(sub)
                _job_progress(task_id, done, total, failed=failed)
                continue

            consecutive_batch_failures = 0

            rows = []
            for idx, res in enumerate(results):
                if idx < len(sub):
                    _, rel, file_h = sub[idx]
                    h = file_h or compute_file_sha256(sub[idx][0])
                    rows.append((h, res))

            if rows:
                db.save_qualities_batch(rows)

            done += len(sub)
            _job_progress(task_id, done, total, failed=failed)
            _job_append_log(
                task_id,
                {
                    "t": dt.datetime.now().strftime("%H:%M:%S"),
                    "level": "info",
                    "msg": f"已评估 {done}/{total} 张",
                },
            )

    logger.info("[QUALITY] %s 完成: %d/%d 张", task_id, done, total)
    if failed > 0:
        _job_finish(
            task_id,
            summary=f"质检完成: {done}/{total} 张 (其中 {failed} 张评估失败，无评分数据)",
        )
    else:
        _job_finish(task_id, summary=f"质检完成: {done}/{total} 张")


class StudioRequestHandler(BaseHTTPRequestHandler):
    """请求处理器：路由分发、API 响应与静态资源托管"""

    current_root_dir: Path | None = None

    def log_message(self, fmt: str, *args: Any) -> None:
        msg = fmt % args
        status_code = 0
        if len(args) >= 2:
            try:
                status_code = int(args[1])
            except (ValueError, TypeError):
                status_code = 0

        req_line = getattr(self, "requestline", "") or (args[0] if args else "")
        req_line_s = str(req_line)

        if status_code >= 500:
            logger.error(f"[HTTP] {msg}")
        elif status_code >= 400:
            logger.warning(f"[HTTP] {msg}")
        elif (
            "/api/thumb" in req_line_s
            or "/static/" in req_line_s
            or "/favicon.ico" in req_line_s
            or "/api/health" in req_line_s
        ):
            logger.debug(f"[HTTP] {msg}")
        else:
            logger.info(f"[HTTP] {msg}")

    def _cors(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Cache-Control")

    def _json(self, data: Any, status: int = 200) -> None:
        body = json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def _error(self, message: str, status: int = 400) -> None:
        self._json({"ok": False, "error": message}, status=status)

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self._cors()
        self.end_headers()

    # -----------------------------------------------------------------------
    # GET 路由分发
    # -----------------------------------------------------------------------
    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)

        # 日志前缀：绑定本次请求的源库（无 dir/srcDir 参数时清空，避免跨请求串味）
        _bind_src((qs.get("dir") or qs.get("srcDir") or [""])[0].strip())

        # 1. 首页与静态文件
        if path in ("/", "/index.html"):
            self._serve_static_file(
                STATIC_DIR / "index.html", "text/html; charset=utf-8"
            )
            return

        if path in ("/rollback", "/rollback.html"):
            self._serve_static_file(
                STATIC_DIR / "rollback.html", "text/html; charset=utf-8"
            )
            return

        if path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
            return

        if path.startswith("/static/"):
            rel_path = path[len("/static/") :]
            target = STATIC_DIR / rel_path
            if target.exists() and target.is_file():
                ctype, _ = mimetypes.guess_type(str(target))
                self._serve_static_file(target, ctype or "application/octet-stream")
                return

        # 2. API 路由
        if path == "/api/health":
            self._json({"ok": True, "has_pil": HAS_PIL})
            return

        if path == "/api/taxonomy":
            self._handle_taxonomy()
            return

        if path == "/api/scan":
            self._handle_scan(qs)
            return

        if path == "/api/tags":
            self._handle_get_tags(qs)
            return

        if path == "/api/export/limits":
            self._handle_export_limits()
            return

        if path in ("/api/export/status", "/api/job/status"):
            self._handle_job_status(qs)
            return

        if path == "/api/thumb":
            self._handle_thumb(qs)
            return

        if path == "/api/file":
            self._handle_file(qs)
            return

        if path == "/api/quality":
            self._handle_get_quality(qs)
            return

        if path == "/api/quality/stats":
            self._handle_get_quality_stats(qs)
            return

        if path == "/api/quality/scores":
            self._handle_get_quality_scores(qs)
            return

        if path == "/api/crop/manual":
            self._handle_get_manual_crops(qs)
            return

        if path == "/api/ledger/ops":
            self._handle_ledger_ops(qs)
            return

        if path == "/api/ledger/records":
            self._handle_ledger_records(qs)
            return

        if path == "/api/ledger/audit":
            self._handle_ledger_audit(qs)
            return

        # 兜底查找静态文件
        cand = STATIC_DIR / path.lstrip("/")
        if cand.exists() and cand.is_file():
            ctype, _ = mimetypes.guess_type(str(cand))
            self._serve_static_file(cand, ctype or "application/octet-stream")
            return

        self.send_error(404, f"Not Found: {path}")

    # -----------------------------------------------------------------------
    # POST 路由分发
    # -----------------------------------------------------------------------
    def do_POST(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        length = int(self.headers.get("Content-Length", 0))
        body_bytes = self.rfile.read(length) if length > 0 else b""

        try:
            data = json.loads(body_bytes.decode("utf-8")) if body_bytes else {}
        except Exception as e:
            self._error(f"JSON 解析失败: {e}", status=400)
            return

        # 日志前缀：绑定本次请求的源库（无 dir/srcDir 字段时清空，避免跨请求串味）
        _bind_src(data.get("dir") or data.get("srcDir") or "")

        if path == "/api/tags":
            self._handle_post_tags(data)
            return

        if path == "/api/export":
            self._handle_export(data)
            return

        if path == "/api/export/preview":
            self._handle_export_preview(data)
            return

        if path == "/api/quality/batch":
            self._handle_post_quality_batch(data)
            return

        if path == "/api/quality/cancel":
            self._handle_quality_cancel(data)
            return

        if path == "/api/crop/manual":
            self._handle_post_manual_crop(data)
            return

        if path == "/api/delete":
            self._handle_delete_image(data)
            return

        if path == "/api/rollback":
            self._handle_rollback(data)
            return

        self.send_error(404, f"Not Found POST: {path}")

    # -----------------------------------------------------------------------
    # 具体 API 业务处理
    # -----------------------------------------------------------------------
    def _handle_taxonomy(self) -> None:
        """返回完整的分类法元数据（前端单一事实源）"""
        self._json(
            {
                "ok": True,
                "tags": MAIN_TAGS,
                "main_tags": MAIN_TAGS,
                "catalogs": MAIN_TAGS,
                "specific_tags": MAIN_TAGS,
                "tag_zh": TAG_ZH,
                "catalog_to_tags": CATALOG_TO_TAGS_MAP,
                "tag_to_catalogs": TAG_TO_CATALOGS,
                "all_canonical_tags": ALL_CANONICAL_TAGS,
            }
        )

    def _handle_scan(self, qs: dict[str, list[str]]) -> None:
        """扫描指定目录下的图片，并加载或推断标签与防重导出状态"""
        dir_param = (qs.get("dir") or [""])[0].strip()
        if not dir_param:
            self._error("缺少必要参数 ?dir=PATH")
            return

        root = Path(dir_param).resolve()
        if not root.exists():
            self._error(f"指定目录不存在: {dir_param}", status=404)
            return
        if not root.is_dir():
            self._error(f"指定路径不是目录: {dir_param}", status=400)
            return

        StudioRequestHandler.current_root_dir = root
        tag_file = find_tags_file(root)
        existing_records = None
        format_name = None

        with CacheDB(root) as db:
            # 优先加载 SQLite 算力缓存，确保哪怕未点保存也能 0ms 秒级恢复
            hash_cache: dict[str, tuple[int, int, str, int, int, str]] = dict(
                db.load_file_cache()
            )

            if tag_file:
                raw_data, err = load_tags_file(tag_file)
                if not err and raw_data:
                    existing_records, format_name = normalize_records(raw_data, root)
                    for r in existing_records:
                        p_k = r.get("path", "").replace("\\", "/")
                        if p_k and r.get("hash") and p_k not in hash_cache:
                            hash_cache[p_k] = (
                                int(r.get("mtime", 0)),
                                int(r.get("size", 0)),
                                str(r.get("hash", "")),
                                int(r.get("width", 0)),
                                int(r.get("height", 0)),
                                str(r.get("format", "")),
                            )

            images = scan_images(root)
            total_images = len(images)
            logger.info(
                f"[SCAN] 开始扫描目录: {root.resolve()} (发现 {total_images:,} 个图片文件)"
            )

            scan_stats: dict[str, Any] = {}
            start_time = time.time()
            last_log_time = 0.0

            def _on_progress(
                completed: int, total: int, cache_hits: int, new_hashes: int
            ) -> None:
                nonlocal last_log_time
                now = time.time()
                if (
                    completed == 1
                    or completed == total
                    or completed % 500 == 0
                    or (now - last_log_time >= 1.0)
                ):
                    last_log_time = now
                    pct = (completed / total * 100) if total else 100.0
                    logger.info(
                        f"[SCAN] 进度: {completed:,}/{total:,} ({pct:.1f}%) | "
                        f"缓存命中: {cache_hits:,} | 新计Hash: {new_hashes:,}"
                    )

            image_infos = scan_image_infos(
                images,
                root,
                hash_cache=hash_cache,
                progress_callback=_on_progress,
                stats_out=scan_stats,
            )
            elapsed = max(time.time() - start_time, 0.001)
            speed = len(images) / elapsed

            # 立即将新发现或更新的图像元数据增量固化至 SQLite 底层数据库，并清理废弃路径
            db.upsert_files(list(image_infos.values()))
            db.prune_missing_files(list(image_infos.keys()))

            records, stats = merge_scanned_images(
                images, root, existing_records, image_infos=image_infos
            )
            img_infos = list(image_infos.values())

            # 读取权威导出账本 (.studio/ledger/exports.json) 并关联到每条记录
            exp_ledger = load_exported_ledger(root)
            exp_hashes = exp_ledger.get("hashes", {})
            exp_map = get_exported_map(root)
            exported_count = 0

            for r in records:
                h = (r.get("hash") or "").strip().lower()
                rel = r.get("path", "").replace("\\", "/")
                exp_info = exp_hashes.get(h) or exp_map.get(rel)
                if exp_info:
                    r["exported"] = exp_info
                    exported_count += 1
                else:
                    r["exported"] = None

            stats["exportedCount"] = exported_count
            stats["unexportedCount"] = len(records) - exported_count

            # 批量装配已有的 OpenCV 物理质检评分缓存
            all_hashes = [r.get("hash") for r in records if r.get("hash")]
            qualities = db.get_qualities(all_hashes)
            scored_count = 0
            for r in records:
                h = (r.get("hash") or "").strip().lower()
                q = qualities.get(h)
                if q:
                    r["quality"] = q
                    scored_count += 1
                else:
                    r["quality"] = None

            db_stats = db.get_stats()
            stats["scoredCount"] = scored_count
            stats["unscoredCount"] = len(records) - scored_count
            stats["qualitySummary"] = db_stats

            # 检测并打印重复图片警告日志
            dup_groups = find_duplicate_groups(records)
            if dup_groups:
                total_dup_files = sum(len(g) for g in dup_groups.values())
                logger.warning(
                    f"[DUP] ⚠️ 检测到 {len(dup_groups)} 组内容重复的图片文件 (共 {total_dup_files} 个文件):"
                )
                for idx, (h, group) in enumerate(dup_groups.items(), 1):
                    logger.warning(f"[DUP] ── 组 {idx} [SHA-256: {h[:16]}...]:")
                    for it in group:
                        p_name = it.get("path") or it.get("file")
                        real_tags = [
                            t for t in (it.get("tags") or []) if t.lower() != "others"
                        ]
                        tag_str = (
                            f"[{', '.join(real_tags)}]"
                            if real_tags
                            else "[未分类/无标签]"
                        )
                        logger.warning(f"[DUP]    • {p_name} (标签: {tag_str})")
            else:
                logger.info("[SCAN] 重复性检查: 未发现内容重复的文件 (0 重复)")

            # 标记每条记录的重复状态
            for r in records:
                h = (r.get("hash") or "").strip().lower()
                if h and h in dup_groups:
                    r["is_duplicate"] = True
                    r["duplicate_with"] = [
                        (o.get("path") or o.get("file"))
                        for o in dup_groups[h]
                        if (o.get("path") or o.get("file")) != r.get("path")
                    ]
                else:
                    r["is_duplicate"] = False
                    r["duplicate_with"] = []

            stats["duplicateGroups"] = len(dup_groups)
            stats["duplicateCount"] = sum(len(g) for g in dup_groups.values())
            stats["duplicateHashes"] = list(dup_groups.keys())

        logger.info(
            f"[SCAN] 扫描完成: 共 {len(images):,} 张图片，耗时 {elapsed:.2f}s ({speed:.0f} 张/秒) | "
            f"缓存命中: {scan_stats.get('cache_hits', 0):,} | 新增哈希: {scan_stats.get('new_hashes', 0):,} | "
            f"错误: {scan_stats.get('errors', 0):,}"
        )
        logger.info(
            f"[SCAN] 状态统计: 总记录 {len(records):,} 条 | 已导出: {exported_count:,} 条 | 未导出: {len(records) - exported_count:,} 条"
        )
        if stats.get("duplicateCount", 0) > 0:
            logger.warning(
                f"[SCAN] 重复统计: 存在 {stats['duplicateGroups']} 组重复素材，共计 {stats['duplicateCount']} 个文件"
            )

        # 每次扫描结束后自动备份权威账本快照，便于账本 JSON 损坏被重置时手工 copy 回滚
        try:
            from studio.core.exports_ledger import backup_ledger_snapshot

            backup_ledger_snapshot(root)
        except Exception:
            pass

        # .studio git 守卫状态可见性：扫描后输出一行状态摘要（只读，不产生任何 git 操作）
        try:
            logger.info("[GIT_GUARD] %s", describe_status(root / ".studio"))
        except Exception:
            pass

        self._json(
            {
                "ok": True,
                "dir": str(root.resolve()),
                "tagFile": str(tag_file.resolve()) if tag_file else None,
                "tagFormat": format_name,
                "records": records,
                "stats": stats,
                "images": img_infos,
                "total": len(img_infos),
                "totalExported": exp_ledger.get("total_exported", 0),
            }
        )

    def _resolve_image_path(self, path_s: str, qs: dict[str, list[str]]) -> Path | None:
        """多策略路径解析：直接绝对路径、相对路径与允许根目录拼接。

        安全边界：解析结果必须落在「允许根目录」之内。允许根按优先级取
        ① 请求显式携带的 ?dir= 目录；② 最近一次成功扫描的 current_root_dir。
        允许根为空时一律拒绝——在未指定工作目录的情况下不接受任何路径，
        避免 /api/file、/api/thumb 被用作读取本机任意文件的通道。
        """
        if not path_s or not str(path_s).strip():
            return None
        decoded = urllib.parse.unquote(path_s).strip()
        candidates = [Path(decoded), Path(path_s)]

        allowed_roots: list[Path] = []
        dir_param = (qs.get("dir") or [""])[0].strip()
        if dir_param:
            try:
                dp = Path(dir_param).resolve()
                if dp.is_dir():
                    allowed_roots.append(dp)
            except Exception:
                pass
        cur = StudioRequestHandler.current_root_dir
        if cur:
            try:
                cp = Path(cur).resolve()
                if cp.is_dir() and cp not in allowed_roots:
                    allowed_roots.append(cp)
            except Exception:
                pass
        if not allowed_roots:
            return None

        def _within(cand: Path) -> Path | None:
            """候选路径存在且位于任一允许根内时返回其绝对路径，否则 None。"""
            try:
                rp = cand.resolve()
            except Exception:
                return None
            try:
                if not rp.is_file():
                    return None
            except Exception:
                return None
            for r in allowed_roots:
                if rp == r or r in rp.parents:
                    return rp
            return None

        # 1. 候选路径本身可直达（绝对路径，或相对当前工作目录）
        for cand in candidates:
            got = _within(cand)
            if got:
                return got

        # 2. 相对路径与允许根目录拼接（绝对路径已在上一步处理，跳过）
        for root in allowed_roots:
            for cand in candidates:
                if cand.is_absolute():
                    continue
                got = _within(root / cand)
                if got:
                    return got

        return None

    def _handle_get_tags(self, qs: dict[str, list[str]]) -> None:
        """读取 tags.json 并关联导出状态"""
        dir_param = (qs.get("dir") or [""])[0].strip()
        if not dir_param:
            self._error("缺少 ?dir 参数")
            return

        root = Path(dir_param)
        tag_file = find_tags_file(root)
        if not tag_file:
            self._error("未找到 tags.json 文件", status=404)
            return

        raw, err = load_tags_file(tag_file)
        if err:
            self._error(f"读取失败: {err}", status=500)
            return

        records, _ = normalize_records(raw, root)
        exp_ledger = load_exported_ledger(root)
        exp_hashes = exp_ledger.get("hashes", {})
        exp_map = get_exported_map(root)

        dup_groups = find_duplicate_groups(records)
        for r in records:
            h = (r.get("hash") or "").strip().lower()
            rel = r.get("path", "").replace("\\", "/")
            exp_info = exp_hashes.get(h) or exp_map.get(rel)
            r["exported"] = exp_info if exp_info else None
            if h and h in dup_groups:
                r["is_duplicate"] = True
                r["duplicate_with"] = [
                    (o.get("path") or o.get("file"))
                    for o in dup_groups[h]
                    if (o.get("path") or o.get("file")) != r.get("path")
                ]
            else:
                r["is_duplicate"] = False
                r["duplicate_with"] = []

        self._json({"ok": True, "file": str(tag_file.resolve()), "records": records})

    def _handle_job_status(self, qs: dict[str, list[str]]) -> None:
        """任务进度状态快照 (只读观测通道，供前端轮询)；导出与质检共用"""
        task_id = (qs.get("task") or [""])[0].strip()
        snap = _job_snapshot(task_id)
        if snap is None:
            self._json({"ok": False, "found": False})
            return
        snap["ok"] = True
        snap["found"] = True
        self._json(snap)

    def _handle_post_tags(self, data: dict[str, Any]) -> None:
        """原子写回保存 tags.json"""
        dir_param = (data.get("dir") or "").strip()
        records = data.get("records")
        if not dir_param or records is None:
            self._error("缺少必要参数 dir 或 records")
            return

        root = Path(dir_param)
        if not root.exists() or not root.is_dir():
            self._error(f"目录不存在: {dir_param}", status=404)
            return

        tag_warnings: list[str] = []
        ok, msg, saved, auto_skipped = save_tags_file(root, records, warnings_out=tag_warnings)
        if ok:
            logger.info(f"[TAGS] 保存成功: 文件={msg}, 手动={saved}, 自动跳过={auto_skipped}")
            self._json({
                "ok": True,
                "file": msg,
                "saved": saved,
                "autoSkipped": auto_skipped,
                **({"warning": tag_warnings[0]} if tag_warnings else {}),
            })
        else:
            logger.error(f"[TAGS] 保存失败: {msg}")
            self._error(f"保存失败: {msg}", status=500)

    def _handle_get_quality(self, qs: dict[str, list[str]]) -> None:
        """获取或现场执行单张图片的 OpenCV 物理质检与裁剪建议"""
        path_s = (qs.get("path") or [""])[0].strip()
        hash_s = (qs.get("hash") or [""])[0].strip().lower()
        force = (qs.get("force") or ["0"])[0] == "1"
        dir_param = (qs.get("dir") or [""])[0].strip()

        img_path = self._resolve_image_path(path_s, qs)
        if not img_path or not img_path.is_file():
            self._error(f"图片不存在或无法访问: {path_s}", status=404)
            return

        root = (
            Path(dir_param).resolve()
            if dir_param
            else (StudioRequestHandler.current_root_dir or img_path.parent)
        )

        with CacheDB(root) as db:
            file_hash = hash_s
            if not file_hash:
                try:
                    file_hash = compute_file_sha256(img_path)
                except Exception:
                    file_hash = ""

            # 命中缓存直接返回
            if not force and file_hash:
                cached = db.get_quality(file_hash)
                if cached:
                    self._json(
                        {
                            "ok": True,
                            "hash": file_hash,
                            "quality": cached,
                            "cached": True,
                        }
                    )
                    return

            # 现场计算并入库
            try:
                res = evaluate_image(img_path)
                if file_hash:
                    db.save_quality(file_hash, res)
                self._json(
                    {"ok": True, "hash": file_hash, "quality": res, "cached": False}
                )
            except Exception as e:
                logger.error(f"[QUALITY] 质检计算异常 ({path_s}): {e}")
                self._error(f"质检计算失败: {e}", status=500)

    def _handle_get_quality_stats(self, qs: dict[str, list[str]]) -> None:
        """获取当前工作目录的质检统计总览"""
        dir_param = (qs.get("dir") or [""])[0].strip()
        root = (
            Path(dir_param).resolve()
            if dir_param
            else StudioRequestHandler.current_root_dir
        )
        if not root or not root.is_dir():
            self._error("缺少有效目录 ?dir 参数")
            return
        with CacheDB(root) as db:
            self._json({"ok": True, "stats": db.get_stats()})

    def _handle_get_quality_scores(self, qs: dict[str, list[str]]) -> None:
        """轻量端点：纯 SQLite 查询返回 {path: quality}，不碰文件系统"""
        dir_param = (qs.get("dir") or [""])[0].strip()
        root = (
            Path(dir_param).resolve()
            if dir_param
            else StudioRequestHandler.current_root_dir
        )
        if not root or not root.is_dir():
            self._error("缺少有效目录 ?dir 参数")
            return
        with CacheDB(root) as db:
            scores = db.get_all_quality_scores()
            stats = db.get_stats()
        self._json({"ok": True, "scores": scores, "stats": stats})

    # ------------------------------------------------------------------
    # 手动裁切框 API
    # ------------------------------------------------------------------

    # ------------------------------------------------------------------
    # 台账 / 回滚 API（见 docs/rollback-plan-20260910.md）
    # ------------------------------------------------------------------

    def _ledger_dir_param(self, dir_param: str) -> Path | None:
        """解析台账接口的 ?dir 参数；为空回退 current_root_dir。"""
        root = (
            Path(dir_param).resolve()
            if dir_param
            else StudioRequestHandler.current_root_dir
        )
        if not root or not root.is_dir():
            return None
        return root

    def _handle_ledger_ops(self, qs: dict[str, list[str]]) -> None:
        """GET /api/ledger/ops?dir=... — 按操作聚合的可撤销导出列表（只读）"""
        root = self._ledger_dir_param((qs.get("dir") or [""])[0].strip())
        if not root:
            self._error("缺少有效目录 ?dir 参数")
            return
        try:
            ops = list_ops(root)
        except Exception as e:
            self._error(f"读取台账失败: {e}", status=500)
            return
        legacy = [o for o in ops if not o.get("opId")]
        self._json(
            {
                "ok": True,
                "ops": ops,
                "legacyCount": len(legacy),
                "totalRecords": sum(int(o.get("count") or 0) for o in ops),
            }
        )

    def _handle_ledger_records(self, qs: dict[str, list[str]]) -> None:
        """GET /api/ledger/records?dir=...&op=op_xxx — 单次导出的文件级记录"""
        root = self._ledger_dir_param((qs.get("dir") or [""])[0].strip())
        if not root:
            self._error("缺少有效目录 ?dir 参数")
            return
        op_id = (qs.get("op") or [""])[0].strip()
        if not op_id:
            self._error("缺少 op 参数", status=400)
            return
        try:
            ledger = ExportsLedger(root, read_only=True)
        except Exception as e:
            self._error(f"读取台账失败: {e}", status=500)
            return
        records = [r for r in ledger.records if r.get("opId") == op_id]
        superseded = ledger._superseded_ids
        for r in records:
            r = r  # noqa: 保持可读；字段透传
        self._json(
            {
                "ok": True,
                "opId": op_id,
                "records": records,
                "supersededIds": sorted(str(s) for s in superseded & {r.get("recordId") for r in records if r.get("recordId")}),
            }
        )

    def _handle_ledger_audit(self, qs: dict[str, list[str]]) -> None:
        """GET /api/ledger/audit?dir=...&limit=50 — 回滚审计事件 + 快照备份列表"""
        root = self._ledger_dir_param((qs.get("dir") or [""])[0].strip())
        if not root:
            self._error("缺少有效目录 ?dir 参数")
            return
        try:
            limit = max(1, min(500, int((qs.get("limit") or ["50"])[0])))
        except ValueError:
            limit = 50
        ws = StudioWorkspace(root, read_only=True)
        events_file = ws.ledger_dir / "exports_events.jsonl"
        events: list[dict[str, Any]] = []
        if events_file.exists():
            try:
                lines = events_file.read_text(encoding="utf-8").strip().splitlines()
                for line in reversed(lines[-limit * 5:] if limit * 5 < len(lines) else lines):
                    if len(events) >= limit:
                        break
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        ev = json.loads(line)
                    except Exception:
                        continue
                    # 只保留与回滚审计相关的动作
                    if ev.get("action") in ("rollback", "append"):
                        if ev.get("action") == "append":
                            # append 过多，仅保留 op 级首次出现由前端聚合；此处直接跳过 append
                            continue
                        events.append(ev)
            except Exception as e:
                logger.warning(f"[LEDGER_AUDIT] 读取事件流失败: {e}")
        backups: list[dict[str, Any]] = []
        backup_dir = ws.ledger_dir / "backups"
        if backup_dir.is_dir():
            for f in sorted(backup_dir.glob("*"), key=lambda p: p.name, reverse=True):
                if f.is_file():
                    try:
                        stat = f.stat()
                        backups.append(
                            {
                                "name": f.name,
                                "size": stat.st_size,
                                "mtime": stat.st_mtime,
                            }
                        )
                    except Exception:
                        continue
        self._json({"ok": True, "events": events, "backups": backups[:100]})

    def _handle_rollback(self, data: dict[str, Any]) -> None:
        """POST /api/rollback — 回滚预览 (dryRun) 或执行回滚 (confirm)"""
        dir_param = (data.get("dir") or "").strip()
        root = self._ledger_dir_param(dir_param)
        if not root:
            self._error("缺少有效目录 dir 参数")
            return
        op_id = (data.get("opId") or "").strip()
        if not op_id:
            self._error("缺少 opId 参数", status=400)
            return
        dry_run = bool(data.get("dryRun"))
        confirm = bool(data.get("confirm"))
        if not dry_run and not confirm:
            self._error("回滚为高危操作：预览请传 dryRun=true，执行请传 confirm=true", status=400)
            return
        reason = str(data.get("reason") or "").strip()[:500]
        clean_release = data.get("cleanRelease") is not False

        # 与导出/质检同款任务互斥：回滚同时改账本与 release，禁止并发回滚/导出/质检
        task_id = f"rollback-{uuid.uuid4().hex[:12]}"
        if not _job_register(task_id, kind="rollback"):
            running = _job_find_running(kind="rollback")
            self._error(
                f"{_job_kind_label('rollback')}任务正在进行中: {running[0] if running else '(未知)'}，请稍后再试",
                status=409,
            )
            return

        try:
            # 回滚与导出/质检也互斥（三者都会写账本或 release）
            for other_kind in ("export", "quality"):
                if _job_find_running(kind=other_kind):
                    _job_finish(task_id, error="interrupted by running job")
                    self._error(
                        f"{_job_kind_label(other_kind)}任务正在进行中，回滚必须等待其结束（防止账本/镜像写入冲突）",
                        status=409,
                    )
                    return
            result = undo_op(root, op_id, dry_run=dry_run, clean_release=clean_release, reason=reason)
            # Path 对象（如 snapshotLedger）转为可序列化字符串
            def _jsonable(v: Any) -> Any:
                if isinstance(v, Path):
                    return str(v)
                if isinstance(v, dict):
                    return {k: _jsonable(x) for k, x in v.items()}
                if isinstance(v, (list, tuple)):
                    return [_jsonable(x) for x in v]
                return v
            result = _jsonable(result)
            if result.get("ok") and not result.get("dryRun"):
                # 回滚成功后提交账本/流水变化（尽力而为，失败不影响响应）
                commit_after_rollback(
                    root / ".studio",
                    modules=result.get("modules") or [],
                    op_id=op_id,
                    reason=reason,
                )
            _job_finish(task_id, summary=result.get("msg") or ("" if result.get("ok") else "rollback failed"))
            self._json(result)
        except Exception as e:
            _job_finish(task_id, error=str(e))
            logger.exception(f"[ROLLBACK] 执行异常: {e}")
            self._error(f"回滚执行失败: {e}", status=500)

    def _handle_get_manual_crops(self, qs: dict[str, list[str]]) -> None:
        """GET /api/crop/manual?dir=... — 批量返回所有用户手动裁切框"""
        dir_param = (qs.get("dir") or [""])[0].strip()
        root = (
            Path(dir_param).resolve()
            if dir_param
            else StudioRequestHandler.current_root_dir
        )
        if not root or not root.is_dir():
            self._error("缺少有效目录 ?dir 参数")
            return
        with CacheDB(root) as db:
            overrides = db.get_all_user_overrides()
        # 只返回有裁切框的条目
        crops = {h: o for h, o in overrides.items() if o.get("has_crop")}
        logger.info(f"[MANUAL_CROP] GET overrides: dir={root}, count={len(crops)}")
        self._json({"ok": True, "overrides": crops})

    def _handle_post_manual_crop(self, data: dict[str, Any]) -> None:
        """POST /api/crop/manual — 保存或更新用户手动裁切框"""
        hash_val = (data.get("hash") or "").strip().lower()
        if not hash_val:
            self._error("缺少 hash 参数", status=400)
            return

        dir_param = (data.get("dir") or "").strip()
        root = (
            Path(dir_param).resolve()
            if dir_param
            else StudioRequestHandler.current_root_dir
        )
        if not root or not root.is_dir():
            self._error("缺少有效目录 dir 参数", status=400)
            return

        x0 = data.get("x0")
        y0 = data.get("y0")
        x1 = data.get("x1")
        y1 = data.get("y1")
        ratio = data.get("ratio") or ""

        # 校验百分比范围
        coords = []
        for v in (x0, y0, x1, y1):
            if v is not None:
                fv = float(v)
                if not (0.0 <= fv <= 1.0):
                    self._error(f"裁切框坐标必须在 0.0~1.0 范围内: {v}", status=400)
                    return
                coords.append(fv)
            else:
                coords.append(None)

        crop_box = None
        if all(c is not None for c in coords):
            if coords[2] <= coords[0] or coords[3] <= coords[1]:
                self._error("裁切框 x1/y1 必须大于 x0/y0", status=400)
                return
            crop_box = (coords[0], coords[1], coords[2], coords[3])

        with CacheDB(root) as db:
            ok = db.set_user_override(hash_val, crop_box=crop_box, crop_ratio=ratio)
        logger.info(
            f"[MANUAL_CROP] POST save: hash={hash_val[:16]}... "
            f"box=({coords[0]:.4f},{coords[1]:.4f},{coords[2]:.4f},{coords[3]:.4f}) "
            f"ratio={ratio} ok={ok}"
        )
        _audit(
            root,
            "crop_manual_save",
            scope="crop",
            entity=hash_val,
            after={
                "cropBox": list(crop_box) if crop_box else None,
                "ratio": ratio,
                "ok": ok,
            },
            result="ok" if ok else "err",
        )
        self._json({"ok": ok})

    def do_DELETE(self) -> None:
        """DELETE 路由分发"""
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)

        # 日志前缀：绑定本次请求的源库（无 dir 参数时清空，避免跨请求串味）
        _bind_src((qs.get("dir") or [""])[0].strip())

        if path == "/api/crop/manual":
            self._handle_delete_manual_crop(qs)
            return

        self.send_error(404, f"Not Found DELETE: {path}")

    def _handle_delete_manual_crop(self, qs: dict[str, list[str]]) -> None:
        """DELETE /api/crop/manual?hash=... — 删除用户手动裁切框"""
        hash_val = (qs.get("hash") or [""])[0].strip().lower()
        if not hash_val:
            self._error("缺少 hash 参数", status=400)
            return

        dir_param = (qs.get("dir") or [""])[0].strip()
        root = (
            Path(dir_param).resolve()
            if dir_param
            else StudioRequestHandler.current_root_dir
        )
        if not root or not root.is_dir():
            self._error("缺少有效目录 dir 参数", status=400)
            return

        with CacheDB(root) as db:
            ok = db.delete_user_override(hash_val)
        logger.info(f"[MANUAL_CROP] DELETE: hash={hash_val[:16]}... ok={ok}")
        _audit(
            root,
            "crop_manual_delete",
            scope="crop",
            entity=hash_val,
            after={"ok": ok},
            result="ok" if ok else "err",
        )
        self._json({"ok": ok})

    def _handle_delete_image(self, data: dict[str, Any]) -> None:
        """
        POST /api/delete — 删除单张素材（软删除，可手工找回）。

        语义：
        1. 把源文件移动到 <SourceDir>/.deleted/ 下的同名相对路径（保留原子目录结构）；
        2. 从 SQLite 缓存数据库移除该路径条目，并清理随之失去引用的用户覆盖记录；
        3. 已导出（账本命中 hash 或路径）的图片一律拒绝删除。

        .deleted/ 以点开头，属隐藏目录，scanner 扫描时天然忽略，
        因此后续扫描不会把回收目录重新纳入（历史 "Deleted/" 亦被视为回收目录）。
        """
        dir_param = (data.get("dir") or "").strip()
        path_s = (data.get("path") or "").strip()

        if not dir_param:
            self._error("缺少必要参数 dir")
            return
        if not path_s:
            self._error("缺少必要参数 path")
            return

        root = Path(dir_param).resolve()
        if not root.exists() or not root.is_dir():
            self._error(f"目录不存在: {dir_param}", status=404)
            return

        rel_raw = urllib.parse.unquote(path_s).replace("\\", "/").strip().strip("/")
        raw_path = Path(rel_raw)
        src = raw_path.resolve() if raw_path.is_absolute() else (root / rel_raw)

        try:
            src_res = src.resolve()
        except Exception as e:
            self._error(f"路径无法解析: {rel_raw} ({e})", status=400)
            return

        # 安全边界：绝不允许越出源目录操作任何文件
        if src_res != root and root not in src_res.parents:
            self._error("拒绝删除源目录之外的文件", status=400)
            return
        if not src_res.is_file():
            self._error(f"文件不存在: {rel_raw}", status=404)
            return

        rel = src_res.relative_to(root).as_posix()

        dest_root = (root / DELETED_DIR_NAME).resolve()
        recycle_roots = [dest_root] + [(root / n).resolve() for n in LEGACY_DELETED_DIR_NAMES]
        if any(src_res == r or r in src_res.parents for r in recycle_roots):
            self._error(f"该文件已位于回收目录 {DELETED_DIR_NAME}/ 中", status=400)
            return

        # 已导出保护：账本按 hash 或相对路径命中即视为已导出，禁止删除
        exp_ledger = load_exported_ledger(root) or {}
        exp_hashes = exp_ledger.get("hashes", {}) or {}
        exp_map = get_exported_map(root) or {}

        file_hash = (data.get("hash") or "").strip().lower()
        if not file_hash:
            try:
                file_hash = compute_file_sha256(src_res).strip().lower()
            except Exception as e:
                logger.warning(f"[DELETE] 计算 hash 失败: {src_res} ({e})")
                file_hash = ""

        exp_info = (exp_hashes.get(file_hash) if file_hash else None) or exp_map.get(rel)
        if exp_info:
            logger.warning(f"[DELETE] 拒绝删除已导出素材: {rel} (hash={file_hash[:16]}...)")
            self._error("已导出的图片不能删除", status=409)
            return

        # 目标路径冲突时追加时间戳序号，绝不覆盖回收目录中已有的同名文件
        dest = dest_root / rel
        if dest.exists():
            stem = Path(rel).stem
            suffix = Path(rel).suffix
            stamp = dt.datetime.now().strftime("%Y%m%d%H%M%S")
            seq = 1
            while True:
                cand = dest.parent / f"{stem}_{stamp}_{seq}{suffix}"
                if not cand.exists():
                    dest = cand
                    break
                seq += 1

        try:
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(src_res), str(dest))
        except Exception as e:
            logger.error(f"[DELETE] 移动文件失败: {src_res} -> {dest} ({e})")
            self._error(f"删除失败，移动文件出错: {e}", status=500)
            return

        removed_hashes: list[str] = []
        cleaned = {"overrides": 0, "qualities": 0}
        try:
            with CacheDB(root) as db:
                removed_hashes = db.delete_files([rel])
                cleaned = db.cleanup_orphan_hash_data(removed_hashes)
        except Exception as e:
            # 文件已挪走，数据库清理失败不回滚，仅记录告警。
            # 注意兜底范围有限：file_cache 残留条目会被下次扫描 prune_missing_files
            # 清理，但 user_overrides / quality_cache 的孤儿记录不会，需另行手工清理。
            logger.warning(f"[DELETE] 数据库清理失败: {rel} ({e})")

        dest_rel = dest.relative_to(root).as_posix()
        logger.info(
            f"[DELETE] 已删除素材: {rel} -> {dest_rel} (hash={file_hash[:16]}...)"
        )
        _audit(
            root,
            "delete_image",
            scope="source",
            entity=rel,
            after={
                "deletedTo": dest_rel,
                "hash": file_hash,
                "removedHashes": len(removed_hashes),
                "cleaned": cleaned,
            },
            result="ok",
        )
        self._json(
            {
                "ok": True,
                "path": rel,
                "hash": file_hash,
                "deletedTo": dest_rel,
                "removedHashes": len(removed_hashes),
                "cleaned": cleaned,
            }
        )

    def _handle_post_quality_batch(self, data: dict[str, Any]) -> None:
        """批量质检：注册 job -> 后台 worker -> 立即返回 taskId"""
        dir_param = (data.get("dir") or "").strip()
        root = (
            Path(dir_param).resolve()
            if dir_param
            else StudioRequestHandler.current_root_dir
        )
        if not root or not root.is_dir():
            self._error("缺少有效目录 dir 参数", status=400)
            return

        client_task_id = (data.get("clientTaskId") or "").strip()
        if not client_task_id:
            self._error("缺少 clientTaskId 参数", status=400)
            return

        paths = data.get("paths") or []
        # limit<=0 表示全量，否则最多取 limit 条（上限 2000）
        limit_raw = int(data.get("limit") or 0)
        limit = 0 if limit_raw <= 0 else max(1, min(limit_raw, 2000))
        force = bool(data.get("force"))
        max_workers_raw = int(data.get("maxWorkers") or 0)
        max_workers = max_workers_raw if 1 <= max_workers_raw <= 24 else None

        with CacheDB(root) as db:
            targets: list[tuple[Path, str, str]] = []  # (full_path, rel_path, hash)
            if paths:
                for p_s in paths:
                    p = self._resolve_image_path(p_s, {"dir": [str(root)]})
                    if p and p.is_file():
                        rel = p.relative_to(root).as_posix().replace("\\", "/")
                        targets.append((p, rel, ""))
            elif force:
                all_items = db.get_all_items(limit=limit)
                for rel, h in all_items:
                    p = root / rel
                    if p.is_file():
                        targets.append((p, rel, h))
            else:
                unscored = db.get_unscored_items(limit=limit)
                for rel, h in unscored:
                    p = root / rel
                    if p.is_file():
                        targets.append((p, rel, h))

        total = len(targets)

        # 并发拦截：只拦截同类型（质检）任务，导出任务互不阻塞。
        # 注册本身是原子的（锁内完成「检查 + 写入」），此处仅用于取出冲突任务 id 以生成文案。
        if not _job_register(client_task_id, kind="quality"):
            running = _job_find_running(kind="quality")
            self._error(
                f"{_job_kind_label('quality')}任务正在进行中: {running[0] if running else '(未知)'}，"
                f"请等待完成或先取消",
                status=409,
            )
            return

        _job_progress(client_task_id, 0, total)

        def _quality_worker() -> None:
            """后台线程入口：任何逃逸异常都必须收口为任务失败，
            否则任务会永远停在 running，导致同类任务被互斥锁永久挡住。"""
            # contextvar 不跨线程传播，这里显式重新绑定，保证质检日志带 [src=库名]
            _bind_src(root)
            try:
                _run_quality_job(root, targets, client_task_id, max_workers)
            except Exception as e:  # pragma: no cover - 兜底路径
                logger.error("[QUALITY] %s 任务异常终止: %s", client_task_id, e)
                _job_finish(client_task_id, error=f"质检任务异常终止: {e}")

        _Pool(max_workers=1).submit(_quality_worker)

        logger.info(
            "[QUALITY] 质检任务已启动: task=%s, total=%d, force=%s, workers=%s",
            client_task_id,
            total,
            force,
            max_workers or "auto",
        )
        # 质检范围：指定清单 / 全量重算 / 仅未评分
        qc_scope_kind = "selected" if paths else ("all" if force else "unscored")
        _audit(
            root,
            "quality_batch_start",
            scope="quality",
            entity=client_task_id,
            after={
                "total": total,
                "scopeKind": qc_scope_kind,
                "limit": limit,
                "force": force,
                "workers": max_workers or "auto",
            },
            result="ok",
        )
        self._json(
            {
                "ok": True,
                "taskId": client_task_id,
                "total": total,
                "started": True,
            }
        )

    def _handle_quality_cancel(self, data: dict[str, Any]) -> None:
        """取消进行中的质检任务"""
        task_id = (data.get("task") or "").strip()
        if not task_id:
            self._error("缺少 task 参数", status=400)
            return
        ok = _job_cancel(task_id)
        # 审计：job 表只存 taskId，源库目录需从请求或当前工作目录推断
        dir_param = (data.get("dir") or "").strip()
        _audit(
            Path(dir_param).resolve() if dir_param else StudioRequestHandler.current_root_dir,
            "quality_cancel",
            scope="quality",
            entity=task_id,
            after={"ok": ok},
            result="ok" if ok else "err",
        )
        self._json({"ok": ok, "taskId": task_id})

    def _handle_thumb(self, qs: dict[str, list[str]]) -> None:
        """缩略图输出 (带 HTTP 强缓存与 304 协商缓存)"""
        path_s = (qs.get("path") or [""])[0]
        size_s = (qs.get("size") or ["360"])[0]

        if not path_s:
            self.send_error(400, "Missing ?path")
            return

        p = self._resolve_image_path(path_s, qs)
        if not p:
            self.send_error(404, f"File not found: {path_s}")
            return

        try:
            size = int(size_s)
        except Exception:
            size = 360

        # ETag 协商缓存检查
        try:
            st = p.stat()
            etag = f'"{hashlib.md5(f"{p.resolve()}_{st.st_mtime_ns}_{st.st_size}_{size}".encode()).hexdigest()}"'
        except Exception:
            etag = None

        if etag and self.headers.get("If-None-Match") == etag:
            self.send_response(304)
            self._cors()
            self.end_headers()
            return

        data, ctype = generate_thumbnail_bytes(p, size=size)
        if data is None:
            self.send_error(500, "Thumbnail generation failed")
            return

        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "public, max-age=86400, immutable")
        if etag:
            self.send_header("ETag", etag)
        self._cors()
        self.end_headers()
        self.wfile.write(data)

    def _handle_file(self, qs: dict[str, list[str]]) -> None:
        """原图输出"""
        path_s = (qs.get("path") or [""])[0]
        if not path_s:
            self.send_error(400, "Missing ?path")
            return

        p = self._resolve_image_path(path_s, qs)
        if not p:
            self.send_error(404, f"File not found: {path_s}")
            return

        ctype, _ = mimetypes.guess_type(str(p))
        self._serve_static_file(p, ctype or "application/octet-stream")

    def _handle_export(self, data: dict[str, Any]) -> None:
        """统一资产导出处理"""
        exp_type = data.get("type", "main").strip().lower()
        src = (data.get("srcDir") or "").strip()
        out = (data.get("outDir") or "").strip()
        http_base = (data.get("httpBase") or "").strip()

        logs: list[dict[str, str]] = []
        # 进度感知观测通道：仅当请求携带 clientTaskId 时注册；否则整条路径与旧版一致
        task_id = str(data.get("clientTaskId") or "").strip()
        if not task_id:
            # 未携带 clientTaskId 时补一个匿名导出任务 id，确保同样纳入并发互斥与
            # 状态观测——否则不传该参数即可绕过导出互斥锁。
            task_id = f"export_anon_{int(time.time() * 1000)}"

        # 导出器 self.log(...) 的级别映射到 Python logging 级别
        _EXPORT_LOG_LEVELS = {
            "debug": logging.DEBUG,
            "info": logging.INFO,
            "ok": logging.INFO,
            "warn": logging.WARNING,
            "warning": logging.WARNING,
            "err": logging.ERROR,
            "error": logging.ERROR,
        }

        def log_fn(msg: str, level: str = "info") -> None:
            entry = {
                "t": dt.datetime.now().strftime("%H:%M:%S"),
                "level": level,
                "msg": msg,
            }
            logs.append(entry)
            _job_append_log(task_id, entry)
            # 同步转发到 Python logger，使完整导出过程（逐张转码、index 写入、
            # 账本更新等）落盘到 temp/studio-YYYYMMDD.log（按日期命名），任务结束后仍可回溯。
            logger.log(
                _EXPORT_LOG_LEVELS.get(level, logging.INFO),
                "[EXPORT] %s",
                msg,
            )

        def progress_fn(done: int, total: int) -> None:
            _job_progress(task_id, done, total)

        if not src or not out:
            self._json(
                {
                    "ok": False,
                    "error": "必须提供源目录 (srcDir) 与输出目录 (outDir)",
                    "logs": logs,
                },
                400,
            )
            return

        src_p = Path(src)
        out_p = Path(out)

        # 并发互斥：同一时刻只允许一个导出任务。
        # 两个导出同时写同一 release/index.json 与账本会互相覆盖（order 撞号、
        # manifest 与产物不符），且不会报错，因此必须入口拦截。
        # 注册为原子操作（锁内完成「检查 + 写入」），并发请求只有一个能成功。
        if not _job_register(task_id, kind="export"):
            running = _job_find_running(kind="export")
            self._json(
                {
                    "ok": False,
                    "error": (
                        f"{_job_kind_label('export')}任务正在进行中: {running[0] if running else '(未知)'}，"
                        f"请等待其结束后再发起新的导出"
                    ),
                    "logs": logs,
                },
                409,
            )
            return

        cat_id = data.get("catalog", "")
        log_fn(f"开始导出任务: [{exp_type.upper()}] (分类: {cat_id})")
        log_fn(f"源路径: {src}")
        log_fn(f"目标路径: {out}")
        logger.info(
            f"[EXPORT] 收到导出请求: 类型={exp_type}, 分类={cat_id}, 源路径={src}, 输出路径={out}"
        )

        # .studio git 守卫：正式导出前自动 checkpoint（strict 模式失败则拦截）。
        # 试导出不写账本/release，无状态变化，完全跳过 git 操作。
        is_trial_export = bool(data.get("trial", False))
        if not is_trial_export:
            gg_mode = load_mode(src_p / ".studio")
            if gg_mode != "off":
                if ensure_repo(src_p / ".studio"):
                    block_reason = guard_export(
                        src_p / ".studio", exp_type, strict=(gg_mode == "strict")
                    )
                    if block_reason:
                        log_fn(block_reason, "err")
                        logger.warning(f"[EXPORT] git 守卫拦截导出: {block_reason}")
                        _job_finish(task_id, error=block_reason)
                        self._json(
                            {"ok": False, "error": block_reason, "logs": logs},
                            status=400,
                        )
                        return
                else:
                    log_fn(".studio git 仓库初始化失败，本次导出无版本快照（不影响导出）", "warn")

        # 查询用户手动裁切框，注入 data 供 exporter 在构建转码任务时按 hash 查找
        try:
            with CacheDB(src_p) as _db:
                _overrides = _db.get_all_user_overrides()
            manual_boxes = {}
            for h, o in _overrides.items():
                if o.get("has_crop"):
                    manual_boxes[h] = (
                        o["crop_x0"],
                        o["crop_y0"],
                        o["crop_x1"],
                        o["crop_y1"],
                    )
            if manual_boxes:
                data["manual_boxes"] = manual_boxes
                log_fn(
                    f"检测到 {len(manual_boxes)} 张图片有手动裁切框，导出时将优先使用",
                    "info",
                )
        except Exception as e:
            logger.warning(f"[EXPORT] 查询手动裁切框失败（不影响导出）: {e}")

        try:
            exporter = get_exporter(
                exp_type, data, src_p, out_p, http_base, log_fn, progress_fn=progress_fn
            )
            exporter.validate()
            result = exporter.execute()
            result.logs = logs
            res_dict = result.to_dict()
            if result.success:
                if getattr(exporter, "is_trial", False):
                    res_dict["trial"] = True
                    res_dict["trialDir"] = str(getattr(exporter, "_build_root", ""))
                    res_dict["wouldCommit"] = getattr(exporter, "_would_commit", {})
                    log_fn(f"试导出完成，产物位于: {res_dict.get('trialDir')}", "info")
                else:
                    ledger = load_exported_ledger(src_p)
                    res_dict["totalExported"] = ledger.get("total_exported", 0)
                logger.info(f"[EXPORT] 导出成功: 输出文件={result.files}")
                if not getattr(exporter, "is_trial", False):
                    # 导出后提交账本/流水/标签变化（尽力而为，失败不影响响应）。
                    # 张数必须取 result.count（= 本次导出图片数）；result.files 是
                    # release 镜像的全量交付文件清单（含 index.json/manifest.json/
                    # zip/封面，且 main 镜像跨批次累积），其长度与图片数无关。
                    commit_after_export(
                        src_p / ".studio",
                        exp_type,
                        result.count or len(result.files or []),
                    )
                _job_finish(task_id, summary=result.summary)
            else:
                logger.error(f"[EXPORT] 导出失败: {result.error}")
                _job_finish(task_id, error=result.error)
            self._json(res_dict)
        except ValueError as e:
            # 业务校验类失败（数量超限 / 素材不足 / 图片损坏等）按 400 返回，
            # 与 500 的运行时异常区分，便于前端把原因直接呈现给用户。
            log_fn(f"导出中止: {e}", "err")
            logger.warning(f"[EXPORT] 导出校验未通过: {e}")
            if not is_trial_export:
                # 记录失败现场（checkpoint 之后、账本变更前的差异，尽力而为）
                commit_after_export(src_p / ".studio", exp_type, 0, failed=True)
            _job_finish(task_id, error=str(e))
            self._json(
                {
                    "ok": False,
                    "error": str(e),
                    "logs": logs,
                },
                status=400,
            )
        except Exception as e:
            import traceback

            err_detail = traceback.format_exc().splitlines()[-1]
            log_fn(f"导出失败: {e} ({err_detail})", "err")
            logger.error(f"[EXPORT] 导出异常: {e}\n{traceback.format_exc()}")
            if not is_trial_export:
                commit_after_export(src_p / ".studio", exp_type, 0, failed=True)
            _job_finish(task_id, error=str(e))
            self._json(
                {
                    "ok": False,
                    "error": str(e),
                    "logs": logs,
                },
                status=500,
            )
        finally:
            # 兜底收口：异常路径之外的任何漏网（如 exporter 内部提前 return）
            # 都必须让任务离开 running，否则导出互斥锁会永久生效。
            _job_ensure_finished(task_id)

    def _handle_export_limits(self) -> None:
        """下发导出侧硬限制（单次导出图片数上限）。

        前端据此提示与禁用按钮，避免阈值在前后端各写一份而产生漂移。
        """
        self._json(
            {
                "ok": True,
                "limits": {
                    "maxImagesPerJob": MAX_EXPORT_IMAGES_PER_JOB,
                    "byType": dict(EXPORT_IMAGE_LIMITS),
                },
            }
        )

    def _handle_export_preview(self, data: dict[str, Any]) -> None:
        """导出前只读预检：按排序方式返回图片清单 + 统计 + 建议起始序号/版本 (不写盘)"""
        src = (data.get("srcDir") or "").strip()
        out = (data.get("outDir") or "").strip()
        exp_type = (data.get("type") or "main").strip().lower()
        if not src:
            self._error("缺少 srcDir")
            return

        # 统一用 resolve() 后的根目录：/api/scan 与 build_manual_order 都是 resolved 口径，
        # 否则 manual 排序的键匹配不上会静默退化成扫描字典序
        root = Path(src).resolve()
        if not root.is_dir():
            self._error(f"源目录不存在: {src}", status=404)
            return
        out_p = Path(out) if out else None

        selected_paths = data.get("selectedPaths")
        sort_by = (data.get("sortBy") or "name_asc").strip().lower()
        exclude_exported = bool(data.get("excludeExported"))
        # 第②步 ✕ 剔除的图片：预览与导出必须同口径
        excluded_raw = data.get("excludedPaths")
        excluded = (
            {
                str(p).replace("\\", "/").strip().lower()
                for p in excluded_raw
                if str(p).strip()
            }
            if isinstance(excluded_raw, list)
            else set()
        )
        fmt = (data.get("format") or "webp").strip().lower()
        try:
            quality = int(data.get("quality", 70))
        except (TypeError, ValueError):
            quality = 70
        quality = max(1, min(100, quality))

        # 1. 校选图范围 + 排序
        images = scan_images(root)
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
                for p in images
                if p.relative_to(root).as_posix().lower() in selected_set
            ]
        if excluded:
            images = [
                p
                for p in images
                if p.relative_to(root).as_posix().lower() not in excluded
            ]
        manual_order = build_manual_order(
            root, data.get("manualOrder") or selected_paths
        )
        images = sort_images(images, sort_by, manual_order=manual_order)

        # 2. 标签与哈希来源：前端传入 records 优先，否则退回源目录 tags 文件
        raw_records = data.get("tagsRecords")
        records: list[dict[str, Any]] = []
        if raw_records:
            records, _ = normalize_records(raw_records, root)
        else:
            tag_file = find_tags_file(root)
            if tag_file:
                raw, _ = load_tags_file(tag_file)
                records, _ = normalize_records(raw, root)
        rec_by_rel: dict[str, dict[str, Any]] = {}
        rec_by_name: dict[str, dict[str, Any]] = {}
        for r in records:
            k = (r.get("path") or r.get("file") or "").replace("\\", "/")
            rec_by_rel[k] = r
            rec_by_name[Path(k).name] = r

        # 3. 已导出状态与主线条目 maxOrder
        ledger = ExportsLedger(root)
        exp_map = ledger.get_exported_map()
        exp_hashes = ledger.get_exported_hashes()
        max_order = ledger.get_max_order(exp_type) if exp_type in ("main",) else 0

        # 4. 构建有序清单与统计
        ordered: list[dict[str, Any]] = []
        tag_counter: dict[str, int] = {}
        dir_counter: dict[str, int] = {}
        source_bytes = 0
        already = 0

        for p in images:
            rel = p.relative_to(root).as_posix().replace("\\", "/")
            rec = rec_by_rel.get(rel) or rec_by_name.get(p.name) or {}
            tags = rec.get("tags") or []
            # 无标签一律落成规范兜底标签 [Others]，与导出器/前端保持同一口径
            norm = [normalize_token(t) for t in tags if normalize_token(t)] or [
                OTHERS_TAG
            ]
            h = (rec.get("hash") or "").strip().lower()
            if not h:
                try:
                    h = compute_file_sha256(p)
                except Exception:
                    h = ""
            try:
                size = int(rec.get("size") or 0) or p.stat().st_size
            except Exception:
                size = 0
            is_exp = bool(h and h in exp_hashes)

            if exclude_exported and is_exp:
                continue

            source_bytes += size
            if is_exp:
                already += 1
            dir1 = rel.rsplit("/", 1)[0] if "/" in rel else "(根目录)"
            for tg in norm:
                tag_counter[tg] = tag_counter.get(tg, 0) + 1
            dir_counter[dir1] = dir_counter.get(dir1, 0) + 1
            prev = exp_map.get(h) or exp_map.get(rel)
            ordered.append(
                {
                    "rel": rel,
                    "file": p.name,
                    "tags": norm,
                    "dir": dir1,
                    "size": size,
                    "isExported": is_exp,
                    "prevTarget": (
                        prev.get("target") if isinstance(prev, dict) else None
                    ),
                }
            )

        # 5. 建议值 (根据 outDir/main/index.json 与源侧账本)
        suggested: dict[str, Any] = {
            "maxOrder": max_order,
            "suggestedStartOrder": (max_order + 1) if max_order > 0 else 1,
            "suggestedVersion": 0,
        }
        if exp_type == "main" and out_p:
            idx_path = out_p / "main" / "index.json"
            if idx_path.exists():
                try:
                    idx = json.loads(idx_path.read_text(encoding="utf-8"))
                    if isinstance(idx, dict):
                        idx_max = int(idx.get("maxOrder") or 0)
                        idx_ver = int(idx.get("version") or 0)
                        if idx_max > suggested["maxOrder"]:
                            suggested["maxOrder"] = idx_max
                            suggested["suggestedStartOrder"] = idx_max + 1
                        suggested["suggestedVersion"] = idx_ver
                except Exception:
                    pass

        est_ratio = _estimate_ratio(fmt, quality)
        stats = {
            "total": len(ordered),
            "sourceBytes": source_bytes,
            # 预计（按输出格式与 quality 折算；png/original 不转码按原图计）
            "estWebpBytes": int(source_bytes * est_ratio),
            "estRatio": round(est_ratio, 4),
            "tags": tag_counter,
            "dirs": dir_counter,
            "alreadyExported": already,
        }
        if exp_type == "main" and suggested.get("maxOrder", 0) > 0:
            stats["suggestedStartOrder"] = suggested["suggestedStartOrder"]

        # 单次导出数量上限：与导出器校验同源（导出器会在剔除已导出后按最终真实数量复核）
        limit = resolve_export_limit(_EXPORT_MODULE_OF_TYPE.get(exp_type, exp_type))
        stats["maxImagesPerJob"] = limit
        stats["overLimit"] = len(ordered) > limit

        self._json(
            {
                "ok": True,
                "type": exp_type,
                "ordered": ordered,
                "stats": stats,
                "suggested": suggested,
                "limits": {
                    "maxImagesPerJob": MAX_EXPORT_IMAGES_PER_JOB,
                    "byType": dict(EXPORT_IMAGE_LIMITS),
                },
            }
        )

    def _serve_static_file(self, p: Path, ctype: str) -> None:
        if not p.exists() or not p.is_file():
            self.send_error(404, f"File not found: {p.name}")
            return
        data = p.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self._cors()
        self.end_headers()
        self.wfile.write(data)


class StudioServer(ThreadingHTTPServer):
    """
    Content Studio 专属 HTTP 多线程服务器实现。
    修复标准库 ThreadingHTTPServer (TCPServer) 在 Windows 下默认开启 SO_REUSEADDR
    导致两个甚至多个进程可以静默同时监听/绑定同一端口（端口劫持与请求混乱冲突）的缺陷。
    在 Windows 下强制关闭 allow_reuse_address 并启用 SO_EXCLUSIVEADDRUSE 独占监听。
    """

    daemon_threads = True

    def __init__(
        self, server_address: tuple[str, int], RequestHandlerClass: type
    ) -> None:
        if sys.platform == "win32":
            self.allow_reuse_address = False
        super().__init__(server_address, RequestHandlerClass)

    def server_bind(self) -> None:
        if sys.platform == "win32" and hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            try:
                self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            except Exception:
                pass
        super().server_bind()


def _require_export_environment() -> None:
    """启动时强校验运行环境：当前解释器必须具备 Pillow + OpenCV + numpy。

    禁止静默降级：cv2 缺失时旧逻辑会依次回退到 venv 子进程 / Pillow 评估，
    三种口径的评分完全不同，用户会看到分数漂移却不知原因。此处 fail-fast：
    环境不满足直接退出，绝不带病启动。
    """
    missing: list[str] = []
    try:
        import cv2  # noqa: F401
    except ImportError:
        missing.append("opencv-python")
    try:
        import numpy  # noqa: F401
    except ImportError:
        missing.append("numpy")
    try:
        import PIL  # noqa: F401
    except ImportError:
        missing.append("Pillow")

    if missing:
        err_msg = (
            f"\n=======================================================\n"
            f"  [错误] Python 环境不满足启动要求，服务已退出！\n"
            f"\n"
            f"  当前解释器: {sys.executable}\n"
            f"  缺失依赖: {', '.join(missing)}\n"
            f"\n"
            f"  Content Studio 禁止质检评估器静默降级（cv2/venv/Pillow 三种口径\n"
            f"  评分不一致，会造成分数漂移且不可察觉），因此强制要求当前 Python\n"
            f"  同时具备 OpenCV + numpy + Pillow。\n"
            f"\n"
            f"  修复方法 (任选其一):\n"
            f"    1. 安装缺失依赖后重新启动:\n"
            f"       {sys.executable} -m pip install {' '.join(missing)}\n"
            f"    2. 使用已配置完整依赖的解释器启动:\n"
            f"       C:\\Home\\Develop\\venv\\Scripts\\python.exe studio/server.py\n"
            f"=======================================================\n"
        )
        sys.stderr.write(err_msg)
        raise SystemExit(1)


def run_server(
    host: str = "127.0.0.1",
    port: int = 5188,
    auto_open: bool = False,
    loglevel: str = "INFO",
    logfile: Path | str | None = DEFAULT_LOG_FILE,
) -> None:
    """启动本地 HTTP 服务器 (多线程并发处理缩略图与 API)"""
    _require_export_environment()
    setup_logger(level_name=loglevel, logfile=logfile)
    server_addr = (host, port)

    try:
        httpd = StudioServer(server_addr, StudioRequestHandler)
    except OSError as e:
        winerr = getattr(e, "winerror", None)
        if winerr == 10048 or getattr(e, "errno", None) in (98, 48, 10048):
            err_msg = (
                f"\n=======================================================\n"
                f"  [错误] 端口 {port} 已被占用，服务无法启动！\n"
                f"  原因：已有 Content Studio 实例在运行，或端口被其他程序占用。\n"
                f"  建议：请关闭正在运行的实例，或通过 --port 指定其他端口：\n"
                f"        python studio/server.py --port {port + 1}\n"
                f"=======================================================\n"
            )
            logger.error(f"端口 {port} 已被占用，服务启动失败: {e}")
            sys.stderr.write(err_msg)
            sys.exit(1)
        raise

    url = f"http://{host}:{port}"
    print(f"\n=======================================================")
    print(f"  Content Studio — 拼图打包控制台已启动")
    print(f"  访问地址: {url}")
    print(f"  Pillow 加速: {'已启用' if HAS_PIL else '未安装 (直出原图)'}")
    print(f"  日志级别: {loglevel.upper()}")
    if logfile and str(logfile).strip().lower() not in ("none", "off", "false", ""):
        print(f"  日志文件: {Path(logfile).resolve()}")
    print(f"=======================================================\n")

    logger.info(f"Content Studio 服务启动: {url} (日志级别: {loglevel.upper()})")

    if auto_open:
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n服务已停止。")
        logger.info("Content Studio 服务已正常停止。")
        httpd.server_close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Content Studio — 拼图内容打包工作室")
    parser.add_argument(
        "--host", default="127.0.0.1", help="监听地址 (默认: 127.0.0.1)"
    )
    parser.add_argument("--port", type=int, default=5188, help="监听端口 (默认: 5188)")
    parser.add_argument("--open", action="store_true", help="启动后自动在浏览器打开")
    parser.add_argument(
        "--loglevel",
        default="INFO",
        choices=[
            "DEBUG",
            "INFO",
            "WARNING",
            "ERROR",
            "debug",
            "info",
            "warning",
            "error",
        ],
        help="控制台日志级别 (默认: INFO)",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="启用详细调试日志模式 (等同于 --loglevel DEBUG)",
    )
    parser.add_argument(
        "--logfile",
        default=str(DEFAULT_LOG_FILE),
        help=f"日志保存文件路径 (默认: {DEFAULT_LOG_FILE})",
    )
    args = parser.parse_args()

    level = "DEBUG" if args.debug else args.loglevel.upper()
    run_server(
        host=args.host,
        port=args.port,
        auto_open=args.open,
        loglevel=level,
        logfile=args.logfile,
    )


if __name__ == "__main__":
    main()
