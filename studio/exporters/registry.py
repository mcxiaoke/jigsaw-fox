#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.exporters.registry — 导出器注册中心与工厂分发
"""

from __future__ import annotations

from pathlib import Path
from typing import Callable, Type

from studio.exporters.base import BaseExporter
from studio.exporters.collection_exporter import CollectionExporter
from studio.exporters.daily_exporter import DailyExporter
from studio.exporters.event_exporter import EventExporter
from studio.exporters.main_exporter import MainExporter

EXPORTERS: dict[str, Type[BaseExporter]] = {
    "main": MainExporter,
    "daily": DailyExporter,
    "event": EventExporter,
    "collection": CollectionExporter,
}


def get_exporter(
    exp_type: str,
    data: dict,
    src_p: Path,
    out_p: Path,
    http_base: str,
    log_fn: Callable[[str, str], None],
) -> BaseExporter:
    """根据类型获取对应的导出器实例"""
    cls = EXPORTERS.get(exp_type.lower())
    if not cls:
        valid_types = ", ".join(EXPORTERS.keys())
        raise ValueError(f"未知的导出类型: '{exp_type}'，支持的类型包括: {valid_types}")
    return cls(data, src_p, out_p, http_base, log_fn)
