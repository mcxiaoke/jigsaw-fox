#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.server — Content Studio 本地打包工作台 HTTP 服务端
纯标准库实现 (无需额外 pip 安装第三方 web 框架)，轻量秒启。
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import mimetypes
import sys
import threading
import urllib.parse
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any

# 确保以独立脚本执行时 (如 python studio/server.py)，项目根目录在 sys.path 中
_pkg_dir = Path(__file__).resolve().parent
_root_dir = _pkg_dir.parent
if str(_root_dir) not in sys.path:
    sys.path.insert(0, str(_root_dir))

from studio.core.image_proc import HAS_PIL, generate_thumbnail_bytes
from studio.core.scanner import find_tags_file, get_image_info, scan_images
from studio.core.tags_manager import (
    load_tags_file,
    merge_scanned_images,
    normalize_records,
    save_tags_file,
)
from studio.exporters import get_exporter
from studio.taxonomy import (
    ALL_CANONICAL_TAGS,
    CATALOG_DEFS,
    CATALOG_TO_TAGS_MAP,
    MAIN_TAGS,
    MAIN_TAG_IDS,
    SPECIFIC_TAG_DEFS,
    TAG_TO_CATALOGS,
    TAG_ZH,
)

STATIC_DIR = Path(__file__).parent / "static"


