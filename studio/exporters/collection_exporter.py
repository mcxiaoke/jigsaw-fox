#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.exporters.collection_exporter — 主题图集关卡导出器 (collections/index.json + zip + 封面)
基于 PackExporterBase 共享打包引擎构建。
"""

from __future__ import annotations

from typing import Any

from studio.exporters.pack_exporter_base import PackExporterBase


class CollectionExporter(PackExporterBase):
    module = "collections"
    id_field = "collectionId"

    def build_item_extra(self) -> dict[str, Any]:
        extra: dict[str, Any] = {}
        if self.data.get("category"):
            extra["category"] = self.data["category"]
        if self.data.get("unlockCoins"):
            try:
                extra["unlockCoins"] = int(self.data["unlockCoins"])
            except Exception:
                pass
        return extra
