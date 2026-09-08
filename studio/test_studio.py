#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.test_studio — Content Studio 核心功能与自动化回归测试套件
"""

import json
import logging
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

_pkg_dir = Path(__file__).resolve().parent
_root_dir = _pkg_dir.parent
if str(_root_dir) not in sys.path:
    sys.path.insert(0, str(_root_dir))

from studio.core.export_tracker import (
    get_exported_hashes,
    get_exported_map,
    load_exported_ledger,
    record_exports,
    save_exported_ledger,
)
from studio.core.image_proc import HAS_PIL, convert_image, generate_thumbnail_bytes, make_rename
from studio.core.scanner import (
    compute_file_sha256,
    find_duplicate_groups,
    find_tags_file,
    get_image_info,
    scan_image_infos,
    scan_images,
)
from studio.core.tags_manager import (
    extract_real_tags,
    is_real_tag,
    merge_scanned_images,
    normalize_records,
    save_tags_file,
)
from studio.exporters import get_exporter
from studio.server import DEFAULT_LOG_FILE, logger, setup_logger
from studio.test_frontend import TestFrontendSmoke
from studio.taxonomy import (
    ALL_CANONICAL_TAGS,
    CATALOG_DEFS,
    CATALOG_TO_TAGS_MAP,
    SPECIFIC_TAG_DEFS,
    TAG_TO_CATALOGS,
    TAG_ZH,
    get_catalogs_for_tags,
    guess_tags_from_path,
    normalize_token,
)


class TestTaxonomy(unittest.TestCase):
    """测试分类与标签体系 (SSOT)"""

    def test_definitions(self):
        self.assertEqual(len(CATALOG_DEFS), 17)
        self.assertEqual(len(SPECIFIC_TAG_DEFS), 17)
        self.assertEqual(len(ALL_CANONICAL_TAGS), 17)
        self.assertIn("Pets", ALL_CANONICAL_TAGS)
        self.assertIn("Landscapes", ALL_CANONICAL_TAGS)
        self.assertIn("Colors", ALL_CANONICAL_TAGS)
        self.assertIn("Composition", ALL_CANONICAL_TAGS)
        self.assertIn("Holidays", ALL_CANONICAL_TAGS)
        self.assertIn("Flowers", ALL_CANONICAL_TAGS)
        self.assertIn("Animals", ALL_CANONICAL_TAGS)
        self.assertIn("Cities", ALL_CANONICAL_TAGS)
        self.assertIn("Structures", ALL_CANONICAL_TAGS)
        self.assertIn("People", ALL_CANONICAL_TAGS)
        self.assertIn("Objects", ALL_CANONICAL_TAGS)

    def test_normalization(self):
        # 英文单复数与细分词识别归一化
        self.assertEqual(normalize_token("cat"), "Pets")
        self.assertEqual(normalize_token("Cats"), "Pets")
        self.assertEqual(normalize_token("ocean"), "Landscapes")
        self.assertEqual(normalize_token("Oceans"), "Landscapes")
        self.assertEqual(normalize_token("city"), "Cities")
        self.assertEqual(normalize_token("castle"), "Structures")
        self.assertEqual(normalize_token("portrait"), "People")
        self.assertEqual(normalize_token("clock"), "Objects")
        self.assertEqual(normalize_token("illustration"), "Art")
        self.assertEqual(normalize_token("holiday"), "Holidays")
        self.assertEqual(normalize_token("sports"), "Holidays")
        self.assertEqual(normalize_token("Christmas"), "Holidays")
        self.assertEqual(normalize_token("rainbow"), "Colors")
        self.assertEqual(normalize_token("flat_lay"), "Composition")

        # 中文别名
        self.assertEqual(normalize_token("猫咪"), "Pets")
        self.assertEqual(normalize_token("雪山"), "Landscapes")
        self.assertEqual(normalize_token("城市"), "Cities")
        self.assertEqual(normalize_token("建筑"), "Structures")
        self.assertEqual(normalize_token("人物"), "People")
        self.assertEqual(normalize_token("复古"), "Objects")
        self.assertEqual(normalize_token("物品"), "Objects")
        self.assertEqual(normalize_token("甜点"), "Food")
        self.assertEqual(normalize_token("花卉"), "Flowers")
        self.assertEqual(normalize_token("庆典"), "Holidays")
        self.assertEqual(normalize_token("组合"), "Composition")
        self.assertEqual(normalize_token("色彩"), "Colors")

    def test_path_guessing(self):
        p1 = Path("D:/images/Animals/Cats/001.jpg")
        self.assertEqual(guess_tags_from_path(p1), ["Pets"])

        p2 = Path("D:/images/Natural_Landscape/Mountains/002.webp")
        self.assertEqual(guess_tags_from_path(p2), ["Landscapes"])

        # 严格不从文件名推断
        p3 = Path("D:/images/Misc/my_cat_photo.jpg")
        self.assertEqual(guess_tags_from_path(p3), ["Others"])

        # 历史 cat_* 目录兼容映射
        p4 = Path("D:/images/cat_nature/003.jpg")
        self.assertEqual(guess_tags_from_path(p4), ["Nature"])

    def test_catalogs_mapping(self):
        cats = get_catalogs_for_tags(["Pets", "Landscapes"])
        self.assertIn("Pets", cats)
        self.assertIn("Landscapes", cats)


class TestCoreAndExporters(unittest.TestCase):
    """测试核心业务逻辑与资产导出器"""

    def setUp(self):
        self.test_dir = Path(tempfile.mkdtemp(prefix="studio_test_"))
        self.src_dir = self.test_dir / "src"
        self.out_dir = self.test_dir / "out"
        self.src_dir.mkdir(parents=True)
        self.out_dir.mkdir(parents=True)

        # 创建几个测试图片 (利用 Pillow 或直接写入最小测试字节)
        if HAS_PIL:
            from PIL import Image

            cat_dir = self.src_dir / "Cats"
            cat_dir.mkdir()
            for i in range(1, 4):
                img = Image.new("RGB", (100, 100), color=(100 * i, 50, 200))
                img.save(cat_dir / f"cat_{i:02d}.jpg", "JPEG")

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_scan_and_tags_manager(self):
        images = scan_images(self.src_dir)
        self.assertEqual(len(images), 3)

        # 并发提取元数据
        image_infos = scan_image_infos(images, self.src_dir)
        self.assertEqual(len(image_infos), 3)
        sample_info = list(image_infos.values())[0]
        self.assertEqual(sample_info["width"], 100)
        self.assertEqual(sample_info["height"], 100)
        self.assertEqual(sample_info["format"], "JPEG")
        self.assertGreater(sample_info["size"], 0)

        # 合并扫描与智能推断 (带元数据注入)
        records, stats = merge_scanned_images(images, self.src_dir, None, image_infos=image_infos)
        self.assertEqual(len(records), 3)
        self.assertEqual(records[0]["tags"], ["Pets"])
        self.assertEqual(records[0]["catalogs"], ["Pets"])
        self.assertFalse(records[0]["review_required"])
        self.assertEqual(records[0]["width"], 100)
        self.assertEqual(records[0]["height"], 100)
        self.assertEqual(records[0]["format"], "JPEG")

        # 保存 tags.json (持久化元数据)
        ok, dest_file, count = save_tags_file(self.src_dir, records)
        self.assertTrue(ok)
        self.assertEqual(count, 3)
        self.assertTrue(Path(dest_file).exists())

        # 重新读取归一化 (校验元数据完整回载)
        tag_file = find_tags_file(self.src_dir)
        self.assertIsNotNone(tag_file)
        loaded = json.loads(tag_file.read_text(encoding="utf-8"))
        norm_records, fmt_name = normalize_records(loaded, self.src_dir)
        self.assertEqual(fmt_name, "list")
        self.assertEqual(len(norm_records), 3)
        self.assertEqual(norm_records[0]["tags"], ["Pets"])
        self.assertEqual(norm_records[0]["width"], 100)
        self.assertEqual(norm_records[0]["height"], 100)
        self.assertEqual(norm_records[0]["format"], "JPEG")
        self.assertGreater(norm_records[0]["size"], 0)

    def test_main_exporter(self):
        logs = []
        exporter = get_exporter(
            exp_type="main",
            data={
                "startOrder": 101,
                "version": 5,
                "format": "webp" if HAS_PIL else "original",
                "rename": "sequence",
            },
            src_p=self.src_dir,
            out_p=self.out_dir,
            http_base="http://test.local/data",
            log_fn=lambda msg, lvl="info": logs.append((lvl, msg)),
        )
        exporter.validate()
        result = exporter.execute()

        self.assertTrue(result.success)
        main_index = self.out_dir / "main" / "index.json"
        self.assertTrue(main_index.exists())
        idx_data = json.loads(main_index.read_text(encoding="utf-8"))
        self.assertEqual(idx_data["version"], 5)
        self.assertEqual(idx_data["totalCount"], 3)
        self.assertIn("updatedAt", idx_data)
        self.assertEqual(len(idx_data["items"]), 1)

        batch_json = self.out_dir / "main" / "batches" / "batch_001.json"
        self.assertTrue(batch_json.exists())
        b_data = json.loads(batch_json.read_text(encoding="utf-8"))
        self.assertEqual(b_data["count"], 3)
        self.assertEqual(len(b_data["items"]), 3)
        self.assertEqual(b_data["items"][0]["order"], 101)
        self.assertEqual(b_data["items"][0]["tags"], ["Pets"])

        # 验证 manifest.json 纯路由清单 (v2.3 规范相对路径与 schemaVersion 4)
        manifest_json = self.out_dir / "manifest.json"
        self.assertTrue(manifest_json.exists())
        m_data = json.loads(manifest_json.read_text(encoding="utf-8"))
        self.assertIn("main", m_data["modules"])
        self.assertEqual(m_data["modules"]["main"]["version"], 5)
        self.assertEqual(m_data["modules"]["main"]["url"], "main/index.json")
        self.assertEqual(m_data["modules"]["main"]["totalCount"], 3)
        self.assertIn("updatedAt", m_data["modules"]["main"])

    def test_daily_exporter(self):
        logs = []
        exporter = get_exporter(
            exp_type="daily",
            data={
                "month": "202609",
                "format": "webp" if HAS_PIL else "original",
                "rename": "date",
            },
            src_p=self.src_dir,
            out_p=self.out_dir,
            http_base="http://test.local/data",
            log_fn=lambda msg, lvl="info": logs.append((lvl, msg)),
        )
        exporter.validate()
        result = exporter.execute()

        self.assertTrue(result.success)
        daily_zip = self.out_dir / "daily" / "zips" / "202609.zip"
        self.assertTrue(daily_zip.exists())

        daily_index = self.out_dir / "daily" / "index.json"
        self.assertTrue(daily_index.exists())
        d_data = json.loads(daily_index.read_text(encoding="utf-8"))
        self.assertEqual(d_data["currentMonth"], "202609")
        self.assertIn("updatedAt", d_data)
        self.assertEqual(len(d_data["items"]), 1)
        self.assertEqual(d_data["items"][0]["month"], "202609")
        self.assertEqual(d_data["items"][0]["totalCount"], 3)
        self.assertIn("updatedAt", d_data["items"][0])

        manifest_json = self.out_dir / "manifest.json"
        self.assertTrue(manifest_json.exists())
        m_data = json.loads(manifest_json.read_text(encoding="utf-8"))
        self.assertIn("daily", m_data["modules"])
        self.assertEqual(m_data["modules"]["daily"]["count"], 3)

    def test_event_exporter(self):
        logs = []
        exporter = get_exporter(
            exp_type="event",
            data={
                "eventId": "test_event_2026",
                "title": "Spooky Halloween",
                "titleZh": "万圣节狂欢",
                "description": "Halloween puzzles",
                "descZh": "万圣节精彩拼图挑战",
                "outputMode": "zip",
                "format": "webp" if HAS_PIL else "original",
                "rename": "none",
            },
            src_p=self.src_dir,
            out_p=self.out_dir,
            http_base="http://test.local/data",
            log_fn=lambda msg, lvl="info": logs.append((lvl, msg)),
        )
        exporter.validate()
        result = exporter.execute()

        self.assertTrue(result.success)
        event_zip = self.out_dir / "events" / "packs" / "test_event_2026.zip"
        self.assertTrue(event_zip.exists())

        events_json = self.out_dir / "events" / "index.json"
        self.assertTrue(events_json.exists())
        ev_data = json.loads(events_json.read_text(encoding="utf-8"))
        self.assertIn("items", ev_data)
        self.assertEqual(len(ev_data["items"]), 1)
        self.assertEqual(ev_data["items"][0]["id"], "test_event_2026")
        self.assertEqual(ev_data["items"][0]["title"], "Spooky Halloween")
        self.assertEqual(ev_data["items"][0]["titleZh"], "万圣节狂欢")
        self.assertEqual(ev_data["items"][0]["desc"], "Halloween puzzles")
        self.assertEqual(ev_data["items"][0]["descZh"], "万圣节精彩拼图挑战")
        self.assertEqual(ev_data["items"][0]["totalCount"], 3)
        self.assertIn("updatedAt", ev_data["items"][0])

    def test_collection_exporter(self):
        logs = []
        exporter = get_exporter(
            exp_type="collection",
            data={
                "collectionId": "test_col_2026",
                "title": "Masterpieces Vol 1",
                "titleZh": "名画系列第一辑",
                "desc": "Classic masterpieces collection",
                "descZh": "精选传世名画合集",
                "outputMode": "zip",
                "format": "webp" if HAS_PIL else "original",
                "rename": "none",
            },
            src_p=self.src_dir,
            out_p=self.out_dir,
            http_base="http://test.local/data",
            log_fn=lambda msg, lvl="info": logs.append((lvl, msg)),
        )
        exporter.validate()
        result = exporter.execute()

        self.assertTrue(result.success)
        col_zip = self.out_dir / "collections" / "packs" / "test_col_2026.zip"
        self.assertTrue(col_zip.exists())

        cols_json = self.out_dir / "collections" / "index.json"
        self.assertTrue(cols_json.exists())
        col_data = json.loads(cols_json.read_text(encoding="utf-8"))
        self.assertIn("items", col_data)
        self.assertEqual(len(col_data["items"]), 1)
        self.assertEqual(col_data["items"][0]["id"], "test_col_2026")
        self.assertEqual(col_data["items"][0]["title"], "Masterpieces Vol 1")
        self.assertEqual(col_data["items"][0]["titleZh"], "名画系列第一辑")
        self.assertEqual(col_data["items"][0]["desc"], "Classic masterpieces collection")
        self.assertEqual(col_data["items"][0]["descZh"], "精选传世名画合集")
        self.assertEqual(col_data["items"][0]["totalCount"], 3)
        self.assertIn("updatedAt", col_data["items"][0])

    def test_pack_exporter_title_validation(self):
        # 验证未提供 title 或 title 为空时 validate() 抛出异常
        exporter = get_exporter(
            exp_type="collection",
            data={
                "collectionId": "test_col_no_title",
                "outputMode": "zip",
            },
            src_p=self.src_dir,
            out_p=self.out_dir,
            http_base="http://test.local/data",
            log_fn=lambda msg, lvl="info": None,
        )
        with self.assertRaises(ValueError) as ctx:
            exporter.validate()
        self.assertIn("必须填写标题", str(ctx.exception))


class TestExportTracker(unittest.TestCase):
    """测试已导出账本管理 (exported.json)"""

    def setUp(self):
        self.test_dir = Path(tempfile.mkdtemp(prefix="studio_tracker_"))

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_load_and_save_empty_ledger(self):
        ledger = load_exported_ledger(self.test_dir)
        self.assertEqual(ledger["total_exported"], 0)
        self.assertEqual(len(ledger["hashes"]), 0)

        ok, msg = save_exported_ledger(self.test_dir, ledger)
        self.assertTrue(ok)
        self.assertTrue((self.test_dir / "exported.json").exists())

    def test_record_exports(self):
        items = [
            {
                "hash": "abc123def456",
                "path": "Animals/lion.jpg",
                "export_type": "main",
                "target": "main/101.webp",
                "order": 101,
            },
            {
                "hash": "789xyz000111",
                "path": "Flowers/rose.jpg",
                "export_type": "daily",
                "target": "daily/202609.zip#20260901.webp",
                "month": "202609",
            },
        ]
        ledger, new_count = record_exports(self.test_dir, items)
        self.assertEqual(new_count, 2)
        self.assertEqual(ledger["total_exported"], 2)

        # 校验哈希集合
        hashes = get_exported_hashes(self.test_dir)
        self.assertIn("abc123def456", hashes)
        self.assertIn("789xyz000111", hashes)

        # 校验路径映射
        exp_map = get_exported_map(self.test_dir)
        self.assertIn("Animals/lion.jpg", exp_map)
        self.assertEqual(exp_map["Animals/lion.jpg"]["order"], 101)


class TestHashAndReconciliation(unittest.TestCase):
    """测试 SHA-256 增量哈希计算与改名/移动自动认领引擎"""

    def setUp(self):
        self.test_dir = Path(tempfile.mkdtemp(prefix="studio_recon_"))
        self.src_dir = self.test_dir / "src"
        self.src_dir.mkdir()

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_compute_file_sha256(self):
        sample_file = self.src_dir / "test.txt"
        sample_file.write_text("Hello Jigsaw Fox Studio!", encoding="utf-8")
        h = compute_file_sha256(sample_file)
        self.assertEqual(len(h), 64)

        # 验证相同内容哈希严格相等
        copy_file = self.src_dir / "test_copy.txt"
        copy_file.write_text("Hello Jigsaw Fox Studio!", encoding="utf-8")
        self.assertEqual(compute_file_sha256(copy_file), h)

    def test_auto_reconciliation_on_rename_or_move(self):
        if not HAS_PIL:
            self.skipTest("Pillow not installed")

        from PIL import Image

        # 1. 初始状态：生成一张原始图片 Animals/old_cat.jpg
        orig_dir = self.src_dir / "Animals"
        orig_dir.mkdir(parents=True)
        img_p = orig_dir / "old_cat.jpg"
        im = Image.new("RGB", (120, 120), color=(255, 100, 50))
        im.save(img_p, "JPEG")

        images = scan_images(self.src_dir)
        infos = scan_image_infos(images, self.src_dir)
        records, stats = merge_scanned_images(images, self.src_dir, None, image_infos=infos)

        # 用户进行了精细的人工打标并确认复核
        records[0]["tags"] = ["Pets"]
        records[0]["review_required"] = False
        records[0]["subject"] = "波斯猫"
        records[0]["scene"] = "室内木地板"
        save_tags_file(self.src_dir, records)

        old_hash = records[0]["hash"]
        self.assertTrue(len(old_hash) == 64)

        # 2. 模拟文件在操作系统中被改名并移动到了新目录 Pets/new_kitten.jpg
        new_dir = self.src_dir / "Pets"
        new_dir.mkdir(parents=True)
        new_img_p = new_dir / "new_kitten.jpg"
        img_p.rename(new_img_p)

        # 3. 再次扫描目录并自动对齐
        tag_file = find_tags_file(self.src_dir)
        self.assertIsNotNone(tag_file)
        loaded_raw, _ = normalize_records(json.loads(tag_file.read_text(encoding="utf-8")), self.src_dir)
        new_images = scan_images(self.src_dir)
        new_infos = scan_image_infos(new_images, self.src_dir)
        new_records, new_stats = merge_scanned_images(new_images, self.src_dir, loaded_raw, image_infos=new_infos)

        # 4. 验证引擎自动识别并完美继承
        self.assertEqual(len(new_records), 1)
        self.assertEqual(new_stats["reconciledCount"], 1)
        self.assertEqual(new_records[0]["path"], "Pets/new_kitten.jpg")
        self.assertEqual(new_records[0]["file"], "new_kitten.jpg")
        self.assertEqual(new_records[0]["hash"], old_hash)
        self.assertEqual(new_records[0]["tags"], ["Pets"])
        self.assertEqual(new_records[0]["subject"], "波斯猫")
        self.assertEqual(new_records[0]["scene"], "室内木地板")
        self.assertFalse(new_records[0]["review_required"])


class TestExporterTrackingAndDeduplication(unittest.TestCase):
    """测试导出器自动记账与防重复排除功能"""

    def setUp(self):
        self.test_dir = Path(tempfile.mkdtemp(prefix="studio_exp_dedup_"))
        self.src_dir = self.test_dir / "src"
        self.out_dir = self.test_dir / "out"
        self.src_dir.mkdir()
        self.out_dir.mkdir()

        if HAS_PIL:
            from PIL import Image
            for i in range(1, 3):
                im = Image.new("RGB", (60, 60), color=(50 * i, 100, 150))
                im.save(self.src_dir / f"img_{i:02d}.jpg", "JPEG")

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_main_exporter_records_and_deduplicates(self):
        logs = []
        # 第一次导出
        exporter1 = get_exporter(
            exp_type="main",
            data={
                "startOrder": 101,
                "version": 1,
                "format": "webp" if HAS_PIL else "original",
                "excludeExported": False,
            },
            src_p=self.src_dir,
            out_p=self.out_dir,
            http_base="http://test.local",
            log_fn=lambda m, l="info": logs.append((l, m)),
        )
        res1 = exporter1.execute()
        self.assertTrue(res1.success)

        # 检查 .studio/ledger/exports.json 权威账本是否已生成
        ledger_file = self.src_dir / ".studio" / "ledger" / "exports.json"
        self.assertTrue(ledger_file.exists())
        hashes = get_exported_hashes(self.src_dir)
        self.assertEqual(len(hashes), 2)

        # 第二次导出：开启 excludeExported=True
        # 由于所有图片都已导出，应抛出无新图片异常
        exporter2 = get_exporter(
            exp_type="main",
            data={
                "startOrder": 103,
                "version": 2,
                "format": "webp" if HAS_PIL else "original",
                "excludeExported": True,
            },
            src_p=self.src_dir,
            out_p=self.out_dir,
            http_base="http://test.local",
            log_fn=lambda m, l="info": logs.append((l, m)),
        )
        with self.assertRaises(ValueError) as ctx:
            exporter2.execute()
        self.assertIn("已在历史", str(ctx.exception))


class TestScannerProgressAndStats(unittest.TestCase):
    """测试扫描进度指示与统计回调"""

    def setUp(self):
        self.test_dir = Path(tempfile.mkdtemp(prefix="jigsaw_progress_test_"))
        self.images = []
        for i in range(5):
            p = self.test_dir / f"img_{i}.jpg"
            p.write_bytes(f"image_data_sample_{i}".encode("utf-8"))
            self.images.append(p)

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_progress_callback_and_stats(self):
        progress_events = []

        def on_progress(completed: int, total: int, hits: int, new_h: int) -> None:
            progress_events.append((completed, total, hits, new_h))

        stats = {}
        infos = scan_image_infos(
            self.images,
            self.test_dir,
            progress_callback=on_progress,
            stats_out=stats,
        )

        self.assertEqual(len(infos), 5)
        self.assertEqual(stats.get("total"), 5)
        self.assertEqual(stats.get("new_hashes"), 5)
        self.assertEqual(stats.get("cache_hits"), 0)
        self.assertEqual(len(progress_events), 5)
        self.assertEqual(progress_events[-1], (5, 5, 0, 5))

        # 第二次扫描传入缓存，测试命中
        hash_cache = {
            r["path"]: (r["mtime"], r["size"], r["hash"])
            for r in infos.values()
        }
        stats2 = {}
        progress_events2 = []
        infos2 = scan_image_infos(
            self.images,
            self.test_dir,
            hash_cache=hash_cache,
            progress_callback=lambda c, t, h, n: progress_events2.append((c, t, h, n)),
            stats_out=stats2,
        )
        self.assertEqual(stats2.get("total"), 5)
        self.assertEqual(stats2.get("cache_hits"), 5)
        self.assertEqual(stats2.get("new_hashes"), 0)
        self.assertEqual(progress_events2[-1], (5, 5, 5, 0))


class TestServerLogging(unittest.TestCase):
    """测试服务端日志系统与 CLI 参数"""

    def setUp(self):
        self.test_dir = Path(tempfile.mkdtemp(prefix="jigsaw_log_test_"))
        self.log_file = self.test_dir / "test_studio.log"

    def tearDown(self):
        # 关闭所有属于 test_studio.log 的 FileHandler 句柄，防止 Windows 文件锁定
        for h in list(logger.handlers):
            if isinstance(h, logging.FileHandler):
                h.close()
                logger.removeHandler(h)
        shutil.rmtree(self.test_dir, ignore_errors=True)
        # 恢复默认 logger
        setup_logger("INFO", DEFAULT_LOG_FILE)

    def test_setup_logger_file_and_levels(self):
        log = setup_logger(level_name="DEBUG", logfile=self.log_file)
        self.assertTrue(self.log_file.exists())

        log.debug("DEBUG 调试消息测试")
        log.info("INFO 正常消息测试")
        log.warning("WARNING 警告消息测试")

        # 刷新 handlers
        for h in log.handlers:
            h.flush()

        content = self.log_file.read_text(encoding="utf-8")
        self.assertIn("DEBUG 调试消息测试", content)
        self.assertIn("INFO 正常消息测试", content)
        self.assertIn("WARNING 警告消息测试", content)

    def test_cli_argument_parser(self):
        import argparse
        parser = argparse.ArgumentParser()
        parser.add_argument("--loglevel", default="INFO")
        parser.add_argument("--debug", action="store_true")
        parser.add_argument("--logfile", default=str(DEFAULT_LOG_FILE))

        args = parser.parse_args(["--debug", "--logfile", str(self.log_file)])
        level = "DEBUG" if args.debug else args.loglevel.upper()
        self.assertEqual(level, "DEBUG")
        self.assertEqual(Path(args.logfile), self.log_file)

    def test_studio_server_prevents_port_reuse(self):
        from studio.server import StudioRequestHandler, StudioServer

        # 绑定空闲动态端口
        s1 = StudioServer(("127.0.0.1", 0), StudioRequestHandler)
        port = s1.server_address[1]
        try:
            with self.assertRaises(OSError) as ctx:
                StudioServer(("127.0.0.1", port), StudioRequestHandler)
            winerr = getattr(ctx.exception, "winerror", None)
            self.assertTrue(winerr == 10048 or ctx.exception.errno in (98, 48, 10048))
        finally:
            s1.server_close()


class TestCacheDBAndQuality(unittest.TestCase):
    """测试 SQLite3 算力缓存引擎与 OpenCV 图像质检集成"""

    def setUp(self):
        self.test_dir = Path(tempfile.mkdtemp(prefix="studio_cache_test_"))
        # 生成两个简单的测试图片
        if HAS_PIL:
            from PIL import Image
            # 丰富纹理图片
            im1 = Image.new("RGB", (200, 200), color=(120, 150, 200))
            for i in range(200):
                im1.putpixel((i, i), (255, 0, 0))
                im1.putpixel((i, 199 - i), (0, 255, 0))
            im1.save(self.test_dir / "img1.jpg")

            # 纯色死区图片
            im2 = Image.new("RGB", (200, 200), color=(255, 255, 255))
            im2.save(self.test_dir / "img2.png")

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_cache_db_lifecycle(self):
        from studio.core.cache_db import CacheDB

        with CacheDB(self.test_dir) as db:
            # 1. 批量插入文件缓存
            items = [
                {
                    "path": "img1.jpg",
                    "mtime": 1000,
                    "size": 500,
                    "hash": "hash111",
                    "width": 200,
                    "height": 200,
                    "format": "JPEG",
                },
                {
                    "path": "sub/img2.png",
                    "mtime": 2000,
                    "size": 800,
                    "hash": "hash222",
                    "width": 300,
                    "height": 200,
                    "format": "PNG",
                },
            ]
            inserted = db.upsert_files(items)
            self.assertEqual(inserted, 2)

            # 2. 读取缓存
            cached = db.load_file_cache()
            self.assertIn("img1.jpg", cached)
            self.assertIn("sub/img2.png", cached)
            self.assertEqual(cached["img1.jpg"][2], "hash111")
            self.assertEqual(cached["img1.jpg"][3], 200)

            # 3. 未评分查询
            unscored = db.get_unscored_items(limit=10)
            self.assertEqual(len(unscored), 2)

            # 4. 保存质检结果
            q_res = {
                "score": 85,
                "grade": "S",
                "status": "PASS",
                "dead_zone_ratio": 0.01,
                "crop_suggestion": "无需裁切",
                "can_upgrade": False,
                "max_grid": "225 块",
            }
            db.save_quality("hash111", q_res)
            fetched = db.get_quality("hash111")
            self.assertIsNotNone(fetched)
            self.assertEqual(fetched["score"], 85)
            self.assertEqual(fetched["grade"], "S")

            # 5. 再次查询未评分，只剩 1 个
            unscored_after = db.get_unscored_items(limit=10)
            self.assertEqual(len(unscored_after), 1)
            self.assertEqual(unscored_after[0][1], "hash222")

            # 6. 统计信息
            stats = db.get_stats()
            self.assertEqual(stats["total_files"], 2)
            self.assertEqual(stats["total_scored"], 1)
            self.assertEqual(stats["unscored"], 1)

            # 7. 清理失效路径
            pruned = db.prune_missing_files(["img1.jpg"])
            self.assertEqual(pruned, 1)
            cached_after = db.load_file_cache()
            self.assertNotIn("sub/img2.png", cached_after)
            self.assertIn("img1.jpg", cached_after)

    def test_quality_evaluator(self):
        from studio.core.quality_evaluator import evaluate_image

        p1 = self.test_dir / "img1.jpg"
        if p1.exists():
            res = evaluate_image(p1)
            self.assertIn("score", res)
            self.assertIn("grade", res)
            self.assertIn("status", res)
            self.assertIn("dead_zone_ratio", res)
            self.assertIn("crop_suggestion", res)

    def test_server_quality_endpoints(self):
        from studio.server import StudioRequestHandler, StudioServer
        import threading
        import time
        import urllib.parse
        import urllib.request

        server = StudioServer(("127.0.0.1", 0), StudioRequestHandler)
        port = server.server_address[1]
        t = threading.Thread(target=server.serve_forever, daemon=True)
        t.start()
        time.sleep(0.1)

        try:
            # 1. 扫描目录测试，应返回 qualitySummary
            scan_url = f"http://127.0.0.1:{port}/api/scan?dir={urllib.parse.quote(str(self.test_dir))}"
            with urllib.request.urlopen(scan_url) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                self.assertTrue(data["ok"])
                self.assertIn("qualitySummary", data["stats"])
                records = data["records"]
                self.assertGreaterEqual(len(records), 1)

            # 2. 单张质检 API
            q_url = f"http://127.0.0.1:{port}/api/quality?path=img1.jpg&dir={urllib.parse.quote(str(self.test_dir))}"
            with urllib.request.urlopen(q_url) as resp:
                q_data = json.loads(resp.read().decode("utf-8"))
                self.assertTrue(q_data["ok"])
                self.assertIn("quality", q_data)
                self.assertIn("score", q_data["quality"])

            # 3. 统计 API
            stats_url = f"http://127.0.0.1:{port}/api/quality/stats?dir={urllib.parse.quote(str(self.test_dir))}"
            with urllib.request.urlopen(stats_url) as resp:
                s_data = json.loads(resp.read().decode("utf-8"))
                self.assertTrue(s_data["ok"])
                self.assertIn("total_files", s_data["stats"])

            # 4. 批量质检 API
            batch_url = f"http://127.0.0.1:{port}/api/quality/batch"
            post_body = json.dumps({"dir": str(self.test_dir), "limit": 10}).encode("utf-8")
            req = urllib.request.Request(
                batch_url,
                data=post_body,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req) as resp:
                b_data = json.loads(resp.read().decode("utf-8"))
                self.assertTrue(b_data["ok"])
                self.assertIn("count", b_data)
                self.assertIn("items", b_data)

        finally:
            server.shutdown()
            server.server_close()


class TestDuplicateHandling(unittest.TestCase):
    """测试重复文件检测、标签继承与导出器批次防重"""

    def setUp(self):
        self.test_dir = Path(tempfile.mkdtemp(prefix="studio_dup_test_"))
        self.src_dir = self.test_dir / "src"
        self.out_dir = self.test_dir / "out"
        self.src_dir.mkdir(parents=True)
        self.out_dir.mkdir(parents=True)

        p_cat = self.src_dir / "Animals" / "cat.jpg"
        p_cat.parent.mkdir(parents=True, exist_ok=True)
        p_cat_copy = self.src_dir / "Temp" / "cat_copy.jpg"
        p_cat_copy.parent.mkdir(parents=True, exist_ok=True)
        p_tree = self.src_dir / "Nature" / "tree.jpg"
        p_tree.parent.mkdir(parents=True, exist_ok=True)

        if HAS_PIL:
            from PIL import Image
            im1 = Image.new("RGB", (100, 100), color=(255, 0, 0))
            im1.save(p_cat, format="JPEG")
            # 制作完全相同的副本文件
            im1.save(p_cat_copy, format="JPEG")
            im2 = Image.new("RGB", (100, 100), color=(0, 255, 0))
            im2.save(p_tree, format="JPEG")
        else:
            p_cat.write_bytes(b"image_content_1")
            p_cat_copy.write_bytes(b"image_content_1")
            p_tree.write_bytes(b"image_content_2")

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_find_duplicate_groups(self):
        images = scan_images(self.src_dir)
        self.assertEqual(len(images), 3)
        infos = scan_image_infos(images, self.src_dir)
        dup_groups = find_duplicate_groups(infos)
        self.assertEqual(len(dup_groups), 1)
        dup_items = list(dup_groups.values())[0]
        self.assertEqual(len(dup_items), 2)
        paths = {it["path"] for it in dup_items}
        self.assertIn("Animals/cat.jpg", paths)
        self.assertIn("Temp/cat_copy.jpg", paths)

    def test_duplicate_tag_inheritance(self):
        images = scan_images(self.src_dir)
        infos = scan_image_infos(images, self.src_dir)
        cat_hash = infos["Animals/cat.jpg"]["hash"]
        existing = [{
            "path": "Animals/cat.jpg",
            "file": "cat.jpg",
            "tags": ["Pets"],
            "catalogs": ["Pets"],
            "confidence": 1.0,
            "hash": cat_hash,
            "review_required": False,
        }]
        records, stats = merge_scanned_images(images, self.src_dir, existing, image_infos=infos)
        self.assertEqual(len(records), 3)

        rec_map = {r["path"]: r for r in records}
        copy_rec = rec_map["Temp/cat_copy.jpg"]
        # Temp/cat_copy.jpg 必须自动继承 cat.jpg 的真实标签 Pets，而不是被推断为 Others！
        self.assertEqual(copy_rec["tags"], ["Pets"])
        self.assertEqual(copy_rec["catalogs"], ["Pets"])
        self.assertIn("自动继承", copy_rec["reason"])

    def test_exporter_rejects_duplicate_images(self):
        # 待导出列表中存在重复图片时，严禁导出并报错拦截（避免每日挑战少天数或主线关卡重复）
        logs = []
        exporter = get_exporter(
            exp_type="main",
            data={
                "startOrder": 101,
                "version": 1,
                "format": "original",
                "rename": "sequence",
                "excludeExported": False,
            },
            src_p=self.src_dir,
            out_p=self.out_dir,
            http_base="http://test.local/data",
            log_fn=lambda msg, level: logs.append((msg, level)),
        )
        with self.assertRaises(ValueError) as ctx:
            exporter.execute()
        self.assertIn("存在 1 组内容完全相同的重复图片", str(ctx.exception))
        # 日志中记录了中止错误
        err_logs = [m for m, l in logs if "导出已被安全中止" in m]
        self.assertEqual(len(err_logs), 1)

    def test_daily_exporter_rejects_duplicate_images(self):
        # Daily 导出包含重复图片时必须直接拦截，防止缺失日历天数
        logs = []
        exporter = get_exporter(
            exp_type="daily",
            data={
                "month": "202609",
                "format": "original",
                "rename": "sequence",
                "excludeExported": False,
            },
            src_p=self.src_dir,
            out_p=self.out_dir,
            http_base="http://test.local/data",
            log_fn=lambda msg, level: logs.append((msg, level)),
        )
        with self.assertRaises(ValueError) as ctx:
            exporter.execute()
        self.assertIn("存在 1 组内容完全相同的重复图片", str(ctx.exception))

    def test_exporter_selected_paths_without_duplicates(self):
        # 当用户显式指定 selectedPaths 且无重复图片时，导出应正常成功
        logs = []
        exporter = get_exporter(
            exp_type="main",
            data={
                "startOrder": 101,
                "version": 1,
                "format": "original",
                "rename": "sequence",
                "excludeExported": False,
                "selectedPaths": ["Animals/cat.jpg", "Nature/tree.jpg"],
            },
            src_p=self.src_dir,
            out_p=self.out_dir,
            http_base="http://test.local/data",
            log_fn=lambda msg, level: logs.append((msg, level)),
        )
        res = exporter.execute()
        batch_json = self.out_dir / "main" / "batches" / "batch_001.json"
        self.assertTrue(batch_json.exists())
        data = json.loads(batch_json.read_text(encoding="utf-8"))
        self.assertEqual(len(data["items"]), 2)

    def test_server_duplicate_scan_api(self):
        from studio.server import StudioRequestHandler, StudioServer
        import threading
        import time
        import urllib.parse
        import urllib.request

        server = StudioServer(("127.0.0.1", 0), StudioRequestHandler)
        port = server.server_address[1]
        t = threading.Thread(target=server.serve_forever, daemon=True)
        t.start()
        time.sleep(0.1)

        try:
            scan_url = f"http://127.0.0.1:{port}/api/scan?dir={urllib.parse.quote(str(self.src_dir))}"
            with urllib.request.urlopen(scan_url) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                self.assertTrue(data["ok"])
                stats = data["stats"]
                self.assertEqual(stats["duplicateGroups"], 1)
                self.assertEqual(stats["duplicateCount"], 2)
                records = data["records"]
                dup_recs = [r for r in records if r.get("is_duplicate")]
                self.assertEqual(len(dup_recs), 2)
        finally:
            server.shutdown()
            server.server_close()


class TestExportJobStore(unittest.TestCase):
    """导出进度观测通道：JobStore 内存状态表单元测试"""

    def setUp(self):
        from studio import server as srv
        self.srv = srv
        with srv._JOB_LOCK:
            srv._JOBS.clear()

    def test_register_snapshot_is_copy(self):
        s = self.srv
        s._job_register("job_a")
        s._job_append_log("job_a", {"t": "00:00:01", "level": "info", "msg": "start"})
        s._job_append_log("job_a", {"t": "00:00:02", "level": "info", "msg": "scan ok"})
        s._job_progress("job_a", 3, 8)
        snap = s._job_snapshot("job_a")
        self.assertEqual(snap["state"], "running")
        self.assertEqual(snap["done"], 3)
        self.assertEqual(snap["total"], 8)
        self.assertEqual([x["msg"] for x in snap["logs"]], ["start", "scan ok"])

        # 快照必须为拷贝：外部修改不污染内部状态
        snap["logs"].append({"t": "x", "level": "err", "msg": "mutate"})
        snap["done"] = 99
        snap2 = s._job_snapshot("job_a")
        self.assertEqual(len(snap2["logs"]), 2)
        self.assertEqual(snap2["done"], 3)

    def test_log_frozen_after_terminal_and_error_state(self):
        s = self.srv
        s._job_register("job_b")
        s._job_append_log("job_b", {"t": "t", "level": "info", "msg": "m1"})
        s._job_finish("job_b", summary="已成功导出 8 个关卡")
        self.assertEqual(s._job_snapshot("job_b")["state"], "done")
        # 终态后不再追加日志
        s._job_append_log("job_b", {"t": "t", "level": "err", "msg": "late"})
        self.assertEqual(len(s._job_snapshot("job_b")["logs"]), 1)

        s._job_register("job_c")
        s._job_finish("job_c", error="boom")
        snap = s._job_snapshot("job_c")
        self.assertEqual(snap["state"], "error")
        self.assertEqual(snap["error"], "boom")

    def test_unknown_and_empty_task(self):
        s = self.srv
        self.assertIsNone(s._job_snapshot("no_such_task"))
        # 空 task id 一律空操作，不产生记录
        s._job_register("")
        s._job_append_log("", {"t": "t", "level": "info", "msg": "x"})
        s._job_finish("", summary="x")
        self.assertEqual(len(s._JOBS), 0)

    def test_cleanup_bounds(self):
        import time
        s = self.srv
        # 塞入超过上限的过期终态任务
        for i in range(60):
            s._JOBS[f"stale_{i}"] = {
                "state": "done", "logs": [], "done": 0, "total": 0,
                "summary": "", "error": None,
                "created_at": time.time() - 99999,
            }
        s._job_register("fresh_one")
        self.assertLessEqual(len(s._JOBS), s._JOB_MAX_KEEP)
        self.assertIn("fresh_one", s._JOBS)


class TestExportStatusEndpoint(unittest.TestCase):
    """导出进度观测通道：GET /api/export/status 真实起服端到端测试"""

    def test_status_endpoint_live_progress(self):
        from studio import server as srv
        from studio.server import StudioRequestHandler, StudioServer
        import threading
        import time
        import urllib.parse
        import urllib.request

        with srv._JOB_LOCK:
            srv._JOBS.clear()

        server = StudioServer(("127.0.0.1", 0), StudioRequestHandler)
        port = server.server_address[1]
        t = threading.Thread(target=server.serve_forever, daemon=True)
        t.start()
        time.sleep(0.1)
        try:
            task = "endpoint_live_1"
            srv._job_register(task)
            srv._job_append_log(task, {"t": "00:00:01", "level": "info", "msg": "收到导出请求"})
            srv._job_append_log(task, {"t": "00:00:02", "level": "info", "msg": "开始转码"})
            srv._job_progress(task, 5, 16)

            url = f"http://127.0.0.1:{port}/api/export/status?task={urllib.parse.quote(task)}"
            with urllib.request.urlopen(url) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            self.assertTrue(data["found"])
            self.assertEqual(data["state"], "running")
            self.assertEqual(data["done"], 5)
            self.assertEqual(data["total"], 16)
            self.assertEqual(len(data["logs"]), 2)
            self.assertEqual(data["logs"][-1]["msg"], "开始转码")

            # 完成后再查：done + summary
            srv._job_finish(task, summary="已成功导出 16 个关卡")
            with urllib.request.urlopen(url) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            self.assertEqual(data["state"], "done")
            self.assertEqual(data["summary"], "已成功导出 16 个关卡")

            # 未知任务 → found=false (HTTP 200，前端据此静默停止轮询)
            with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/api/export/status?task=no_such"
            ) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            self.assertFalse(data["found"])
            self.assertFalse(data["ok"])
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()


