#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.test_workspace — Studio 私有工作区管理与数据迁移测试套件
"""

import json
from pathlib import Path
import shutil
import tempfile
import unittest

from studio.core.workspace import StudioWorkspace


class TestStudioWorkspace(unittest.TestCase):
    def setUp(self):
        self.test_dir = Path(tempfile.mkdtemp(prefix="studio_ws_test_"))

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_ensure_structure(self):
        ws = StudioWorkspace(self.test_dir)
        self.assertTrue(ws.studio_dir.is_dir())
        self.assertTrue(ws.cache_dir.is_dir())
        self.assertTrue(ws.ledger_dir.is_dir())
        self.assertTrue(ws.logs_dir.is_dir())
        self.assertTrue(ws.staging_dir.is_dir())
        self.assertTrue(ws.release_dir.is_dir())
        self.assertTrue(ws.thumbs_dir.is_dir())

    def test_legacy_tags_migration(self):
        # 预置根目录 legacy tags.json
        legacy_tags = self.test_dir / "tags.json"
        sample_data = [{"path": "test.jpg", "tags": ["Nature"]}]
        legacy_tags.write_text(json.dumps(sample_data), encoding="utf-8")

        ws = StudioWorkspace(self.test_dir)
        self.assertTrue(ws.tags_file.exists())
        loaded = json.loads(ws.tags_file.read_text(encoding="utf-8"))
        self.assertEqual(loaded[0]["tags"], ["Nature"])

    def test_legacy_db_migration(self):
        # 预置根目录 legacy .studio.db
        legacy_db = self.test_dir / ".studio.db"
        legacy_db.write_bytes(b"SQLite format 3 mock content")

        ws = StudioWorkspace(self.test_dir)
        self.assertFalse(legacy_db.exists())
        self.assertTrue(ws.db_file.exists())
        self.assertEqual(ws.db_file.read_bytes(), b"SQLite format 3 mock content")

    def test_audit_logs(self):
        ws = StudioWorkspace(self.test_dir)
        ws.log_operation("tag_add", path="cats/c1.jpg", tag="Pets")
        ws.log_export("export_main", count=10, version=101)

        self.assertTrue(ws.operations_log.exists())
        self.assertTrue(ws.exports_log.exists())

        op_lines = ws.operations_log.read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(len(op_lines), 1)
        op_data = json.loads(op_lines[0])
        self.assertEqual(op_data["action"], "tag_add")
        self.assertEqual(op_data["tag"], "Pets")
        self.assertIn("timestamp", op_data)

        exp_lines = ws.exports_log.read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(len(exp_lines), 1)
        exp_data = json.loads(exp_lines[0])
        self.assertEqual(exp_data["action"], "export_main")
        self.assertEqual(exp_data["count"], 10)

    def test_copy_release_to_out(self):
        ws = StudioWorkspace(self.test_dir)
        # 在 release/main 中构建文件
        rel_main = ws.release_dir / "main"
        rel_main.mkdir(parents=True)
        (rel_main / "index.json").write_text('{"module": "main"}', encoding="utf-8")
        batches_dir = rel_main / "batches"
        batches_dir.mkdir()
        (batches_dir / "batch_001.json").write_text('{"batchId": "batch_001"}', encoding="utf-8")

        out_dir = self.test_dir / "cdn_out"
        copied = ws.copy_release_to_out("main", out_dir)

        self.assertIn(str((out_dir / "main" / "index.json").resolve()), copied)
        self.assertIn(str((out_dir / "main" / "batches" / "batch_001.json").resolve()), copied)
        self.assertTrue((out_dir / "main" / "index.json").exists())
        self.assertTrue((out_dir / "main" / "batches" / "batch_001.json").exists())


if __name__ == "__main__":
    unittest.main()
