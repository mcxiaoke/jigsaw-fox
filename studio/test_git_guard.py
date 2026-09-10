#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.test_git_guard — .studio git 版本化守卫单元测试
覆盖：仓库幂等初始化 / ignore 生效性 / checkpoint / guard_export 拦截 /
模式配置容错 / 导出与回滚 commit 消息 / GitPython 缺失降级。
"""

import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

from studio.core import git_guard
from studio.core.git_guard import (
    commit_after_export,
    commit_after_rollback,
    ensure_repo,
    guard_export,
    is_dirty,
    is_managed,
    load_mode,
    checkpoint,
)


def _has_git() -> bool:
    """git CLI 必须可用，否则本套件全部 skip（守卫为降级 no-op，无从验证）。"""
    import subprocess

    try:
        subprocess.run(
            ["git", "--version"], capture_output=True, timeout=10, check=True
        )
        return True
    except Exception:
        return False


requires_git = unittest.skipUnless(_has_git(), "git CLI 不可用")


@requires_git
class TestGitGuard(unittest.TestCase):
    def setUp(self):
        self.test_dir = Path(tempfile.mkdtemp(prefix="studio_gg_test_"))
        self.studio_dir = self.test_dir / ".studio"
        self.studio_dir.mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    # ------------------------------------------------------------------
    # 仓库初始化
    # ------------------------------------------------------------------

    def test_ensure_repo_idempotent(self):
        self.assertTrue(ensure_repo(self.studio_dir))
        gitignore = (self.studio_dir / ".gitignore").read_text(encoding="utf-8")
        self.assertIn("cache/", gitignore)
        self.assertIn("release/", gitignore)
        # 二次调用不报错、不重建
        self.assertTrue(ensure_repo(self.studio_dir))
        self.assertTrue(is_managed(self.studio_dir))
        # 局部身份配置生效
        import subprocess

        proc = subprocess.run(
            ["git", "config", "user.name"],
            cwd=str(self.studio_dir),
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.stdout.strip(), "studio")

    def test_ensure_repo_creates_initial_commit(self):
        (self.studio_dir / "ledger").mkdir()
        (self.studio_dir / "ledger" / "exports.json").write_text(
            "[]", encoding="utf-8"
        )
        ensure_repo(self.studio_dir)
        log = self._git_log()
        self.assertEqual(log, ["chore: init studio git guard"])

    def test_gitignore_effective(self):
        ensure_repo(self.studio_dir)
        cache_dir = self.studio_dir / "cache"
        cache_dir.mkdir()
        (cache_dir / "studio.db").write_bytes(b"x" * 32)
        (cache_dir / "studio.db-wal").write_bytes(b"y" * 8)
        self.assertFalse(is_dirty(self.studio_dir), "cache/ 必须被 ignore")

    # ------------------------------------------------------------------
    # checkpoint
    # ------------------------------------------------------------------

    def test_checkpoint_on_dirty_and_skip_when_clean(self):
        ensure_repo(self.studio_dir)
        self.assertFalse(checkpoint(self.studio_dir, "noop"), "clean 不应产生 commit")
        (self.studio_dir / "tags.json").write_text("{}", encoding="utf-8")
        self.assertTrue(is_dirty(self.studio_dir))
        self.assertTrue(checkpoint(self.studio_dir, "checkpoint(pre-export): main (auto)"))
        self.assertFalse(is_dirty(self.studio_dir))
        self.assertEqual(
            self._git_log()[0], "checkpoint(pre-export): main (auto)"
        )

    # ------------------------------------------------------------------
    # guard_export
    # ------------------------------------------------------------------

    def test_guard_export_auto_resolves_dirty(self):
        ensure_repo(self.studio_dir)
        (self.studio_dir / "tags.json").write_text("{}", encoding="utf-8")
        # auto：dirty 会被自动 checkpoint 化解并放行
        self.assertIsNone(guard_export(self.studio_dir, "main", strict=False))
        self.assertFalse(is_dirty(self.studio_dir))

    def test_guard_export_strict_blocks_when_commit_fails(self):
        ensure_repo(self.studio_dir)
        (self.studio_dir / "tags.json").write_text("{}", encoding="utf-8")
        with mock.patch.object(
            git_guard, "_commit_all", side_effect=Exception("boom")
        ):
            reason = guard_export(self.studio_dir, "main", strict=True)
        self.assertIsInstance(reason, str)
        self.assertIn("strict", reason)

    def test_guard_export_unmanaged_strict(self):
        # 未初始化仓库 + strict：拦截
        reason = guard_export(self.studio_dir, "main", strict=True)
        self.assertIsInstance(reason, str)
        # 未初始化仓库 + auto：放行（降级 warning）
        self.assertIsNone(guard_export(self.studio_dir, "main", strict=False))

    # ------------------------------------------------------------------
    # 模式配置
    # ------------------------------------------------------------------

    def test_load_mode_defaults_and_invalid(self):
        self.assertEqual(load_mode(self.studio_dir), "auto")  # 文件缺失
        (self.studio_dir / "git_guard.json").write_text(
            "{bad json", encoding="utf-8"
        )
        self.assertEqual(load_mode(self.studio_dir), "auto")  # 非法 JSON
        (self.studio_dir / "git_guard.json").write_text(
            json.dumps({"mode": "yolo"}), encoding="utf-8"
        )
        self.assertEqual(load_mode(self.studio_dir), "auto")  # 非法值
        (self.studio_dir / "git_guard.json").write_text(
            json.dumps({"mode": "off"}), encoding="utf-8"
        )
        self.assertEqual(load_mode(self.studio_dir), "off")
        (self.studio_dir / "git_guard.json").write_text(
            json.dumps({"mode": "STRICT"}), encoding="utf-8"
        )
        self.assertEqual(load_mode(self.studio_dir), "strict")  # 大小写容错

    # ------------------------------------------------------------------
    # 业务 commit 消息
    # ------------------------------------------------------------------

    def test_commit_after_export(self):
        ensure_repo(self.studio_dir)
        (self.studio_dir / "ledger").mkdir()
        (self.studio_dir / "ledger" / "exports.json").write_text(
            "[]", encoding="utf-8"
        )
        commit_after_export(self.studio_dir, "main", 42)
        self.assertEqual(self._git_log()[0], "export(main): 42 images")

    def test_commit_after_export_failed(self):
        ensure_repo(self.studio_dir)
        (self.studio_dir / "logs").mkdir()
        (self.studio_dir / "logs" / "exports.jsonl").write_text(
            '{"action":"export_failed"}\n', encoding="utf-8"
        )
        commit_after_export(self.studio_dir, "daily", 0, failed=True)
        self.assertEqual(
            self._git_log()[0], "export(daily): failed after checkpoint (auto)"
        )

    def test_commit_after_rollback(self):
        ensure_repo(self.studio_dir)
        (self.studio_dir / "ledger").mkdir()
        (self.studio_dir / "ledger" / "exports.json").write_text(
            "[]", encoding="utf-8"
        )
        commit_after_rollback(self.studio_dir, ["main"], "op_123", "误导出")
        self.assertIn("rollback(main): op=op_123 误导出", self._git_log()[0])
        # 多模块：追加流水后再次提交
        with (self.studio_dir / "ledger" / "exports.json").open(
            "a", encoding="utf-8"
        ) as f:
            f.write('{"opId":"op_456"}\n')
        commit_after_rollback(self.studio_dir, ["main", "daily"], "op_456", "")
        self.assertIn("rollback(main,daily): op=op_456", self._git_log()[0])

    def test_business_commit_never_raises(self):
        """业务 commit 在仓库损坏时只降级，不得抛异常。"""
        ensure_repo(self.studio_dir)
        (self.studio_dir / ".git" / "HEAD").write_text("garbage", encoding="utf-8")
        commit_after_export(self.studio_dir, "main", 1)  # 不应 raise
        commit_after_rollback(self.studio_dir, ["main"], "op_x", "")

    # ------------------------------------------------------------------
    # 降级路径
    # ------------------------------------------------------------------

    def test_degrade_without_gitpython(self):
        """GitPython 不可用时走 CLI fallback，功能不缺失。"""
        ensure_repo(self.studio_dir)
        (self.studio_dir / "tags.json").write_text("{}", encoding="utf-8")
        with mock.patch.object(git_guard, "_HAS_GITPYTHON", False):
            self.assertTrue(checkpoint(self.studio_dir, "cli fallback cp"))
        self.assertIn("cli fallback cp", self._git_log()[0])

    # ------------------------------------------------------------------
    # helpers
    # ------------------------------------------------------------------

    def _git_log(self) -> list[str]:
        import subprocess

        proc = subprocess.run(
            ["git", "log", "--format=%s"],
            cwd=str(self.studio_dir),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        return [line for line in proc.stdout.splitlines() if line.strip()]


if __name__ == "__main__":
    unittest.main()
