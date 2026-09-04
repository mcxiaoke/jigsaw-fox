#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.exporters.manifest_manager — manifest.json 纯路由清单更新管理器
符合规范: docs/dart-manifest-pure-route-migration.md
"""

from __future__ import annotations

import datetime as dt
import json
from pathlib import Path
from typing import Any, Callable


class ManifestManager:
    """负责以原子方式更新输出目录下的 manifest.json 路由清单"""

    @staticmethod
    def update_module(
        out_p: Path,
        module_name: str,
        version: int,
        url: str,
        log_fn: Callable[[str, str], None],
    ) -> Path | None:
        manifest_file = out_p / "manifest.json"
        manifest_data: dict[str, Any] = {
            "version": 1,
            "updatedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
            "modules": {},
        }

        if manifest_file.exists():
            try:
                content = json.loads(manifest_file.read_text(encoding="utf-8"))
                if isinstance(content, dict):
                    manifest_data = content
                    if "modules" not in manifest_data:
                        manifest_data["modules"] = {}
            except Exception as e:
                log_fn(f"读取现有 manifest.json 失败，将重新初始化: {e}", "warn")

        # 更新指定模块路由
        manifest_data["modules"][module_name] = {
            "url": url,
            "version": version,
        }
        manifest_data["updatedAt"] = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")

        try:
            tmp_file = manifest_file.with_suffix(".tmp")
            tmp_file.write_text(json.dumps(manifest_data, ensure_ascii=False, indent=2), encoding="utf-8")
            tmp_file.replace(manifest_file)
            log_fn(f"manifest.json 已更新: [{module_name}] version={version}", "ok")
            return manifest_file
        except Exception as e:
            log_fn(f"写入 manifest.json 失败: {e}", "warn")
            return None
