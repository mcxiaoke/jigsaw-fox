#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.test_rollback — L1 Operation 回滚 / opId / rollback 事件重放 单元测试
"""

import json
from pathlib import Path
import shutil
import tempfile
import unittest

from studio.core.exports_ledger import ExportsLedger, new_op_id
from studio.core.export_rollback import list_ops, undo_last, undo_op


def _rec(hash_key: str, module: str = "main", logical_id: str | None = None,
         order: int = 101, batch_id: str | None = "batch_001",
         revision: int = 1, supersedes: str | None = None) -> dict:
    if logical_id is None:
        logical_id = f"{module}:{order}"
    return {
        "sourceHash": hash_key,
        "sourcePath": f"assets/{hash_key}.jpg",
        "sourceSize": 1024,
        "module": module,
        "logicalId": logical_id,
        "order": order,
        "batchId": batch_id,
        "targetFile": f"{module}/images/{order:04d}.webp",
        "revision": revision,
        "supersedes": supersedes,
    }


class TestOpIdBackfill(unittest.TestCase):
    def setUp(self):
        self.test_dir = Path(tempfile.mkdtemp(prefix="studio_rollback_test_"))

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_new_op_id_format(self):
        oid = new_op_id()
        self.assertTrue(oid.startswith("op_"))
        self.assertEqual(len(oid.split("_")), 3)

    def test_append_backfills_same_op_id_for_batch(self):
        ledger = ExportsLedger(self.test_dir)
        ledger.append_records([_rec("h1", order=101), _rec("h2", order=102)])
        self.assertEqual(len(ledger.records), 2)
        op_ids = {r.get("opId") for r in ledger.records}
        self.assertEqual(len(op_ids), 1)
        self.assertTrue(list(op_ids)[0].startswith("op_"))

    def test_idempotent_retry_no_new_op(self):
        ledger = ExportsLedger(self.test_dir)
        items = [_rec("h1", order=101), _rec("h2", order=102)]
        self.assertEqual(ledger.append_records(items), 2)
        op1 = {r.get("opId") for r in ledger.records}
        # 续跑重试：全部幂等跳过，不产生新记录/新 op
        self.assertEqual(ledger.append_records(items), 0)
        self.assertEqual(len(ledger.records), 2)
        op2 = {r.get("opId") for r in ledger.records}
        self.assertEqual(op1, op2)

    def test_explicit_op_id_respected(self):
        ledger = ExportsLedger(self.test_dir)
        ledger.append_records([_rec("h1")], op_id="op_manual_1")
        self.assertEqual(ledger.records[0]["opId"], "op_manual_1")


class TestRollbackOperation(unittest.TestCase):
    def setUp(self):
        self.test_dir = Path(tempfile.mkdtemp(prefix="studio_rollback_test_"))

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_rollback_releases_hashes(self):
        ledger = ExportsLedger(self.test_dir)
        ledger.append_records([_rec("h1", order=101), _rec("h2", order=102)])
        op_id = ledger.records[0]["opId"]

        ok, msg = ledger.rollback_operation(op_id)
        self.assertTrue(ok, msg)
        self.assertEqual(len(ledger.records), 0)
        self.assertEqual(ledger.get_exported_hashes(), set())
        # 防重恢复放行
        conflict, _, sev = ledger.check_history_duplicate("h1", module="main", logical_id="main:201")
        self.assertFalse(conflict)
        self.assertIsNone(sev)

        # 重复回滚同一 op 失败
        ok2, _ = ledger.rollback_operation(op_id)
        self.assertFalse(ok2)

    def test_rollback_writes_event_and_persists(self):
        ledger = ExportsLedger(self.test_dir)
        ledger.append_records([_rec("h1")])
        op_id = ledger.records[0]["opId"]
        rec_id = ledger.records[0]["recordId"]
        ok, _ = ledger.rollback_operation(op_id)
        self.assertTrue(ok)

        # 事件流含 rollback 行（自包含 recordIds）
        lines = ledger.events_file.read_text(encoding="utf-8").strip().splitlines()
        rollbacks = [json.loads(x) for x in lines if json.loads(x).get("action") == "rollback"]
        self.assertEqual(len(rollbacks), 1)
        self.assertEqual(rollbacks[0]["opId"], op_id)
        self.assertEqual(rollbacks[0]["recordIds"], [rec_id])

        # 重新加载后仍为空（物化投影已剔除）
        reloaded = ExportsLedger(self.test_dir)
        self.assertEqual(len(reloaded.records), 0)

    def test_rollback_patch_revives_superseded(self):
        ledger = ExportsLedger(self.test_dir)
        # 首次导出 (op1): main:1 rev1
        ledger.append_records([_rec("hash_v1", logical_id="main:1", order=1)])
        rec_v1_id = ledger.records[0]["recordId"]
        # 补丁导出 (op2): 同 logicalId rev2 supersedes 旧记录
        ledger.append_records([
            _rec("hash_v2", logical_id="main:1", order=1, revision=2, supersedes=rec_v1_id)
        ])
        op2 = ledger.records[1]["opId"]
        self.assertNotEqual(ledger.records[0]["opId"], op2)

        # patch 后 active 为 rev2
        active = ledger.get_active_record("main:1")
        self.assertEqual(active["sourceHash"], "hash_v2")

        # 撤销 op2 → rev1 自动复活为 active
        ok, _ = ledger.rollback_operation(op2)
        self.assertTrue(ok)
        active = ledger.get_active_record("main:1")
        self.assertEqual(active["sourceHash"], "hash_v1")
        self.assertEqual(active["recordId"], rec_v1_id)
        # rev1 素材恢复占用（同模块同 logicalId 合法，不同 logicalId 仍冲突）
        conflict, _, sev = ledger.check_history_duplicate("hash_v1", module="main", logical_id="main:1")
        self.assertFalse(conflict)
        self.assertIsNone(sev)
        conflict, _, sev = ledger.check_history_duplicate("hash_v1", module="main", logical_id="main:2")
        self.assertTrue(conflict)
        self.assertEqual(sev, "error")

    def test_rebuild_from_events_after_rollback(self):
        ledger = ExportsLedger(self.test_dir)
        ledger.append_records([_rec("h1", order=1), _rec("h2", order=2)])  # opA
        op_a = ledger.records[0]["opId"]
        ledger.append_records([_rec("h3", order=3), _rec("h4", order=4)])  # opB
        op_b = ledger.records[2]["opId"]
        self.assertNotEqual(op_a, op_b)

        ok, _ = ledger.rollback_operation(op_a)
        self.assertTrue(ok)

        # 删除权威 exports.json → 触发从事件流重建，被撤记录不得复活
        ledger.ledger_file.unlink()
        rebuilt = ExportsLedger(self.test_dir)
        self.assertTrue(rebuilt.ledger_file.exists())
        self.assertEqual(len(rebuilt.records), 2)
        self.assertEqual(rebuilt.records[0]["opId"], op_b)
        self.assertNotIn("h1", rebuilt.get_exported_hashes())
        self.assertNotIn("h2", rebuilt.get_exported_hashes())

    def test_read_only_rejects_rollback(self):
        ledger = ExportsLedger(self.test_dir)
        ledger.append_records([_rec("h1")])
        op_id = ledger.records[0]["opId"]

        ro = ExportsLedger(self.test_dir, read_only=True)
        ok, _ = ro.rollback_operation(op_id)
        self.assertFalse(ok)
        # 只读侧不影响可写侧数据
        again = ExportsLedger(self.test_dir)
        self.assertEqual(len(again.records), 1)


class TestUndoMainRelease(unittest.TestCase):
    def setUp(self):
        self.test_dir = Path(tempfile.mkdtemp(prefix="studio_rollback_test_"))
        # 预置 release/main 镜像（批次目录自包含）：batch_001(1~100) + batch_002(101~120)
        main_rel = self.test_dir / ".studio" / "release" / "main"
        (main_rel / "batches").mkdir(parents=True, exist_ok=True)
        index_p = main_rel / "index.json"
        index_p.write_text(json.dumps({
            "module": "main",
            "version": 2,
            "totalCount": 120,
            "maxOrder": 120,
            "updatedAt": "2026-09-09T00:00:00Z",
            "items": [
                {"batchId": "batch_001", "version": 1, "count": 100,
                 "startOrder": 1, "endOrder": 100,
                 "url": "batches/batch_001/index.json"},
                {"batchId": "batch_002", "version": 2, "count": 20,
                 "startOrder": 101, "endOrder": 120,
                 "url": "batches/batch_002/index.json"},
            ],
        }, ensure_ascii=False), encoding="utf-8")
        for bid in ("batch_001", "batch_002"):
            bdir = main_rel / "batches" / bid
            (bdir / "images").mkdir(parents=True, exist_ok=True)
            (bdir / "index.json").write_text(
                json.dumps({"batchId": bid}), encoding="utf-8")
            (bdir / "images" / f"{bid}.webp").write_bytes(b"img")

        # 记账：batch_002 两关（模拟一次导出）
        self.ledger = ExportsLedger(self.test_dir)
        self.ledger.append_records([
            _rec("h101", order=101, batch_id="batch_002"),
            _rec("h102", order=102, batch_id="batch_002"),
        ])
        self.op_id = self.ledger.records[0]["opId"]

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_list_ops(self):
        ops = list_ops(self.test_dir)
        self.assertEqual(len(ops), 1)
        self.assertEqual(ops[0]["opId"], self.op_id)
        self.assertEqual(ops[0]["modules"], ["main"])
        self.assertEqual(ops[0]["minOrder"], 101)
        self.assertEqual(ops[0]["maxOrder"], 102)

    def test_undo_dry_run_no_write(self):
        res = undo_op(self.test_dir, self.op_id, dry_run=True)
        self.assertTrue(res.get("ok"))
        self.assertTrue(res.get("dryRun"))
        # 不落盘
        self.assertEqual(len(ExportsLedger(self.test_dir).records), 2)
        index = json.loads(
            (self.test_dir / ".studio" / "release" / "main" / "index.json").read_text(encoding="utf-8")
        )
        self.assertEqual(len(index["items"]), 2)

    def test_undo_op_removes_records_and_cleans_release(self):
        res = undo_op(self.test_dir, self.op_id, clean_release=True)
        self.assertTrue(res.get("ok"), res.get("msg"))
        self.assertEqual(res.get("removedRecords"), 2)

        # ledger 记录清空
        ledger = ExportsLedger(self.test_dir)
        self.assertEqual(len(ledger.records), 0)

        # main index 仅剩 batch_001，maxOrder/totalCount 重算
        index = json.loads(
            (self.test_dir / ".studio" / "release" / "main" / "index.json").read_text(encoding="utf-8")
        )
        self.assertEqual([e["batchId"] for e in index["items"]], ["batch_001"])
        self.assertEqual(index["maxOrder"], 100)
        self.assertEqual(index["totalCount"], 100)
        # version 不回退
        self.assertEqual(index["version"], 2)

        # 批次目录：batch_002 整目录删除（含 index.json 与 images），batch_001 保留
        main_batches = self.test_dir / ".studio" / "release" / "main" / "batches"
        self.assertFalse((main_batches / "batch_002").exists())
        self.assertTrue((main_batches / "batch_001").exists())
        self.assertTrue((main_batches / "batch_001" / "images").exists())

        # 事件流含 rollback；审计流水含 rollback_export；撤销前有快照
        events = self.test_dir / ".studio" / "ledger" / "exports_events.jsonl"
        lines = events.read_text(encoding="utf-8").strip().splitlines()
        self.assertTrue(any(json.loads(x).get("action") == "rollback" for x in lines))
        audit = self.test_dir / ".studio" / "logs" / "exports.jsonl"
        audit_text = audit.read_text(encoding="utf-8")
        self.assertIn("rollback_export", audit_text)
        backups = (self.test_dir / ".studio" / "ledger" / "backups").glob("exports-*.json")
        self.assertTrue(list(backups))

    def test_undo_last(self):
        res = undo_last(self.test_dir, module="main")
        self.assertTrue(res.get("ok"))
        self.assertEqual(len(ExportsLedger(self.test_dir).records), 0)


class TestUndoDailyRelease(unittest.TestCase):
    """L1.1: daily 镜像投影自动回退（month 定位）"""

    def setUp(self):
        self.test_dir = Path(tempfile.mkdtemp(prefix="studio_rollback_test_"))
        daily_rel = self.test_dir / ".studio" / "release" / "daily"
        (daily_rel / "zips").mkdir(parents=True, exist_ok=True)
        (daily_rel / "zips" / "202608.zip").write_bytes(b"old-zip")
        (daily_rel / "zips" / "202609.zip").write_bytes(b"new-zip")
        (daily_rel / "index.json").write_text(json.dumps({
            "module": "daily",
            "version": 2,
            "currentMonth": "202609",
            "updatedAt": "2026-09-09T00:00:00Z",
            "items": [
                {"month": "202608", "totalCount": 31,
                 "zipUrl": "zips/202608.zip", "updatedAt": "2026-08-01T00:00:00Z"},
                {"month": "202609", "totalCount": 30,
                 "zipUrl": "zips/202609.zip", "updatedAt": "2026-09-01T00:00:00Z"},
            ],
        }, ensure_ascii=False), encoding="utf-8")

        self.ledger = ExportsLedger(self.test_dir)
        self.ledger.append_records([
            {"sourceHash": "dh1", "sourcePath": "days/20260901.jpg",
             "sourceSize": 100, "module": "daily", "logicalId": "daily:202609",
             "month": "202609", "revision": 1,
             "targetFile": "daily/zips/202609.zip#20260901.webp"},
        ])
        self.op_id = self.ledger.records[0]["opId"]

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_month_field_persisted(self):
        rec = ExportsLedger(self.test_dir).records[0]
        self.assertEqual(rec.get("month"), "202609")

    def test_undo_daily_removes_month_and_zip(self):
        res = undo_op(self.test_dir, self.op_id, clean_release=True)
        self.assertTrue(res.get("ok"), res.get("msg"))
        self.assertIn("daily 镜像回退", res["msg"])

        index = json.loads(
            (self.test_dir / ".studio" / "release" / "daily" / "index.json").read_text(encoding="utf-8")
        )
        self.assertEqual([e["month"] for e in index["items"]], ["202608"])
        self.assertEqual(index["currentMonth"], "202608")
        daily_zips = self.test_dir / ".studio" / "release" / "daily" / "zips"
        self.assertFalse((daily_zips / "202609.zip").exists())
        self.assertTrue((daily_zips / "202608.zip").exists())
        # ledger 记录清空、防重释放
        self.assertEqual(len(ExportsLedger(self.test_dir).records), 0)


class TestUndoPackRelease(unittest.TestCase):
    """L1.1: events/collections 镜像投影自动回退（packId 定位）"""

    def setUp(self):
        self.test_dir = Path(tempfile.mkdtemp(prefix="studio_rollback_test_"))
        ev_rel = self.test_dir / ".studio" / "release" / "events"
        (ev_rel / "packs").mkdir(parents=True)
        (ev_rel / "covers").mkdir(parents=True)
        (ev_rel / "packs" / "ev1.zip").write_bytes(b"z1")
        (ev_rel / "packs" / "ev2.zip").write_bytes(b"z2")
        (ev_rel / "covers" / "ev1.webp").write_bytes(b"c1")
        (ev_rel / "covers" / "ev2.webp").write_bytes(b"c2")
        (ev_rel / "index.json").write_text(json.dumps({
            "module": "events",
            "version": 2,
            "updatedAt": "2026-09-09T00:00:00Z",
            "items": [
                {"id": "ev1", "title": "A", "zipUrl": "packs/ev1.zip",
                 "coverUrl": "covers/ev1.webp", "totalCount": 2},
                {"id": "ev2", "title": "B", "zipUrl": "packs/ev2.zip",
                 "coverUrl": "covers/ev2.webp", "totalCount": 3},
            ],
        }, ensure_ascii=False), encoding="utf-8")

        self.ledger = ExportsLedger(self.test_dir)
        self.ledger.append_records([
            {"sourceHash": "e1", "sourcePath": "x/ev1a.jpg", "sourceSize": 10,
             "module": "events", "logicalId": "events:ev1:ev1a.jpg",
             "packId": "ev1", "revision": 1,
             "targetFile": "events/packs/ev1.zip#ev1a.webp"},
            {"sourceHash": "e2", "sourcePath": "x/ev1b.jpg", "sourceSize": 11,
             "module": "events", "logicalId": "events:ev1:ev1b.jpg",
             "packId": "ev1", "revision": 1,
             "targetFile": "events/packs/ev1.zip#ev1b.webp"},
        ])
        self.op_id = self.ledger.records[0]["opId"]

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_pack_id_field_persisted(self):
        rec = ExportsLedger(self.test_dir).records[0]
        self.assertEqual(rec.get("packId"), "ev1")

    def test_undo_events_removes_entry_zip_cover(self):
        res = undo_op(self.test_dir, self.op_id, clean_release=True)
        self.assertTrue(res.get("ok"), res.get("msg"))
        self.assertIn("events 镜像回退", res["msg"])

        index = json.loads(
            (self.test_dir / ".studio" / "release" / "events" / "index.json").read_text(encoding="utf-8")
        )
        self.assertEqual([e["id"] for e in index["items"]], ["ev2"])
        ev_rel = self.test_dir / ".studio" / "release" / "events"
        self.assertFalse((ev_rel / "packs" / "ev1.zip").exists())
        self.assertFalse((ev_rel / "covers" / "ev1.webp").exists())
        self.assertTrue((ev_rel / "packs" / "ev2.zip").exists())
        self.assertTrue((ev_rel / "covers" / "ev2.webp").exists())
        self.assertEqual(len(ExportsLedger(self.test_dir).records), 0)


class TestUndoAtomicity(unittest.TestCase):
    """L1.2 原子撤销：先镜像后账本，任一模块失败整体还原、账本不动"""

    def setUp(self):
        self.test_dir = Path(tempfile.mkdtemp(prefix="studio_rollback_test_"))
        main_rel = self.test_dir / ".studio" / "release" / "main"
        (main_rel / "batches").mkdir(parents=True, exist_ok=True)
        index_p = main_rel / "index.json"
        self.index_before = {
            "module": "main", "version": 2, "totalCount": 120, "maxOrder": 120,
            "updatedAt": "2026-09-09T00:00:00Z",
            "items": [
                {"batchId": "batch_001", "version": 1, "count": 100,
                 "startOrder": 1, "endOrder": 100,
                 "url": "batches/batch_001/index.json"},
                {"batchId": "batch_002", "version": 2, "count": 20,
                 "startOrder": 101, "endOrder": 120,
                 "url": "batches/batch_002/index.json"},
            ],
        }
        index_p.write_text(json.dumps(self.index_before, ensure_ascii=False), encoding="utf-8")
        for bid in ("batch_001", "batch_002"):
            bdir = main_rel / "batches" / bid
            (bdir / "images").mkdir(parents=True, exist_ok=True)
            (bdir / "images" / f"{bid}.webp").write_bytes(b"img")

        ledger = ExportsLedger(self.test_dir)
        ledger.append_records([
            {"sourceHash": "h1", "sourcePath": "assets/h1.jpg", "sourceSize": 1024,
             "module": "main", "logicalId": "main:101", "order": 101,
             "batchId": "batch_002", "revision": 1,
             "targetFile": "main/images/0101.webp"},
            {"sourceHash": "h2", "sourcePath": "assets/h2.jpg", "sourceSize": 1024,
             "module": "main", "logicalId": "main:102", "order": 102,
             "batchId": "batch_002", "revision": 1,
             "targetFile": "main/images/0102.webp"},
        ])
        self.op_id = ledger.records[0]["opId"]

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_mirror_failure_aborts_entire_rollback(self):
        """注入镜像失败：整体失败、账本不动、index 从快照还原、批次目录还原"""
        import studio.core.export_rollback as rb

        original = rb._cleanup_main_release

        def failing(src_dir, batch_ids, trash_dir):
            res = original(src_dir, batch_ids, trash_dir)
            res["errors"].append("注入失败: 模拟磁盘错误")
            return res

        rb._cleanup_main_release = failing
        try:
            res = undo_op(self.test_dir, self.op_id, clean_release=True)
        finally:
            rb._cleanup_main_release = original

        self.assertFalse(res.get("ok"), res.get("msg"))
        self.assertTrue(res.get("errors"))
        # 账本未动
        self.assertEqual(len(ExportsLedger(self.test_dir).records), 2)
        # index 已从快照还原
        index = json.loads(
            (self.test_dir / ".studio" / "release" / "main" / "index.json").read_text(encoding="utf-8")
        )
        self.assertEqual([e["batchId"] for e in index["items"]], ["batch_001", "batch_002"])
        self.assertEqual(index["totalCount"], 120)
        # 批次目录已从回收站还原
        self.assertTrue((self.test_dir / ".studio" / "release" / "main" / "batches" / "batch_002").exists())
        self.assertTrue((self.test_dir / ".studio" / "release" / "main" / "batches" / "batch_002" / "images" / "batch_002.webp").exists())
        # 审计流水记录了失败
        audit = (self.test_dir / ".studio" / "logs" / "exports.jsonl").read_text(encoding="utf-8")
        self.assertIn("rollback_export", audit)
        self.assertIn("fail", audit)

    def test_batch_id_whitelist_rejects_traversal(self):
        """batchId 含路径穿越字符时拒绝回退（不产生任何删除）"""
        import studio.core.export_rollback as rb

        self.assertIsNone(rb._safe_batch_id("../evil"))
        self.assertIsNone(rb._safe_batch_id("a/b"))
        self.assertIsNone(rb._safe_batch_id(".."))
        self.assertEqual(rb._safe_batch_id("batch_001-X9"), "batch_001-X9")

        # 注入恶意 batchId 的记录 → 回退被拒绝，整体失败
        ledger = ExportsLedger(self.test_dir)
        ledger.append_records([
            {"sourceHash": "evil", "sourcePath": "assets/evil.jpg", "sourceSize": 1,
             "module": "main", "logicalId": "main:999", "order": 999,
             "batchId": "../../escape", "revision": 1,
             "targetFile": "main/images/0999.webp"},
        ])
        evil_op = [r for r in ledger.records if r.get("batchId") == "../../escape"][0]["opId"]
        res = undo_op(self.test_dir, evil_op, clean_release=True)
        self.assertFalse(res.get("ok"))
        # escape 目录未被创建，release 内无越界产物
        self.assertFalse((self.test_dir / ".studio" / "release" / "main" / "escape").exists())

    def test_success_returns_trashed_files(self):
        """成功回滚返回回收站文件清单，批次目录不在 release 内"""
        res = undo_op(self.test_dir, self.op_id, clean_release=True)
        self.assertTrue(res.get("ok"), res.get("msg"))
        self.assertIn("main/batches/batch_002", res.get("trashedFiles") or [])
        self.assertFalse(
            (self.test_dir / ".studio" / "release" / "main" / "batches" / "batch_002").exists()
        )
        self.assertEqual(len(ExportsLedger(self.test_dir).records), 0)


if __name__ == "__main__":
    unittest.main()
