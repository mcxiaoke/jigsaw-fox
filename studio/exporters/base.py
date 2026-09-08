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
    ):
        self.data = data
        self.src_p = src_p
        self.out_p = out_p
        self.http_base = http_base.rstrip("/")
        self.fmt = data.get("format", "original")
        self.rename_rule = data.get("rename", "none")
        self.log = log_fn

    @abstractmethod
    def validate(self) -> None:
        """校验输入参数，不合法时抛出 ValueError"""
        pass

    @abstractmethod
    def execute(self) -> ExportResult:
        """执行具体的导出处理与文件生成"""
        pass