class StudioRequestHandler(BaseHTTPRequestHandler):
    """请求处理器：路由分发、API 响应与静态资源托管"""

    current_root_dir: Path | None = None

    def log_message(self, fmt: str, *args: Any) -> None:
        # 只输出简洁日志
        sys.stdout.write(f"[{self.log_date_time_string()}] {fmt % args}\n")

    def _cors(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Cache-Control")

    def _json(self, data: Any, status: int = 200) -> None:
        body = json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def _error(self, message: str, status: int = 400) -> None:
        self._json({"ok": False, "error": message}, status=status)

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self._cors()
        self.end_headers()

    # -----------------------------------------------------------------------
    # GET 路由分发
    # -----------------------------------------------------------------------
    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)

        # 1. 首页与静态文件
        if path in ("/", "/index.html"):
            self._serve_static_file(STATIC_DIR / "index.html", "text/html; charset=utf-8")
            return

        if path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
            return

        if path.startswith("/static/"):
            rel_path = path[len("/static/") :]
            target = STATIC_DIR / rel_path
            if target.exists() and target.is_file():
                ctype, _ = mimetypes.guess_type(str(target))
                self._serve_static_file(target, ctype or "application/octet-stream")
                return

        # 2. API 路由
        if path == "/api/health":
            self._json({"ok": True, "has_pil": HAS_PIL})
            return

        if path == "/api/taxonomy":
            self._handle_taxonomy()
            return

        if path == "/api/scan":
            self._handle_scan(qs)
            return

        if path == "/api/tags":
            self._handle_get_tags(qs)
            return

        if path == "/api/thumb":
            self._handle_thumb(qs)
            return

        if path == "/api/file":
            self._handle_file(qs)
            return

        # 兜底查找静态文件
        cand = STATIC_DIR / path.lstrip("/")
        if cand.exists() and cand.is_file():
            ctype, _ = mimetypes.guess_type(str(cand))
            self._serve_static_file(cand, ctype or "application/octet-stream")
            return

        self.send_error(404, f"Not Found: {path}")

    # -----------------------------------------------------------------------
    # POST 路由分发
    # -----------------------------------------------------------------------
    def do_POST(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        length = int(self.headers.get("Content-Length", 0))
        body_bytes = self.rfile.read(length) if length > 0 else b""

        try:
            data = json.loads(body_bytes.decode("utf-8")) if body_bytes else {}
        except Exception as e:
            self._error(f"JSON 解析失败: {e}", status=400)
            return

        if path == "/api/tags":
            self._handle_post_tags(data)
            return

        if path == "/api/export":
            self._handle_export(data)
            return

        self.send_error(404, f"Not Found POST: {path}")

    # -----------------------------------------------------------------------
    # 具体 API 业务处理
    # -----------------------------------------------------------------------
    def _handle_taxonomy(self) -> None:
        """返回完整的分类法元数据（前端单一事实源）"""
        self._json({
            "ok": True,
            "tags": MAIN_TAGS,
            "main_tags": MAIN_TAGS,
            "catalogs": MAIN_TAGS,
            "specific_tags": MAIN_TAGS,
            "tag_zh": TAG_ZH,
            "catalog_to_tags": CATALOG_TO_TAGS_MAP,
            "tag_to_catalogs": TAG_TO_CATALOGS,
            "all_canonical_tags": ALL_CANONICAL_TAGS,
        })

    def _handle_scan(self, qs: dict[str, list[str]]) -> None:
        """扫描指定目录下的图片，并加载或推断标签"""
        dir_param = (qs.get("dir") or [""])[0].strip()
        if not dir_param:
            self._error("缺少必要参数 ?dir=PATH")
            return

        root = Path(dir_param)
        if not root.exists():
            self._error(f"指定目录不存在: {dir_param}", status=404)
            return
        if not root.is_dir():
            self._error(f"指定路径不是目录: {dir_param}", status=400)
            return

        StudioRequestHandler.current_root_dir = root.resolve()

        images = scan_images(root)
        tag_file = find_tags_file(root)
        existing_records = None
        format_name = None

        if tag_file:
            raw_data, err = load_tags_file(tag_file)
            if not err and raw_data:
                existing_records, format_name = normalize_records(raw_data, root)

        records, stats = merge_scanned_images(images, root, existing_records)

        img_infos = [get_image_info(p, root) for p in images]
        img_infos = [info for info in img_infos if info is not None]

        self._json({
            "ok": True,
            "dir": str(root.resolve()),
            "tagFile": str(tag_file.resolve()) if tag_file else None,
            "tagFormat": format_name,
            "records": records,
            "stats": stats,
            "images": img_infos,
            "total": len(img_infos),
        })

    def _resolve_image_path(self, path_s: str, qs: dict[str, list[str]]) -> Path | None:
        """多策略路径解析：直接绝对路径、基于 ?dir 参数或上次扫描根目录"""
        if not path_s or not str(path_s).strip():
            return None
        decoded = urllib.parse.unquote(path_s).strip()
        candidates = [Path(decoded), Path(path_s)]

        # 1. 检查候选路径本身是否可直达
        for cand in candidates:
            try:
                if cand.exists() and cand.is_file():
                    return cand.resolve()
            except Exception:
                pass

        # 2. 如果是相对路径，优先尝试与 query 参数中的 ?dir= 拼接
        dir_param = (qs.get("dir") or [""])[0].strip()
        if dir_param:
            try:
                dir_root = Path(dir_param).resolve()
                for cand in candidates:
                    joined = dir_root / cand
                    if joined.exists() and joined.is_file():
                        return joined.resolve()
            except Exception:
                pass

        # 3. 回退与上次成功扫描的目录拼接
        if StudioRequestHandler.current_root_dir and StudioRequestHandler.current_root_dir.is_dir():
            try:
                for cand in candidates:
                    joined = StudioRequestHandler.current_root_dir / cand
                    if joined.exists() and joined.is_file():
                        return joined.resolve()
            except Exception:
                pass

        return None

    def _handle_get_tags(self, qs: dict[str, list[str]]) -> None:
        """读取 tags.json"""
        dir_param = (qs.get("dir") or [""])[0].strip()
        if not dir_param:
            self._error("缺少 ?dir 参数")
            return

        root = Path(dir_param)
        tag_file = find_tags_file(root)
        if not tag_file:
            self._error("未找到 tags.json 文件", status=404)
            return

        raw, err = load_tags_file(tag_file)
        if err:
            self._error(f"读取失败: {err}", status=500)
            return

        records, _ = normalize_records(raw, root)
        self._json({"ok": True, "file": str(tag_file.resolve()), "records": records})

    def _handle_post_tags(self, data: dict[str, Any]) -> None:
        """原子写回保存 tags.json"""
        dir_param = (data.get("dir") or "").strip()
        records = data.get("records")
        if not dir_param or records is None:
            self._error("缺少必要参数 dir 或 records")
            return

        root = Path(dir_param)
        if not root.exists() or not root.is_dir():
            self._error(f"目录不存在: {dir_param}", status=404)
            return

        ok, msg, count = save_tags_file(root, records)
        if ok:
            self._json({"ok": True, "file": msg, "count": count})
        else:
            self._error(f"保存失败: {msg}", status=500)

    def _handle_thumb(self, qs: dict[str, list[str]]) -> None:
        """缩略图输出 (带 HTTP 强缓存与 304 协商缓存)"""
        path_s = (qs.get("path") or [""])[0]
        size_s = (qs.get("size") or ["360"])[0]

        if not path_s:
            self.send_error(400, "Missing ?path")
            return

        p = self._resolve_image_path(path_s, qs)
        if not p:
            self.send_error(404, f"File not found: {path_s}")
            return

        try:
            size = int(size_s)
        except Exception:
            size = 360

        # ETag 协商缓存检查
        try:
            st = p.stat()
            etag = f'"{hashlib.md5(f"{p.resolve()}_{st.st_mtime_ns}_{st.st_size}_{size}".encode()).hexdigest()}"'
        except Exception:
            etag = None

        if etag and self.headers.get("If-None-Match") == etag:
            self.send_response(304)
            self._cors()
            self.end_headers()
            return

        data, ctype = generate_thumbnail_bytes(p, size=size)
        if data is None:
            self.send_error(500, "Thumbnail generation failed")
            return

        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "public, max-age=86400, immutable")
        if etag:
            self.send_header("ETag", etag)
        self._cors()
        self.end_headers()
        self.wfile.write(data)

    def _handle_file(self, qs: dict[str, list[str]]) -> None:
        """原图输出"""
        path_s = (qs.get("path") or [""])[0]
        if not path_s:
            self.send_error(400, "Missing ?path")
            return

        p = self._resolve_image_path(path_s, qs)
        if not p:
            self.send_error(404, f"File not found: {path_s}")
            return

        ctype, _ = mimetypes.guess_type(str(p))
        self._serve_static_file(p, ctype or "application/octet-stream")

    def _handle_export(self, data: dict[str, Any]) -> None:
        """统一资产导出处理"""
        exp_type = data.get("type", "main").strip().lower()
        src = (data.get("srcDir") or "").strip()
        out = (data.get("outDir") or "").strip()
        http_base = (data.get("httpBase") or "").strip()

        logs: list[dict[str, str]] = []

        def log_fn(msg: str, level: str = "info") -> None:
            logs.append({
                "t": dt.datetime.now().strftime("%H:%M:%S"),
                "level": level,
                "msg": msg,
            })

        if not src or not out:
            self._json({"ok": False, "error": "必须提供源目录 (srcDir) 与输出目录 (outDir)", "logs": logs}, 400)
            return

        src_p = Path(src)
        out_p = Path(out)

        log_fn(f"开始导出任务: [{exp_type.upper()}]")
        log_fn(f"源路径: {src}")
        log_fn(f"目标路径: {out}")

        try:
            exporter = get_exporter(exp_type, data, src_p, out_p, http_base, log_fn)
            exporter.validate()
            result = exporter.execute()
            result.logs = logs
            self._json(result.to_dict())
        except Exception as e:
            import traceback

            err_detail = traceback.format_exc().splitlines()[-1]
            log_fn(f"导出失败: {e} ({err_detail})", "err")
            self._json({
                "ok": False,
                "error": str(e),
                "logs": logs,
            }, status=500)

    def _serve_static_file(self, p: Path, ctype: str) -> None:
        if not p.exists() or not p.is_file():
            self.send_error(404, f"File not found: {p.name}")
            return
        data = p.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self._cors()
        self.end_headers()
        self.wfile.write(data)


def run_server(host: str = "127.0.0.1", port: int = 5188, auto_open: bool = False) -> None:
    """启动本地 HTTP 服务器"""
    server_addr = (host, port)
    httpd = HTTPServer(server_addr, StudioRequestHandler)
    url = f"http://{host}:{port}"
    print(f"\n=======================================================")
    print(f"  Content Studio — 拼图打包控制台已启动")
    print(f"  访问地址: {url}")
    print(f"  Pillow 加速: {'已启用' if HAS_PIL else '未安装 (直出原图)'}")
    print(f"=======================================================\n")

    if auto_open:
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n服务已停止。")
        httpd.server_close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Content Studio — 拼图内容打包工作室")
    parser.add_argument("--host", default="127.0.0.1", help="监听地址 (默认: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=5188, help="监听端口 (默认: 5188)")
    parser.add_argument("--open", action="store_true", help="启动后自动在浏览器打开")
    args = parser.parse_args()

    run_server(host=args.host, port=args.port, auto_open=args.open)


if __name__ == "__main__":
    main()
