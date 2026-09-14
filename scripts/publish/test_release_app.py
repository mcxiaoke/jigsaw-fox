#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_release_app.py — 针对 release_app.py 的单元测试与完整性验证测试
"""

import hashlib
import http.server
import json
import socketserver
import tempfile
import threading
import unittest
from pathlib import Path

from release_app import (
    calculate_sha256_and_size,
    generate_manifest,
    get_pubspec_version,
    fetch_remote_stream_and_verify,
    flatten_platform_entries,
)


class TestReleaseApp(unittest.TestCase):

    def test_flatten_platform_entries(self):
        platforms = {
            "android": {
                "arm64-v8a": {"url": "a.apk", "sha256": "1", "size": 10},
                "all": {"url": "all.apk", "sha256": "2", "size": 20},
            },
            "windows": {
                "url": "win.zip", "sha256": "3", "size": 30,
            }
        }
        entries = flatten_platform_entries(platforms)
        self.assertEqual(len(entries), 3)
        self.assertEqual(entries[0], ("android", "arm64-v8a", {"url": "a.apk", "sha256": "1", "size": 10}))
        self.assertEqual(entries[1], ("android", "all", {"url": "all.apk", "sha256": "2", "size": 20}))
        self.assertEqual(entries[2], ("windows", None, {"url": "win.zip", "sha256": "3", "size": 30}))

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


if __name__ == "__main__":
    unittest.main()
