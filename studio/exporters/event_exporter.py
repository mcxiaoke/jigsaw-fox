#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.exporters.event_exporter — 主题活动关卡导出器 (events/index.json + zip + 封面)
基于 PackExporterBase 共享打包引擎构建。
"""

from __future__ import annotations

from typing import Any

from studio.exporters.pack_exporter_base import PackExporterBase


class EventExporter(PackExporterBase):
    module = "events"
    id_field = "eventId"

    def build_item_extra(self) -> dict[str, Any]:
        extra: dict[str, Any] = {}
        if self.data.get("startTime"):
            extra["startTime"] = self.data["startTime"]
        if self.data.get("endTime"):
            extra["endTime"] = self.data["endTime"]
        return extra
