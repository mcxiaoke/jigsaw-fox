#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.test_frontend — Content Studio 前端自动化冒烟测试与静态语法校验
集成 Node --check 语法检查与无头浏览器 (Edge/Chrome) CDP 挂载诊断，
杜绝 JS 未定义变量、Vue 挂载中断或静默白屏问题。
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import time
import unittest
import urllib.request
from pathlib import Path
from typing import Any

_pkg_dir = Path(__file__).resolve().parent
_root_dir = _pkg_dir.parent
STATIC_DIR = _pkg_dir / "static"
JS_DIR = STATIC_DIR / "js"


def get_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def find_browser_executable() -> str | None:
    candidates = [
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        shutil.which("msedge"),
        shutil.which("chrome"),
    ]
    for c in candidates:
        if c and Path(c).exists():
            return str(c)
    return None


def run_node_syntax_check() -> tuple[bool, list[str]]:
    """使用 node --check 静态校验所有 JS 脚本语法"""
    node_exe = shutil.which("node")
    if not node_exe:
        return True, ["Node.js 未安装，跳过 node --check 语法扫描"]

    errors: list[str] = []
    js_files = list(JS_DIR.glob("*.js"))
    for js_file in js_files:
        res = subprocess.run(
            [node_exe, "--check", str(js_file)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        if res.returncode != 0:
            errors.append(f"[{js_file.name}] 语法错误:\n{res.stderr.strip()}")

    return len(errors) == 0, errors


def run_headless_smoke_test(timeout_sec: float = 6.0) -> dict[str, Any]:
    """
    通过无头浏览器加载页面并使用 DevTools 协议捕获控制台报错与 Vue 挂载状态
    """
    browser_exe = find_browser_executable()
    if not browser_exe:
        return {"skipped": True, "reason": "未找到 Edge 或 Chrome 浏览器可执行文件"}

    node_exe = shutil.which("node")
    if not node_exe:
        return {"skipped": True, "reason": "未找到 Node.js 环境"}

    server_port = get_free_port()
    cdp_port = get_free_port()

    server_proc = subprocess.Popen(
        [sys.executable, str(_pkg_dir / "server.py"), "--port", str(server_port), "--host", "127.0.0.1"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    edge_proc = None
    try:
        # 等待服务器启动
        for _ in range(25):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{server_port}/api/health", timeout=0.5) as r:
                    if r.status == 200:
                        break
            except Exception:
                time.sleep(0.1)

        edge_proc = subprocess.Popen([
            browser_exe,
            "--headless",
            f"--remote-debugging-port={cdp_port}",
            "--disable-gpu",
            "--no-first-run",
            "--no-default-browser-check",
            f"http://127.0.0.1:{server_port}/",
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        # 运行 CDP 诊断脚本 (借助 Node 22 内置 WebSocket)
        cdp_js = f"""
const cdpPort = {cdp_port};
setTimeout(async () => {{
  try {{
    const res = await fetch('http://127.0.0.1:' + cdpPort + '/json');
    const tabs = await res.json();
    const pageTab = tabs.find(t => t.type === 'page');
    if (!pageTab) {{
      console.log(JSON.stringify({{ success: false, error: '未找到页面 Tab' }}));
      process.exit(1);
    }}
    const ws = new WebSocket(pageTab.webSocketDebuggerUrl);
    const consoleErrors = [];
    const exceptions = [];
    ws.onopen = () => {{
      ws.send(JSON.stringify({{ id: 1, method: 'Runtime.enable' }}));
      setTimeout(() => {{
        const browserExpr = "(() => {{" +
          "const app = document.getElementById('app');" +
          "const grid = document.querySelector('.image-grid');" +
          "const zoomInput = document.querySelector('.zoom-ctrl input');" +
          "const initialCardSize = grid ? getComputedStyle(grid).getPropertyValue('--card-size').trim() : '';" +
          "if (zoomInput) {{" +
          "  zoomInput.value = 320;" +
          "  zoomInput.dispatchEvent(new Event('input', {{ bubbles: true }}));" +
          "  zoomInput.dispatchEvent(new Event('change', {{ bubbles: true }}));" +
          "}}" +
          "let computedSortTestOk = false;" +
          "let computedSortError = '';" +
          "try {{" +
          "  if (window.__STUDIO_VM__) {{" +
          "    window.__STUDIO_VM__.records = [" +
          "      {{ file: 'b.jpg', path: 'b.jpg', mtime: 100, confidence: 0.9, size: 200, width: 800, height: 600, tags: ['animals'], review_required: false }}," +
          "      {{ file: 'a.jpg', path: 'a.jpg', mtime: 200, confidence: 0.8, size: 100, width: 1024, height: 768, tags: ['nature'], review_required: true }}," +
          "      {{ file: 'c.png', path: 'c.png', mtime: 300, confidence: 0.7, size: 300, width: 500, height: 500, tags: ['others'], review_required: true }}" +
          "    ];" +
          "    const keys = ['name', 'mtime', 'confidence', 'size', 'dimension'];" +
          "    for (const k of keys) {{" +
          "      window.__STUDIO_VM__.sortBy = k;" +
          "      window.__STUDIO_VM__.sortOrder = 'asc';" +
          "      const r1 = window.__STUDIO_VM__.filteredRecords;" +
          "      window.__STUDIO_VM__.sortOrder = 'desc';" +
          "      const r2 = window.__STUDIO_VM__.filteredRecords;" +
          "    }}" +
          "    window.__STUDIO_VM__.searchQuery = 'nature';" +
          "    const rSearch = window.__STUDIO_VM__.filteredRecords;" +
          "    window.__STUDIO_VM__.searchQuery = '';" +
          "    window.__STUDIO_VM__.onlyUnreviewed = true;" +
          "    const rUnrev = window.__STUDIO_VM__.filteredRecords;" +
          "    window.__STUDIO_VM__.onlyUnreviewed = false;" +
          "    computedSortTestOk = true;" +
          "  }}" +
          "}} catch (e) {{" +
          "  computedSortError = e.message || String(e);" +
          "}}" +
          "return new Promise(resolve => setTimeout(() => {{" +
          "  const newCardSize = grid ? getComputedStyle(grid).getPropertyValue('--card-size').trim() : '';" +
          "  resolve(JSON.stringify({{" +
          "    appMounted: Boolean(app && !app.hasAttribute('v-cloak'))," +
          "    hasFatalErrorBox: Boolean(document.getElementById('studio-fatal-error-box'))," +
          "    fatalErrorText: document.getElementById('studio-fatal-error-box')?.innerText || ''," +
          "    title: document.title," +
          "    serverStatusText: document.querySelector('.server-status-badge .status-text')?.textContent || ''," +
          "    brandText: document.querySelector('.brand')?.textContent || ''," +
          "    initialCardSize," +
          "    newCardSize," +
          "    hasZoomVal: Boolean(document.querySelector('.zoom-val'))," +
          "    computedSortTestOk," +
          "    computedSortError" +
          "  }}));" +
          "}}, 100));" +
          "}})()";
        ws.send(JSON.stringify({{
          id: 2,
          method: 'Runtime.evaluate',
          params: {{ expression: browserExpr, awaitPromise: true }}
        }}));
      }}, 1600);
    }};
    ws.onmessage = (event) => {{
      const msg = JSON.parse(event.data);
      if (msg.method === 'Runtime.consoleAPICalled' && msg.params.type === 'error') {{
        consoleErrors.push(msg.params.args.map(a => a.value || a.description).join(' '));
      }} else if (msg.method === 'Runtime.exceptionThrown') {{
        exceptions.push(JSON.stringify(msg.params.exceptionDetails));
      }} else if (msg.id === 2) {{
        const evalVal = JSON.parse(msg.result?.result?.value || '{{}}');
        console.log(JSON.stringify({{
          success: true,
          consoleErrors,
          exceptions,
          domState: evalVal
        }}));
        ws.close();
        process.exit(0);
      }}
    }};
  }} catch (err) {{
    console.log(JSON.stringify({{ success: false, error: err.message }}));
    process.exit(1);
  }}
}}, 1200);
"""
        res = subprocess.run(
            [node_exe, "-e", cdp_js],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout_sec + 4,
        )
        try:
            return json.loads(res.stdout.strip())
        except Exception:
            return {"success": False, "raw_stdout": res.stdout, "raw_stderr": res.stderr}
    finally:
        if edge_proc:
            edge_proc.terminate()
            try:
                edge_proc.wait(timeout=1.0)
            except Exception:
                edge_proc.kill()
        if server_proc:
            server_proc.terminate()
            try:
                server_proc.wait(timeout=1.0)
            except Exception:
                server_proc.kill()


class TestFrontendSmoke(unittest.TestCase):
    """前端静态与无头冒烟自动化回归测试"""

    def test_js_syntax_integrity(self):
        ok, errors = run_node_syntax_check()
        self.assertTrue(ok, "JS 语法检测未通过:\n" + "\n".join(errors))

    def test_page_headless_mount(self):
        result = run_headless_smoke_test()
        if result.get("skipped"):
            self.skipTest(f"无头测试跳过: {result.get('reason')}")
        self.assertTrue(result.get("success"), f"无头 CDP 检测失败: {result}")
        dom = result.get("domState", {})
        self.assertFalse(dom.get("hasFatalErrorBox"), f"页面触发了致命错误弹窗: {dom.get('fatalErrorText')}")
        self.assertTrue(dom.get("appMounted"), "Vue 应用未成功挂载，页面残留 v-cloak (发生白屏)")
        self.assertEqual(len(result.get("consoleErrors", [])), 0, f"控制台存在报错: {result.get('consoleErrors')}")
        self.assertEqual(len(result.get("exceptions", [])), 0, f"存在未捕获异常: {result.get('exceptions')}")
        self.assertIn("Content Studio", dom.get("title", ""))
        self.assertTrue(dom.get("hasZoomVal"), "缩略图大小数值提示框不存在 (.zoom-val)")
        self.assertEqual(dom.get("newCardSize"), "320px", f"缩略图大小调整未能响应式改变 --card-size: {dom.get('newCardSize')}")
        self.assertTrue(dom.get("computedSortTestOk"), f"排序与过滤动态计算测试失败: {dom.get('computedSortError')}")


if __name__ == "__main__":
    unittest.main()
