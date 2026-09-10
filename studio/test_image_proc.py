#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.test_image_proc — 导出规格化单元测试

覆盖：比例族展开 / resize_long / normalize_export_image（强制比例、auto 池、阻断）/
image_long_side / 扫描器 too_small_long 告警。

长边目标常量：DEFAULT_LONG_TARGET = 1920（见 studio.core.image_proc）。
"""

import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image, ImageDraw

_pkg_dir = Path(__file__).resolve().parent
_root_dir = _pkg_dir.parent
if str(_root_dir) not in sys.path:
    sys.path.insert(0, str(_root_dir))

from PIL import Image

from studio.core.crop_compute import (
    build_ratio_pool,
    expand_ratio_families,
    resize_long,
)
from studio.core.image_proc import (
    DEFAULT_LONG_TARGET,
    HAS_CROP_COMPUTE,
    image_long_side,
    normalize_export_image,
)
from studio.core.scanner import get_image_info


class TestRatioFamilies(unittest.TestCase):
    def test_auto_excludes_2x3(self):
        pool = build_ratio_pool(expand_ratio_families(["auto"]))
        labels = {label for _, label in pool}
        # auto 池 = {1:1, 3:4, 4:3}，绝不含 2:3/3:2
        self.assertEqual(labels, {"1:1", "3:4", "4:3"})

    def test_manual_2x3_additive(self):
        pool = build_ratio_pool(expand_ratio_families(["auto", "2:3"]))
        labels = {label for _, label in pool}
        self.assertEqual(labels, {"1:1", "3:4", "4:3", "2:3", "3:2"})

    def test_explicit_4x3_only(self):
        pool = build_ratio_pool(expand_ratio_families(["4:3"]))
        labels = {label for _, label in pool}
        self.assertEqual(labels, {"3:4", "4:3"})


class TestResizeLong(unittest.TestCase):
    def test_downscale_only(self):
        img = Image.new("RGB", (3200, 1800))
        out = resize_long(img, DEFAULT_LONG_TARGET)
        self.assertEqual(max(out.size), DEFAULT_LONG_TARGET)
        self.assertAlmostEqual(out.size[0] / out.size[1], 3200 / 1800, delta=0.01)

    def test_no_upscale_when_at_or_under(self):
        img = Image.new("RGB", (1800, 1500))
        out = resize_long(img, DEFAULT_LONG_TARGET)
        self.assertEqual(out.size, (1800, 1500))


class TestNormalizeExport(unittest.TestCase):
    @unittest.skipUnless(HAS_CROP_COMPUTE, "需要 numpy")
    def test_forced_2x3_landscape_mirrors_to_3x2(self):
        # 2400x1600 横图（ratio 1.5），强制 2:3 族 -> 应输出 3:2（镜像自适应）、长边=1920
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "a.png"
            Image.new("RGB", (2400, 1600), (200, 60, 60)).save(src)
            dst = Path(td) / "a.webp"
            ok, err, meta = normalize_export_image(
                src, dst, fmt="webp", target_ratios=("2:3",),
                crop_mode="center", trim_background=False,
            )
            self.assertTrue(ok, err)
            self.assertEqual(meta["ratio"], "3:2")
            self.assertEqual(meta["out_size"], [DEFAULT_LONG_TARGET, 1280])

    @unittest.skipUnless(HAS_CROP_COMPUTE, "需要 numpy")
    def test_auto_pool_picks_4x3(self):
        # 3000x2160（ratio 1.389）auto 池只会选 4:3（1.333），不会落到 2:3/3:2
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "b.png"
            Image.new("RGB", (3000, 2160), (60, 160, 60)).save(src)
            dst = Path(td) / "b.webp"
            ok, err, meta = normalize_export_image(
                src, dst, fmt="webp", target_ratios=("auto",),
                crop_mode="smart", trim_background=False,
            )
            self.assertTrue(ok, err)
            self.assertEqual(meta["ratio"], "4:3")
            self.assertEqual(meta["out_size"], [DEFAULT_LONG_TARGET, 1440])

    @unittest.skipUnless(HAS_CROP_COMPUTE, "需要 numpy")
    def test_long_edge_block(self):
        # 长边 1200 < 1920 -> 阻断
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "c.png"
            Image.new("RGB", (1200, 800), (60, 60, 200)).save(src)
            dst = Path(td) / "c.webp"
            ok, err, _ = normalize_export_image(src, dst, fmt="webp")
            self.assertFalse(ok)
            self.assertIn("长边不足", err)
            self.assertFalse(dst.exists())

    @unittest.skipUnless(HAS_CROP_COMPUTE, "需要 numpy")
    def test_crop_mode_none_only_scales(self):
        # 不裁切：仅长边缩放，比例保持原样（此处 2400x2400 方图 -> 1:1，长边 1920）
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "d.png"
            Image.new("RGB", (2400, 2400), (90, 90, 200)).save(src)
            dst = Path(td) / "d.png"
            ok, err, meta = normalize_export_image(
                src, dst, fmt="png", target_ratios=("auto",),
                crop_mode="none", trim_background=False,
            )
            self.assertTrue(ok, err)
            self.assertEqual(meta["out_size"], [DEFAULT_LONG_TARGET, DEFAULT_LONG_TARGET])
            self.assertEqual(meta["mode"], "none")


class TestMakeCoverImage(unittest.TestCase):
    """封面生成：限幅裁切 + 长边 1080（正常图不裁、异形图裁到限幅边界）。"""

    COVER_LONG = 1080
    CLAMP = 2.0

    @staticmethod
    def _save_src(td: str, name: str, size: tuple[int, int]) -> Path:
        # 纯色边框(5%) + 内部棋盘主体：compute_content_box 会裁掉均匀边框、
        # 保留棋盘区域，内容框比例≈源图比例（可预测且鲁棒）。
        p = Path(td) / name
        p.parent.mkdir(parents=True, exist_ok=True)
        w, h = size
        im = Image.new("RGB", size, (245, 245, 240))
        dr = ImageDraw.Draw(im)
        bx, by = int(w * 0.05), int(h * 0.05)
        cell = max(16, min(w, h) // 40)
        for yy in range(by, h - by, cell):
            for xx in range(bx, w - bx, cell):
                if (xx // cell + yy // cell) % 2 == 0:
                    dr.rectangle([xx, yy, xx + cell, yy + cell], fill=(60, 60, 70))
        im.save(p)
        return p

    @unittest.skipUnless(HAS_CROP_COMPUTE, "需要 numpy")
    def test_normal_image_no_crop(self):
        # 正常比例（4:3）-> 不裁切，输出长边 1080，比例≈内容框比例（棋盘主体）
        with tempfile.TemporaryDirectory() as td:
            src = self._save_src(td, "a.png", (4000, 3000))
            dst = Path(td) / "a.webp"
            from studio.core.image_proc import make_cover_image
            ok, err, meta = make_cover_image(src, dst, quality=70)
            self.assertTrue(ok, err)
            self.assertEqual(meta["crop_mode"], "keep")
            ow, oh = meta["out_size"]
            self.assertEqual(max(ow, oh), self.COVER_LONG)
            # 内容框比例 1.32 -> 输出比例一致（不裁）
            self.assertAlmostEqual(ow / oh, 1.32, delta=0.1)

    @unittest.skipUnless(HAS_CROP_COMPUTE, "需要 numpy")
    def test_ultra_wide_clamped(self):
        # 超宽 -> 裁到 2:1，输出长边 1080，输出比例=2.0
        with tempfile.TemporaryDirectory() as td:
            src = self._save_src(td, "b.png", (6000, 1200))
            dst = Path(td) / "b.webp"
            from studio.core.image_proc import make_cover_image
            ok, err, meta = make_cover_image(src, dst, quality=70)
            self.assertTrue(ok, err)
            self.assertEqual(meta["crop_mode"], "clamp_2:1")
            ow, oh = meta["out_size"]
            self.assertEqual(max(ow, oh), self.COVER_LONG)
            self.assertAlmostEqual(ow / oh, 2.0, delta=0.05)

    @unittest.skipUnless(HAS_CROP_COMPUTE, "需要 numpy")
    def test_ultra_tall_clamped(self):
        # 超高 -> 裁到 1:2，输出长边 1080，输出比例=0.5
        with tempfile.TemporaryDirectory() as td:
            src = self._save_src(td, "c.png", (1000, 6000))
            dst = Path(td) / "c.webp"
            from studio.core.image_proc import make_cover_image
            ok, err, meta = make_cover_image(src, dst, quality=70)
            self.assertTrue(ok, err)
            self.assertEqual(meta["crop_mode"], "clamp_1:2")
            ow, oh = meta["out_size"]
            self.assertEqual(max(ow, oh), self.COVER_LONG)
            self.assertAlmostEqual(ow / oh, 0.5, delta=0.05)

    def test_degraded_without_crop_compute(self):
        # HAS_CROP_COMPUTE=False 时降级为纯转码，不抛异常
        if HAS_CROP_COMPUTE:
            self.skipTest("仅在裁切算法缺失环境验证降级路径")
        with tempfile.TemporaryDirectory() as td:
            src = self._save_src(td, "d.png", (2000, 2000))
            dst = Path(td) / "d.webp"
            from studio.core.image_proc import make_cover_image
            ok, err, meta = make_cover_image(src, dst, quality=70)
            self.assertTrue(ok, err)
            self.assertEqual(meta["crop_mode"], "degraded_convert_only")


class TestScanWarn(unittest.TestCase):
    def test_too_small_long_flag(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            # 长边 1200 < 1920
            small = root / "small.png"
            Image.new("RGB", (1200, 800)).save(small)
            info = get_image_info(small, root)
            self.assertTrue(info["too_small_long"])
            self.assertEqual(info["long_side"], 1200)
            # 长边 3000 >= 1920
            big = root / "big.png"
            Image.new("RGB", (3000, 2160)).save(big)
            info2 = get_image_info(big, root)
            self.assertFalse(info2["too_small_long"])
            self.assertEqual(info2["long_side"], 3000)

    def test_image_long_side(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "x.png"
            Image.new("RGB", (100, 300)).save(p)
            self.assertEqual(image_long_side(p), 300)
            self.assertEqual(DEFAULT_LONG_TARGET, 1920)


if __name__ == "__main__":
    unittest.main()