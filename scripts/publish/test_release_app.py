#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_release_app.py — 针对 release_app.py 的单元测试与完整性验证测试
"""

import hashlib
import http.server
import json
import os
import socketserver
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

import release_app

from release_app import (
    calculate_sha256_and_size,
    generate_manifest,
    get_pubspec_version,
    fetch_remote_stream_and_verify,
    flatten_platform_entries,
    _app_release_assets,
    _missing_assets,
)


class TestReleaseApp(unittest.TestCase):
    def test_flatten_platform_entries(self):
        platforms = {
            "android": {
                "arm64-v8a": {"url": "a.apk", "sha256": "1", "size": 10},
                "all": {"url": "all.apk", "sha256": "2", "size": 20},
            },
            "windows": {
                "url": "win.zip",
                "sha256": "3",
                "size": 30,
            },
        }
        entries = flatten_platform_entries(platforms)
        self.assertEqual(len(entries), 3)
        self.assertEqual(
            entries[0],
            ("android", "arm64-v8a", {"url": "a.apk", "sha256": "1", "size": 10}),
        )
        self.assertEqual(
            entries[1],
            ("android", "all", {"url": "all.apk", "sha256": "2", "size": 20}),
        )
        self.assertEqual(
            entries[2], ("windows", None, {"url": "win.zip", "sha256": "3", "size": 30})
        )

    def test_calculate_sha256_and_size(self):
        with tempfile.NamedTemporaryFile(delete=False) as tf:
            tf.write(b"hello world test autoupdate")
            tf_path = Path(tf.name)

        try:
            expected_sha = hashlib.sha256(b"hello world test autoupdate").hexdigest()
            calc_sha, size = calculate_sha256_and_size(tf_path)
            self.assertEqual(calc_sha, expected_sha)
            self.assertEqual(size, len(b"hello world test autoupdate"))
        finally:
            tf_path.unlink(missing_ok=True)

    def test_generate_manifest(self):
        manifest = generate_manifest(
            version_name="1.0.1",
            version_code=2,
            platforms_data={
                "android": {
                    "url": "app/1.0.1+2/android/app-release.apk",
                    "sha256": "abcdef",
                    "size": 12345,
                    "mirrors": [],
                }
            },
            min_version_code=1,
        )
        self.assertEqual(manifest["version"], "1.0.1")
        self.assertEqual(manifest["versionCode"], 2)
        self.assertEqual(manifest["minVersionCode"], 1)
        self.assertIn("android", manifest["platforms"])
        self.assertIn("publishedAt", manifest)

    def test_fetch_remote_stream_and_verify_success_and_corruption(self):
        # 启动一个本地临时 HTTP 服务，测试流式下载与完整性校验
        test_data = b"This is a binary package content for testing integrity."
        correct_sha = hashlib.sha256(test_data).hexdigest()
        correct_size = len(test_data)

        class CustomHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == "/valid.apk":
                    self.send_response(200)
                    self.send_header("Content-Length", str(correct_size))
                    self.end_headers()
                    self.wfile.write(test_data)
                else:
                    self.send_response(404)
                    self.end_headers()

            def log_message(self, format, *args):
                pass  # 静默测试服务器日志

        # 动态绑定可用端口
        with socketserver.TCPServer(("127.0.0.1", 0), CustomHandler) as httpd:
            port = httpd.server_address[1]
            server_thread = threading.Thread(target=httpd.serve_forever, daemon=True)
            server_thread.start()

            base_url = f"http://127.0.0.1:{port}"

            # 1. 成功案例
            sha, size = fetch_remote_stream_and_verify(
                url=f"{base_url}/valid.apk",
                expected_sha256=correct_sha,
                expected_size=correct_size,
            )
            self.assertEqual(sha, correct_sha)
            self.assertEqual(size, correct_size)

            # 2. 哈希损坏案例（必须被拦截）
            with self.assertRaises(ValueError) as cm:
                fetch_remote_stream_and_verify(
                    url=f"{base_url}/valid.apk",
                    expected_sha256="wrong_sha256_hash",
                    expected_size=correct_size,
                )
            self.assertIn("SHA256 哈希校验失败", str(cm.exception))

            # 3. 大小损坏案例（必须被拦截）
            with self.assertRaises(ValueError) as cm:
                fetch_remote_stream_and_verify(
                    url=f"{base_url}/valid.apk",
                    expected_sha256=correct_sha,
                    expected_size=correct_size + 100,
                )
            self.assertIn("文件大小不匹配", str(cm.exception))

            # 4. 404 资源不存在案例（必须被拦截）
            with self.assertRaises(ValueError) as cm:
                fetch_remote_stream_and_verify(
                    url=f"{base_url}/nonexistent.apk",
                    expected_sha256=correct_sha,
                    expected_size=correct_size,
                )
            self.assertIn("404", str(cm.exception))

            httpd.shutdown()

    def test_app_release_assets(self):
        # 仅收集目录下的文件（排除子目录），按文件名排序
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            (d / "b.txt").write_text("x", encoding="utf-8")
            (d / "a.apk").write_bytes(b"apk")
            (d / "sub").mkdir()
            (d / "sub" / "nested.zip").write_bytes(b"z")
            assets = _app_release_assets(d)
            self.assertEqual([p.name for p in assets], ["a.apk", "b.txt"])
            self.assertEqual(
                [p.name for p in _app_release_assets(d / "sub")], ["nested.zip"]
            )

    def test_missing_assets(self):
        assets = [Path("JigsawFox-1.0.1-all.apk"), Path("updates.json"), Path("SHA256SUMS")]
        existing = {"JigsawFox-1.0.1-all.apk"}
        missing = _missing_assets(assets, existing, force=False)
        self.assertEqual([f.name for f in missing], ["updates.json", "SHA256SUMS"])
        # --force 时忽略远端清单，全部重传
        self.assertEqual(len(_missing_assets(assets, existing, force=True)), 3)

    # ---------------------------------------------------------------- 镜像发布逻辑（mock gh/OpenAPI，零网络）
    def test_publish_github_release_incremental(self):
        # release 已存在：只按文件名差集上传缺失资产，不创建
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            (d / "a.apk").write_bytes(b"a")
            (d / "b.txt").write_text("b", encoding="utf-8")
            calls: list = []

            def fake_run(cmd, **kw):
                calls.append(cmd)
                if cmd[:3] == ["gh", "release", "view"] and "--json" not in cmd:
                    return mock.Mock(returncode=0)  # release 存在
                if "--json" in cmd and "-q" in cmd:
                    return mock.Mock(returncode=0, stdout="a.apk\n")  # 远端已有 a.apk
                return mock.Mock(returncode=0)

            with mock.patch.object(release_app.subprocess, "run", side_effect=fake_run):
                rc = release_app.publish_github_release("v1.0.1", d)
            self.assertEqual(rc, 0)
            uploads = [c for c in calls if c[:3] == ["gh", "release", "upload"]]
            creates = [c for c in calls if c[:3] == ["gh", "release", "create"]]
            self.assertEqual(len(uploads), 1)
            # upload 参数为绝对路径，按文件名校验仅上传缺失的 b.txt
            file_args = [str(c) for c in uploads[0] if c.endswith(".apk") or c.endswith(".txt")]
            self.assertEqual([Path(c).name for c in file_args], ["b.txt"])
            self.assertIn("--clobber", uploads[0])
            self.assertEqual(len(creates), 0)

    def test_publish_github_release_creates_if_missing(self):
        # release 不存在：先带 --verify-tag 创建，失败后退化重试
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            (d / "a.apk").write_bytes(b"a")
            seen: list = []

            def fake_run(cmd, **kw):
                seen.append(cmd)
                if cmd[:3] == ["gh", "release", "view"]:
                    return mock.Mock(returncode=1)
                if cmd[:3] == ["gh", "release", "create"]:
                    return mock.Mock(returncode=1 if "--verify-tag" in cmd else 0)
                if "--json" in cmd:
                    return mock.Mock(returncode=0, stdout="")
                return mock.Mock(returncode=0)

            with mock.patch.object(release_app.subprocess, "run", side_effect=fake_run):
                rc = release_app.publish_github_release("v1.0.1", d)
            self.assertEqual(rc, 0)
            creates = [c for c in seen if c[:3] == ["gh", "release", "create"]]
            self.assertEqual(len(creates), 2)
            self.assertIn("--verify-tag", creates[0])
            self.assertNotIn("--verify-tag", creates[1])

    def test_publish_gitee_release_incremental(self):
        # release 已存在 + attach_files 已含 a.apk -> 仅上传 b.txt；token 缺失则 FATAL
        api = release_app.GITEE_API
        repo = f"{api}/repos/{release_app.GITEE_MIRROR_REPO}"
        responses = {
            ("GET", f"{repo}/releases/tags/v9.9.9"): (200, json.dumps({"id": 42, "assets": []})),
            ("GET", f"{repo}/releases/42/attach_files?per_page=100"): (
                200, json.dumps([{"name": "a.apk", "size": 1}])),
        }
        post_count = {"n": 0}

        def fake_req(method, url, token=None, data=None, content_type=None, timeout=60):
            key = (method, url)
            if key == ("POST", f"{repo}/releases/42/attach_files"):
                post_count["n"] += 1
                return 201, "{}"
            return responses.get(key, (404, f"unexpected {key}"))

        old_token = os.environ.get("GITEE_TOKEN")
        os.environ["GITEE_TOKEN"] = "test-token"
        try:
            with tempfile.TemporaryDirectory() as td:
                d = Path(td)
                (d / "a.apk").write_bytes(b"a")
                (d / "b.txt").write_text("b", encoding="utf-8")
                with mock.patch.object(release_app, "_gitee_req", side_effect=fake_req):
                    rc = release_app.publish_gitee_release("v9.9.9", d)
            self.assertEqual(rc, 0)
            self.assertEqual(post_count["n"], 1)  # 只上传缺失的 b.txt
            # token 缺失 -> FATAL rc=2
            os.environ.pop("GITEE_TOKEN", None)
            with tempfile.TemporaryDirectory() as td:
                d = Path(td)
                (d / "a.apk").write_bytes(b"a")
                rc2 = release_app.publish_gitee_release("v9.9.9", d)
            self.assertEqual(rc2, 2)
        finally:
            if old_token is None:
                os.environ.pop("GITEE_TOKEN", None)
            else:
                os.environ["GITEE_TOKEN"] = old_token

    def test_publish_gitee_release_creates_and_fails(self):
        # release 不存在 -> 创建成功；上传失败 -> 返回 1（中止发布）
        api = release_app.GITEE_API
        repo = f"{api}/repos/{release_app.GITEE_MIRROR_REPO}"
        responses = {
            # Gitee 对不存在 release 返回 200 + body "null" 的坑
            ("GET", f"{repo}/releases/tags/v9.9.8"): (200, "null"),
            ("POST", f"{repo}/releases"): (201, json.dumps({"id": 7, "assets": []})),
            ("GET", f"{repo}/releases/7/attach_files?per_page=100"): (200, "[]"),
        }

        def fake_req(method, url, token=None, data=None, content_type=None, timeout=60):
            key = (method, url)
            if key == ("POST", f"{repo}/releases/7/attach_files"):
                return 500, "boom"
            return responses.get(key, (404, f"unexpected {key}"))

        old_token = os.environ.get("GITEE_TOKEN")
        os.environ["GITEE_TOKEN"] = "test-token"
        try:
            with tempfile.TemporaryDirectory() as td:
                d = Path(td)
                (d / "a.apk").write_bytes(b"a")
                with mock.patch.object(release_app, "_gitee_req", side_effect=fake_req):
                    rc = release_app.publish_gitee_release("v9.9.8", d)
            self.assertEqual(rc, 1)
        finally:
            if old_token is None:
                os.environ.pop("GITEE_TOKEN", None)
            else:
                os.environ["GITEE_TOKEN"] = old_token


if __name__ == "__main__":
    unittest.main()
