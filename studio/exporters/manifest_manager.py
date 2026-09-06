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
        count: int | None = None,
        module_hash: str | None = None,
        extra_fields: dict[str, Any] | None = None,
        ws: Any = None,
        release_dir: Path | None = None,
    ) -> Path | None:
        manifest_file = out_p / "manifest.json"
        now_str = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
        manifest_data: dict[str, Any] = {
            "schemaVersion": 4,
            "updatedAt": now_str,
            "appConfig": {
                "notice": "",
                "minAppVersion": 1,
            },
            "modules": {},
        }

        if manifest_file.exists():
            try:
                content = json.loads(manifest_file.read_text(encoding="utf-8"))
                if isinstance(content, dict):
                    manifest_data = content
                    if "schemaVersion" not in manifest_data and "version" in manifest_data:
                        manifest_data["schemaVersion"] = 4
                    if "appConfig" not in manifest_data:
                        manifest_data["appConfig"] = {"notice": "", "minAppVersion": 1}
                    if "modules" not in manifest_data:
                        manifest_data["modules"] = {}
            except Exception as e:
                log_fn(f"读取现有 manifest.json 失败，将重新初始化: {e}", "warn")

        # 更新指定模块路由
        mod_entry: dict[str, Any] = {
            "url": url,
            "version": version,
            "updatedAt": now_str,
        }
        if count is not None:
            if module_name == "main":
                mod_entry["totalCount"] = count
            else:
                mod_entry["count"] = count
        if module_hash:
            mod_entry["hash"] = module_hash
        if extra_fields:
            mod_entry.update(extra_fields)
            if module_name == "main" and "count" in mod_entry:
                del mod_entry["count"]

        manifest_data["modules"][module_name] = mod_entry
        manifest_data["updatedAt"] = now_str

        try:
            tmp_file = manifest_file.with_suffix(".tmp")
            tmp_file.write_text(json.dumps(manifest_data, ensure_ascii=False, indent=2), encoding="utf-8")
            tmp_file.replace(manifest_file)
            log_fn(f"manifest.json 已更新: [{module_name}] version={version}", "ok")

            # 同步镜像至 workspace release_dir (如果存在)
            target_release_dir = release_dir or (getattr(ws, "release_dir", None) if ws else None)
            if target_release_dir:
                try:
                    rel_dir = Path(target_release_dir)
                    rel_dir.mkdir(parents=True, exist_ok=True)
                    rel_manifest = rel_dir / "manifest.json"
                    rel_tmp = rel_manifest.with_suffix(".tmp")
                    rel_tmp.write_text(json.dumps(manifest_data, ensure_ascii=False, indent=2), encoding="utf-8")
                    rel_tmp.replace(rel_manifest)
                    log_fn(f"manifest.json 镜像已同步至 release_dir", "info")
                except Exception as ex:
                    log_fn(f"镜像 manifest.json 到 release_dir 失败: {ex}", "warn")

            return manifest_file
        except Exception as e:
            log_fn(f"写入 manifest.json 失败: {e}", "warn")
            return None
