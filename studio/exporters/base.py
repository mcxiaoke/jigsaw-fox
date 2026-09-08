#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.exporters.base — 资产导出器抽象基类与通用数据结构
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable


def resolve_quality(data: dict[str, Any], default: int = 70) -> int:
    """从导出参数中解析并夹取 WebP/JPEG 压缩质量 (1~100)。非法或缺失回退默认。"""
    try:
        q = int(data.get("quality", default))
    except Exception:
        return default
    if q < 1:
        return 1
    if q > 100:
        return 100
    return q


def resolve_excluded(data: dict[str, Any]) -> set[str]:
    """解析前端在第②步用 ✕ 剔除的相对路径集合（小写 posix 口径）。

    这些图片已从导出批次中剔除，导出器必须把它们从待导出清单中真正移除，
    否则会出现「预览里看不到、导出却多出来」的不一致。
    """
    raw = data.get("excludedPaths")
    if not isinstance(raw, list):
        return set()
    out: set[str] = set()
    for p in raw:
        s = str(p).replace("\\", "/").strip().lower()
        if s:
            out.add(s)
    return out


@dataclass
class ExportResult:
    """导出操作执行结果"""
    success: bool
    summary: str = ""
    files: list[str] = field(default_factory=list)
    logs: list[dict[str, str]] = field(default_factory=list)
    error: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": self.success,
            "summary": self.summary,
            "files": self.files,
            "logs": self.logs,
            "error": self.error,
        }


class BaseExporter(ABC):
    """所有导出器的规范抽象基类"""

    def __init__(
        self,
        data: dict[str, Any],
        src_p: Path,
        out_p: Path,
        http_base: str,
        log_fn: Callable[[str, str], None],
        progress_fn: Callable[[int, int], None] | None = None,
    ):
        self.data = data
        self.src_p = src_p
        self.out_p = out_p
        self.http_base = http_base.rstrip("/")
        self.fmt = data.get("format", "original")
        self.rename_rule = data.get("rename", "none")
        self.log = log_fn
        self.progress_fn = progress_fn

    def report_progress(self, done: int, total: int, current: dict | None = None, ok: bool = True) -> None:
        """上报单张图片转码进度（并行池每完成一张调用一次）。

        current: 刚完成任务的信息 dict，含 src / dst（zip 场景额外用 label 提供归档展示名）。
        无 progress_fn 订阅者时仍会输出逐张处理日志（self.log），保证导出面板实时滚动；
        本方法内部任何异常一律吞掉，绝不影响导出主流程。
        """
        try:
            if current and current.get("src"):
                from pathlib import Path as _Path
                src_name = _Path(str(current.get("src"))).name
                disp_name = str(current.get("label") or current.get("dst") or "")
                dst_name = _Path(disp_name).name if disp_name else ""
                arrow = " ==> " if dst_name else ""
                if ok:
                    self.log(f"图片 {src_name}{arrow}{dst_name} ({done}/{total})", "info")
                else:
                    self.log(f"图片 {src_name}{arrow}{dst_name} 转码失败", "warn")
        except Exception:
            pass
        if self.progress_fn is None:
            return
        try:
            self.progress_fn(done, total)
        except Exception:
            pass

    @abstractmethod
    def validate(self) -> None:
        """校验输入参数，不合法时抛出 ValueError"""
        pass

    @abstractmethod
    def execute(self) -> ExportResult:
        """执行具体的导出处理与文件生成"""
        pass
