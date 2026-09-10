#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.test_ledger — 唯一权威导出总账本 (ExportsLedger) 单元测试
"""

import json
from pathlib import Path
import shutil
import tempfile
import unittest

from studio.core.exports_ledger import ExportsLedger


class TestExportsLedger(unittest.TestCase):
    def setUp(self):
        self.test_dir = Path(tempfile.mkdtemp(prefix="studio_ledger_test_"))

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_empty_ledger_creation(self):
        ledger = ExportsLedger(self.test_dir)
        self.assertEqual(ledger.schema_version, 2)
        self.assertEqual(len(ledger.records), 0)
        self.assertEqual(len(ledger.get_exported_hashes()), 0)

    def test_append_records_and_persist(self):
        ledger = ExportsLedger(self.test_dir)
        records = [
            {
                "sourceHash": "hash_aaa",
                "sourcePath": "animals/fox.jpg",
                "sourceSize": 1024,
                "module": "main",
                "logicalId": "main:101",
                "order": 101,
                "batchId": "batch_001",
                "targetFile": "main/images/0101.webp",
                "targetHash": "target_aaa",
                "revision": 1,
            },
            {
                "sourceHash": "hash_bbb",
                "sourcePath": "daily/sep01.jpg",
                "sourceSize": 2048,
                "module": "daily",
                "logicalId": "daily:20260901",
                "order": None,
                "batchId": None,
                "targetFile": "daily/zips/202609.zip#20260901.webp",
                "targetHash": "target_bbb",
                "revision": 1,
            },
        ]
        added = ledger.append_records(records)
        self.assertEqual(added, 2)
        self.assertEqual(len(ledger.records), 2)
        self.assertEqual(ledger.get_max_order("main"), 101)

        # 重新加载验证持久化
        reloaded = ExportsLedger(self.test_dir)
        self.assertEqual(len(reloaded.records), 2)
        self.assertIn("hash_aaa", reloaded.get_exported_hashes())
        self.assertIn("hash_bbb", reloaded.get_exported_hashes())

    def test_duplicate_checks(self):
        ledger = ExportsLedger(self.test_dir)
        ledger.append_records([
            {
                "sourceHash": "hash_fox",
                "sourcePath": "animals/fox.jpg",
                "module": "main",
                "logicalId": "main:101",
                "order": 101,
            }
        ])

        # 1. 同模块不同关卡尝试复用相同图片 -> 严重冲突 (error)
        conflict, msg, sev = ledger.check_history_duplicate("hash_fox", module="main", logical_id="main:102")
        self.assertTrue(conflict)
        self.assertEqual(sev, "error")
        self.assertIn("禁止重复使用相同图片", msg)

        # 2. 跨模块复用 (例如 daily 想用同一张图片) -> 预警 (warning)
        conflict, msg, sev = ledger.check_history_duplicate("hash_fox", module="daily", logical_id="daily:20260901")
        self.assertTrue(conflict)
        self.assertEqual(sev, "warning")
        self.assertIn("跨模块复用", msg)

        # 3. 同关卡修图补丁 (logicalId 保持 main:101) -> 合法修订 (无冲突)
        conflict, msg, sev = ledger.check_history_duplicate("hash_fox", module="main", logical_id="main:101")
        self.assertFalse(conflict)
        self.assertIsNone(sev)

    def test_legacy_exported_json_is_ignored(self):
        """旧版 exported.json 兼容层已移除：文件存在也不再被读取或迁移。"""

        # 写入旧版 exported.json (v1.0.0 字典格式)
        legacy_file = self.test_dir / "exported.json"
        legacy_data = {
            "version": "1.0.0",
            "updated_at": "2026-09-05T00:00:00Z",
            "hashes": {
                "old_hash_1": {
                    "hash": "old_hash_1",
                    "path": "Nature/lake.jpg",
                    "file_size": 5000,
                    "export_type": "main",
                    "order": 201,
                    "target": "main/0201.webp",
                }
            },
        }
        legacy_file.write_text(json.dumps(legacy_data), encoding="utf-8")

        ledger = ExportsLedger(self.test_dir)
        # 不再读取旧版账本：记录为空，且不会因迁移而生成权威账本文件
        self.assertEqual(len(ledger.records), 0)
        self.assertFalse(ledger.ledger_file.exists())

    def test_read_only_no_migration_write(self):
        """read_only 下不产生任何写入（旧版迁移路径已移除，更无从落盘）。"""
        legacy_file = self.test_dir / "exported.json"
        legacy_data = {
            "version": "1.0.0",
            "updated_at": "2026-09-05T00:00:00Z",
            "hashes": {
                "old_hash_1": {
                    "hash": "old_hash_1",
                    "path": "Nature/lake.jpg",
                    "file_size": 5000,
                    "export_type": "main",
                    "order": 201,
                    "target": "main/0201.webp",
                }
            },
        }
        legacy_file.write_text(json.dumps(legacy_data), encoding="utf-8")

        ledger = ExportsLedger(self.test_dir, read_only=True)
        # 不再迁移
        self.assertEqual(len(ledger.records), 0)
        # 但不得写入 exports.json
        self.assertFalse(ledger.ledger_file.exists())

    def test_read_only_rejects_writes(self):
        """双保险：read_only 下 append_records / save 必须拒绝，不产生任何写入。"""
        ledger = ExportsLedger(self.test_dir, read_only=True)
        self.assertEqual(ledger.append_records([{
            "sourceHash": "h",
            "sourcePath": "a.jpg",
            "module": "main",
            "logicalId": "main:101",
        }]), 0)
        self.assertEqual(len(ledger.records), 0)
        ok, _ = ledger.save()
        self.assertFalse(ok)
        self.assertFalse(ledger.ledger_file.exists())


if __name__ == "__main__":
    unittest.main()
