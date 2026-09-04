#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.test_studio — Content Studio 核心功能与自动化回归测试套件
"""

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

_pkg_dir = Path(__file__).resolve().parent
_root_dir = _pkg_dir.parent
if str(_root_dir) not in sys.path:
    sys.path.insert(0, str(_root_dir))

from studio.core.image_proc import HAS_PIL, convert_image, generate_thumbnail_bytes, make_rename
from studio.core.scanner import find_tags_file, get_image_info, scan_images
from studio.core.tags_manager import merge_scanned_images, normalize_records, save_tags_file
from studio.exporters import get_exporter
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
        self.assertEqual(len(CATALOG_DEFS), 14)
        self.assertEqual(len(SPECIFIC_TAG_DEFS), 14)
        self.assertEqual(len(ALL_CANONICAL_TAGS), 14)
        self.assertIn("Pets", ALL_CANONICAL_TAGS)
        self.assertIn("Landscapes", ALL_CANONICAL_TAGS)
        self.assertIn("Colors", ALL_CANONICAL_TAGS)
        self.assertIn("Holidays", ALL_CANONICAL_TAGS)
        self.assertIn("Flowers", ALL_CANONICAL_TAGS)
        self.assertIn("Animals", ALL_CANONICAL_TAGS)

    def test_normalization(self):
        # 英文单复数与细分词识别归一化
        self.assertEqual(normalize_token("cat"), "Pets")
        self.assertEqual(normalize_token("Cats"), "Pets")
        self.assertEqual(normalize_token("ocean"), "Landscapes")
        self.assertEqual(normalize_token("Oceans"), "Landscapes")
        self.assertEqual(normalize_token("mandala"), "Colors")
        self.assertEqual(normalize_token("illustration"), "Art")
        self.assertEqual(normalize_token("holiday"), "Holidays")
        self.assertEqual(normalize_token("Christmas"), "Holidays")

        # 中文别名
        self.assertEqual(normalize_token("猫咪"), "Pets")
        self.assertEqual(normalize_token("雪山"), "Landscapes")
        self.assertEqual(normalize_token("复古"), "Cozy")
        self.assertEqual(normalize_token("甜点"), "Food")
        self.assertEqual(normalize_token("花卉"), "Flowers")

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

        # 合并扫描与智能推断
        records, stats = merge_scanned_images(images, self.src_dir, None)
        self.assertEqual(len(records), 3)
        self.assertEqual(records[0]["tags"], ["Pets"])
        self.assertEqual(records[0]["catalogs"], ["Pets"])
        self.assertFalse(records[0]["review_required"])

        # 保存 tags.json
        ok, dest_file, count = save_tags_file(self.src_dir, records)
        self.assertTrue(ok)
        self.assertEqual(count, 3)
        self.assertTrue(Path(dest_file).exists())

        # 重新读取归一化
        tag_file = find_tags_file(self.src_dir)
        self.assertIsNotNone(tag_file)
        loaded = json.loads(tag_file.read_text(encoding="utf-8"))
        norm_records, fmt_name = normalize_records(loaded, self.src_dir)
        self.assertEqual(fmt_name, "list")
        self.assertEqual(len(norm_records), 3)
        self.assertEqual(norm_records[0]["tags"], ["Pets"])

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
        main_json = self.out_dir / "main.json"
        self.assertTrue(main_json.exists())
        data = json.loads(main_json.read_text(encoding="utf-8"))
        self.assertEqual(data["version"], 5)
        self.assertEqual(len(data["levels"]), 3)
        self.assertEqual(data["levels"][0]["order"], 101)
        self.assertEqual(data["levels"][0]["tags"], ["Pets"])

        # 验证 manifest.json 纯路由清单
        manifest_json = self.out_dir / "manifest.json"
        self.assertTrue(manifest_json.exists())
        m_data = json.loads(manifest_json.read_text(encoding="utf-8"))
        self.assertIn("main", m_data["modules"])
        self.assertEqual(m_data["modules"]["main"]["version"], 5)
        self.assertEqual(m_data["modules"]["main"]["url"], "http://test.local/data/main.json")

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
        daily_zip = self.out_dir / "daily" / "202609.zip"
        self.assertTrue(daily_zip.exists())

        daily_json = self.out_dir / "daily.json"
        self.assertTrue(daily_json.exists())
        d_data = json.loads(daily_json.read_text(encoding="utf-8"))
        self.assertEqual(d_data["currentMonth"], "202609")
        self.assertEqual(len(d_data["months"]), 1)
        self.assertEqual(d_data["months"][0]["month"], "202609")

        manifest_json = self.out_dir / "manifest.json"
        self.assertTrue(manifest_json.exists())
        m_data = json.loads(manifest_json.read_text(encoding="utf-8"))
        self.assertIn("daily", m_data["modules"])

    def test_event_exporter(self):
        logs = []
        exporter = get_exporter(
            exp_type="event",
            data={
                "eventId": "test_event_2026",
                "title": "测试节日活动",
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
        event_zip = self.out_dir / "events" / "test_event_2026.zip"
        self.assertTrue(event_zip.exists())

        events_json = self.out_dir / "events" / "events.json"
        self.assertTrue(events_json.exists())
        ev_data = json.loads(events_json.read_text(encoding="utf-8"))
        self.assertEqual(len(ev_data), 1)
        self.assertEqual(ev_data[0]["id"], "test_event_2026")


if __name__ == "__main__":
    unittest.main()
