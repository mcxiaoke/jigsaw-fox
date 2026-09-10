#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.test_log_routing — 运行日志按源库分流 (studio.core.log_routing) 测试

覆盖：库日志落点与命名、[src=库名] 前缀、无上下文丢弃、级别门控、
目录不存在/不可写时的 fail-safe 降级、上下文清理、setup_logger 接线。
"""

from __future__ import annotations

import datetime as dt
import logging
import shutil
import tempfile
import unittest
from pathlib import Path

from studio.core.log_routing import (
    LOG_DIR_NAME,
    LOG_FILE_PREFIX,
    LibraryRoutingHandler,
    SrcAwareFormatter,
    SrcContextFilter,
    bind_src,
    current_src,
    src_label,
)

TEST_LOGGER_NAME = "studio_test_log_routing"
FMT = "[%(levelname)s] %(src_tag)s%(message)s"


class LogRoutingTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="studio_logrouting_"))
        self.src = self.tmp / "MyLibrary"
        self.src.mkdir()
        bind_src("")

        self.logger = logging.getLogger(TEST_LOGGER_NAME)
        self.logger.setLevel(logging.DEBUG)
        self.logger.propagate = False
        for h in list(self.logger.handlers):
            self.logger.removeHandler(h)
        self.handler = LibraryRoutingHandler(logging.DEBUG)
        self.handler.setFormatter(SrcAwareFormatter(FMT))
        self.handler.addFilter(SrcContextFilter())
        self.logger.addHandler(self.handler)

    def tearDown(self) -> None:
        for h in list(self.logger.handlers):
            h.close()
            self.logger.removeHandler(h)
        bind_src("")
        shutil.rmtree(self.tmp, ignore_errors=True)

    def lib_log_path(self, src: Path | None = None) -> Path:
        stamp = dt.date.today().strftime("%Y%m%d")
        base = src if src is not None else self.src
        return base / LOG_DIR_NAME / f"{LOG_FILE_PREFIX}{stamp}.log"

    def read_lib_log(self, src: Path | None = None) -> str:
        p = self.lib_log_path(src)
        return p.read_text(encoding="utf-8") if p.exists() else ""

    # -- 基础：落点与命名 ------------------------------------------------
    def test_writes_to_src_dot_logs_dir(self) -> None:
        bind_src(self.src)
        self.logger.info("扫描完成")
        self.handler.flush()

        self.assertTrue(
            self.lib_log_path().exists(), f"应写入 {self.lib_log_path()}"
        )
        self.assertIn("扫描完成", self.read_lib_log())
        self.assertEqual(self.lib_log_path().parent.name, ".logs")

    def test_log_file_is_append_only(self) -> None:
        bind_src(self.src)
        self.logger.info("第一条")
        self.logger.info("第二条")
        self.handler.flush()
        content = self.read_lib_log()
        self.assertIn("第一条", content)
        self.assertIn("第二条", content)
        self.assertLess(content.index("第一条"), content.index("第二条"))

    def test_prefix_uses_library_dir_name(self) -> None:
        bind_src(self.src)
        self.logger.warning("拒绝删除已导出素材")
        self.handler.flush()
        self.assertIn("[src=MyLibrary]", self.read_lib_log())

    def test_subpath_library_name_uses_last_segment(self) -> None:
        nested = self.tmp / "A" / "B" / "NestedLib"
        nested.mkdir(parents=True)
        bind_src(nested)
        self.logger.info("x")
        self.handler.flush()
        self.assertIn("[src=NestedLib]", self.read_lib_log(nested))

    # -- 无上下文：丢弃，不能把服务日志写进素材库 -------------------------
    def test_no_context_writes_nothing(self) -> None:
        self.logger.info("服务自身日志")
        self.handler.flush()
        self.assertFalse(
            self.lib_log_path().exists(), "无库上下文时不得创建源库日志目录"
        )

    def test_clearing_context_stops_routing(self) -> None:
        bind_src(self.src)
        self.logger.info("库日志")
        bind_src("")
        self.logger.info("清空后的日志")
        self.handler.flush()
        content = self.read_lib_log()
        self.assertIn("库日志", content)
        self.assertNotIn("清空后的日志", content)

    # -- 级别门控 --------------------------------------------------------
    def test_debug_level_writes_debug(self) -> None:
        bind_src(self.src)
        self.logger.debug("DEBUG 细节")
        self.handler.flush()
        self.assertIn("DEBUG 细节", self.read_lib_log())

    def test_info_level_drops_debug(self) -> None:
        self.handler.setLevel(logging.INFO)
        bind_src(self.src)
        self.logger.debug("DEBUG 细节")
        self.logger.info("INFO 摘要")
        self.handler.flush()
        content = self.read_lib_log()
        self.assertIn("INFO 摘要", content)
        self.assertNotIn("DEBUG 细节", content)

    # -- fail-safe 降级 --------------------------------------------------
    def test_missing_source_dir_is_skipped(self) -> None:
        missing = self.tmp / "not_exists"
        bind_src(missing)
        self.logger.info("不该落盘")  # 不应抛异常
        self.handler.flush()
        self.assertFalse(self.lib_log_path(missing).exists())

    def test_source_path_pointing_to_file_is_skipped(self) -> None:
        a_file = self.tmp / "a_file.txt"
        a_file.write_text("x", encoding="utf-8")
        bind_src(a_file)
        self.logger.info("不该落盘")  # 不应抛异常
        self.handler.flush()
        self.assertFalse((a_file / LOG_DIR_NAME).exists())

    def test_unwritable_target_does_not_raise(self) -> None:
        """把 .logs 占位成同名文件，逼出写入异常，handler 必须吞掉。"""
        blocker = self.src / LOG_DIR_NAME
        blocker.write_text("blocked", encoding="utf-8")
        bind_src(self.src)
        self.logger.info("写入应失败但不抛异常")
        self.handler.flush()
        self.assertTrue(blocker.is_file())
        self.assertEqual(blocker.read_text(encoding="utf-8"), "blocked")

    def test_resolve_log_path_returns_none_without_context(self) -> None:
        self.assertIsNone(self.handler.resolve_log_path())

    # -- 辅助函数与接线 --------------------------------------------------
    def test_src_label(self) -> None:
        self.assertEqual(src_label(Path("/x/y/Zeta")), "Zeta")
        self.assertEqual(src_label(""), "")
        self.assertEqual(src_label(None), "")

    def test_current_src_roundtrip(self) -> None:
        bind_src(self.src)
        self.assertEqual(current_src(), str(self.src.resolve()))
        bind_src("")
        self.assertEqual(current_src(), "")

    def test_setup_logger_registers_library_routing_handler(self) -> None:
        from studio.server import DEFAULT_LOG_FILE, logger, setup_logger

        log_file = self.tmp / "server.log"
        try:
            setup_logger("INFO", log_file)
            kinds = [type(h).__name__ for h in logger.handlers]
            self.assertIn("LibraryRoutingHandler", kinds)
            self.assertIn("FileHandler", kinds)
        finally:
            for h in list(logger.handlers):
                h.close()
                logger.removeHandler(h)
            setup_logger("INFO", DEFAULT_LOG_FILE)

    def test_setup_logger_logfile_off_disables_all_file_output(self) -> None:
        from studio.server import DEFAULT_LOG_FILE, logger, setup_logger

        try:
            setup_logger("INFO", None)
            file_like = [
                type(h).__name__
                for h in logger.handlers
                if isinstance(h, logging.FileHandler)
                or isinstance(h, LibraryRoutingHandler)
            ]
            self.assertEqual(file_like, [], "logfile=off 应关闭全部文件落点")
        finally:
            for h in list(logger.handlers):
                h.close()
                logger.removeHandler(h)
            setup_logger("INFO", DEFAULT_LOG_FILE)


if __name__ == "__main__":
    unittest.main()
