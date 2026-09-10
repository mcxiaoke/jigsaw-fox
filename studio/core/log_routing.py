#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.core.log_routing — 运行日志按源库分流

背景：单文件运行日志把「服务自身」与「对某个源库的操作」混在一起，排查时无法一眼
分辨某行属于哪个库。这里用 contextvar 记录当前请求/任务关联的源库，由
LibraryRoutingHandler 把库相关日志写到 ``<src>/.logs/studio-YYYYMMDD.log``。

为什么放 ``<src>/.logs/`` 而不是 ``<src>/.studio/logs/``：
- ``.studio`` 是 git 仓库。日志放进去只能靠 ``*.log`` 忽略规则挡住 ``git add -A``，
  而「靠规则挡住」正是 ledger/backups 误入库的同一类隐患；``.logs/`` 位于仓库之外，
  **物理上不可能被提交**（结构性隔离，而非规则性隔离）。
- ``.studio`` 收敛的是「有状态、需追溯」的资产元数据（账本/审计/构建镜像）；
  运行日志是纯派生产物，删掉无损，不该混进资产元数据里。
- 以点开头，``scanner.scan_images`` 与 ``scripts/studio_dedupe.py`` 都无条件剪掉
  点开头目录，因此不会被当作素材；源根也不在任何 git 仓库内。

已知边界：contextvar 默认不跨线程传播。当前只有质检 worker 是独立线程，已在
``server._quality_worker`` 内显式重新绑定；其余线程池（scanner 并行哈希、
git_guard 的 git 调用、转码 ProcessPool 子进程）要么不写日志、要么在调用线程写日志，
无需额外处理。
"""

from __future__ import annotations

import datetime as dt
import logging
import sys
from contextvars import ContextVar
from pathlib import Path
from typing import Any

# 当前请求/任务关联的源库绝对路径；空串表示「无库上下文」= 服务自身日志
SRC_CTX: ContextVar[str] = ContextVar("studio_src_dir", default="")

# 源库内运行日志目录名（点开头，天然不被素材扫描器与去重脚本纳入）
LOG_DIR_NAME = ".logs"

# 源库日志文件名前缀，形如 studio-20260910.log
LOG_FILE_PREFIX = "studio-"


def src_label(value: Any) -> str:
    """把源库路径折算为日志前缀用的库名（末级目录名）；空值返回空串。"""
    if not value:
        return ""
    try:
        name = Path(str(value)).name
    except Exception:
        return ""
    return name or str(value)


def bind_src(value: Any) -> None:
    """绑定当前上下文关联的源库（绝对路径）。

    无参数/空值时显式清空，避免同一条 HTTP 连接上的后续请求沿用上一个库的上下文。
    """
    if not value or not str(value).strip():
        SRC_CTX.set("")
        return
    try:
        SRC_CTX.set(str(Path(str(value)).resolve()))
    except Exception:
        SRC_CTX.set("")


def current_src() -> str:
    """读取当前上下文绑定的源库绝对路径；无上下文返回空串。"""
    return SRC_CTX.get() or ""


class SrcContextFilter(logging.Filter):
    """把当前上下文的库名挂到 LogRecord 上，供 SrcAwareFormatter 渲染前缀。"""

    def filter(self, record: logging.LogRecord) -> bool:
        record.src = src_label(SRC_CTX.get())
        return True


class SrcAwareFormatter(logging.Formatter):
    """在级别之后动态插入 ``[src=库名]`` 前缀；无库上下文时不插入，避免噪音。"""

    def format(self, record: logging.LogRecord) -> str:
        src = getattr(record, "src", "")
        record.src_tag = f"[src={src}] " if src else ""
        return super().format(record)


class LibraryRoutingHandler(logging.Handler):
    """把带源库上下文的日志写入 ``<src>/.logs/studio-YYYYMMDD.log``。

    设计取舍：
    - **不缓存文件句柄**：每次 emit 以 append 打开、写完立即关闭。Windows 下长期持句柄
      会妨碍用户删除/移动素材库，且需要额外的 shutdown hook；日志量本就不大，够用。
    - **fail-safe**：任何异常都不得影响业务，只提示一次到 stderr（且不经过 logger，
      避免递归）。
    - **无库上下文则丢弃**：这类「服务自身」日志由服务级 FileHandler 负责，
      不能写进素材库。
    - **只写确实存在的目录**：避免把日志撒到拼写错误的路径上（不替用户凭空建目录）。
    - **不做保留清理**：日志定位是「删掉没事」，由用户手动清理，不引入自动删除逻辑。
    """

    def __init__(self, level: int = logging.NOTSET) -> None:
        super().__init__(level)
        self._warned: set[str] = set()

    def _warn_once(self, key: str, message: str) -> None:
        if key in self._warned:
            return
        self._warned.add(key)
        print(f"[log_routing] {message}", file=sys.stderr)

    def resolve_log_path(self) -> Path | None:
        """解析当前上下文的库日志路径；无上下文或目录不存在时返回 None。"""
        src = SRC_CTX.get()
        if not src:
            return None
        src_p = Path(src)
        try:
            if not src_p.is_dir():
                return None
        except Exception:
            return None
        stamp = dt.date.today().strftime("%Y%m%d")
        return src_p / LOG_DIR_NAME / f"{LOG_FILE_PREFIX}{stamp}.log"

    def emit(self, record: logging.LogRecord) -> None:
        try:
            log_path = self.resolve_log_path()
            if log_path is None:
                return
            line = self.format(record)
            log_path.parent.mkdir(parents=True, exist_ok=True)
            with open(log_path, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except Exception as e:  # noqa: BLE001 - 日志写入绝不允许影响业务
            self._warn_once(str(e), f"写入源库日志失败: {e}")
