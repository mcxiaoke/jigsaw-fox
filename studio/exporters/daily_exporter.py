#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.exporters.daily_exporter — 日历关卡导出器 (YYYYMM.zip + daily.json + 纯路由清单)
"""

from __future__ import annotations

import datetime as dt
import json
import re
import tempfile
import zipfile
from pathlib import Path
from typing import Any

from studio.core.image_proc import HAS_PIL, convert_image, make_rename
from studio.core.scanner import scan_images
from studio.exporters.base import BaseExporter, ExportResult
from studio.exporters.manifest_manager import ManifestManager


class DailyExporter(BaseExporter):
    def validate(self) -> None:
        month = (self.data.get("month") or self.data.get("YYYYMM") or "").strip()
        if not re.match(r"^\d{6}$", month):
            raise ValueError(f"月份格式必须为 6 位数字 YYYYMM，例如 202609，当前为: {month}")
        if not self.src_p.exists() or not self.src_p.is_dir():
            raise ValueError(f"源目录不存在: {self.src_p}")

    def execute(self) -> ExportResult:
        month = (self.data.get("month") or self.data.get("YYYYMM") or "").strip()
        images = scan_images(self.src_p)
        self.log(f"扫描到 {len(images)} 张图片，打包月份: {month}", "info")
        if not images:
            raise ValueError("源目录中没有找到可打包的图片文件")

        daily_dir = self.out_p / "daily"
        daily_dir.mkdir(parents=True, exist_ok=True)
        zip_path = daily_dir / f"{month}.zip"

        # 打包 ZIP
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for idx, p in enumerate(images, start=1):
                # 已经是标准日期命名的图片优先保留
                if re.match(r"^\d{8}\.", p.name) and self.rename_rule != "sequence":
                    arc_name = p.name
                    if self.fmt != "original":
                        arc_name = f"{Path(p.name).stem}.{self.fmt}"
                else:
                    arc_name = make_rename(p.name, idx, self.rename_rule, self.fmt, month)

                if self.fmt != "original" and HAS_PIL:
                    tmp_conv = Path(tempfile.gettempdir()) / f"_daily_{arc_name}"
                    ok, _ = convert_image(p, tmp_conv, self.fmt)
                    if ok:
                        zf.write(tmp_conv, arcname=arc_name)
                        tmp_conv.unlink(missing_ok=True)
                        continue

                zf.write(p, arcname=arc_name)

        self.log(f"ZIP 打包完成: {zip_path.name}", "ok")
        files = [str(zip_path.resolve())]

        # 更新 daily.json
        daily_json = self.out_p / "daily.json"
        existing_data: dict[str, Any] = {}
        if daily_json.exists():
            try:
                existing_data = json.loads(daily_json.read_text(encoding="utf-8"))
            except Exception:
                existing_data = {}

        months_list = existing_data.get("months", [])
        month_entry = {
            "month": month,
            "type": "zip",
            "url": f"{self.http_base}/daily/{month}.zip",
        }

        # 查找替换或插入顶部
        found = False
        for i, m in enumerate(months_list):
            if isinstance(m, dict) and m.get("month") == month:
                months_list[i] = month_entry
                found = True
                break
        if not found:
            months_list.insert(0, month_entry)

        new_version = int(existing_data.get("version", 0)) + 1
        daily_payload = {
            "version": new_version,
            "updatedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
            "currentMonth": month,
            "months": months_list,
        }

        tmp_daily = daily_json.with_suffix(".tmp")
        tmp_daily.write_text(json.dumps(daily_payload, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp_daily.replace(daily_json)
        self.log(f"daily.json 写入成功 (version={new_version})", "ok")
        files.append(str(daily_json.resolve()))

        # 更新 manifest.json
        m_file = ManifestManager.update_module(
            self.out_p,
            "daily",
            new_version,
            f"{self.http_base}/daily.json",
            self.log,
        )
        if m_file:
            files.append(str(m_file.resolve()))

        return ExportResult(
            success=True,
            summary=f"已成功打包 {len(images)} 张图片至 {month}.zip 并更新 daily.json",
            files=files,
        )
