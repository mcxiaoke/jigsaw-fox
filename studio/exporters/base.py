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
