#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Content Packaging Studio — Local packaging tool for jigsaw puzzle
  python scripts/packaging/server.py
  python scripts/packaging/server.py --port 5173 --open

No build, no npm. Serves index.html + JSON APIs for directory scan / thumb / tags / export.
Works with tags.json produced by scripts/ai_tag_images.py (21-tag taxonomy, single primary tag).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import shutil
import sys
import threading
import urllib.parse
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any

# Pillow optional for thumbnails
try:
    from PIL import Image  # type: ignore
    HAS_PIL = True
except ImportError:
    HAS_PIL = False

# ---------------------------------------------------------------------------
# Tag vocab (21) — aligned with docs/jigsaw-image-tagging-specification.md v1.1
# ---------------------------------------------------------------------------

TAGS_21 = [
    "Animals", "Pets", "Nature", "Landscapes", "Flowers", "Ocean", "Birds",
    "Cities", "Architecture", "Food", "Art", "Fantasy", "Space", "Transportation",
    "People", "Sports", "Seasons", "Holidays", "Abstract", "Cartoon", "Others",
]

TAG_ZH: dict[str, str] = {
    "Animals": "动物", "Pets": "宠物", "Nature": "自然", "Landscapes": "风景",
    "Flowers": "花卉", "Ocean": "海洋", "Birds": "鸟类", "Cities": "城市",
    "Architecture": "建筑", "Food": "美食", "Art": "艺术", "Fantasy": "奇幻",
    "Space": "太空", "Transportation": "交通", "People": "人物", "Sports": "运动",
    "Seasons": "四季", "Holidays": "节日", "Abstract": "抽象", "Cartoon": "卡通",
    "Others": "其他",
}

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".tif", ".tiff"}

# Keep docs/puzzle-content-storage-and-expansion-design.md §4.1 / §4.3 compliant
# main.json: { version, levels:[{url, tags:[single], order}] }
# events.json: handled separately if needed


def scan_images(root: Path) -> list[Path]:
    return sorted(
        p for p in root.rglob("*")
        if p.is_file() and p.suffix.lower() in IMAGE_EXTS
    )


def find_tags_file(root: Path) -> Path | None:
    for name in ("tags.json", "ai_tags.json", "puzzle_tags.json", ".puzzle_tags.json"):
        cand = root / name
        # also check one level up for convenience?
        if cand.exists():
            return cand
    # also search one deep subdirs? no, keep simple: only root
    return None


def load_tags_file(p: Path) -> Any:
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:
        return {"_error": str(e)}


def normalize_tags_records(raw: Any, root: Path) -> tuple[list[dict[str, Any]], str]:
    """
    Normalize both formats:
      - ai_tag_images.py: list[{path, sha1, tag, confidence, review_required, ...}]
      - studio intermediate dict: {version, images:[{file, tag, correctedTag, ...}]}
    Returns (records_list, format_name)
      records_list items: {path, file, tag, confidence, correctedTag, review_required, subject, scene, reason, sha1}
    """
    records: list[dict[str, Any]] = []

    if isinstance(raw, list):
        # ai_tag_images output
        for item in raw:
            if not isinstance(item, dict):
                continue
            rel = item.get("path") or item.get("file") or ""
            records.append({
                "path": rel,
                "file": Path(rel).name,
                "tag": item.get("tag", "Others"),
                "confidence": float(item.get("confidence", 0) or 0),
                "correctedTag": item.get("correctedTag"),
                "review_required": bool(item.get("review_required", False)),
                "subject": item.get("subject", ""),
                "scene": item.get("scene", ""),
                "reason": item.get("reason", ""),
                "sha1": item.get("sha1", ""),
                "model": item.get("model", ""),
            })
        return records, "list"

    if isinstance(raw, dict):
        # dict wrappers
        # studio format {images:[...]}
        if "images" in raw and isinstance(raw["images"], list):
            for item in raw["images"]:
                rel = item.get("file") or item.get("path") or ""
                # if file contains subdir, keep it
                records.append({
                    "path": rel,
                    "file": Path(rel).name,
                    "tag": item.get("tag", "Others"),
                    "confidence": float(item.get("confidence", 0) or 0),
                    "correctedTag": item.get("correctedTag"),
                    "review_required": bool(item.get("review_required", False)),
                    "subject": item.get("subject", ""),
                    "scene": item.get("scene", ""),
                    "reason": item.get("reason", ""),
                    "sha1": item.get("sha1", ""),
                    "model": item.get("model", ""),
                })
            return records, "dict-images"
        # legacy {levels:[...]} ignore
        return records, "dict-unknown"

    return records, "unknown"


def build_main_levels(
    records: list[dict[str, Any]],
    image_paths: list[Path],
    root: Path,
    http_base: str,
) -> list[dict[str, Any]]:
    """
    Build levels for main.json from records + filesystem.
    Effective tag = correctedTag if present else tag
    Url = http_base + "/main/" + filename (preserve ext)  — or subpath if needed
    Order = natural sort order (1-indexed for display, but pipeline uses numeric suffix)
    For now we number from 101 to preserve main:101 canonical (configurable)
    """
    # Map path -> effective tag
    tag_map: dict[str, str] = {}
    for r in records:
        eff = (r.get("correctedTag") or r.get("tag") or "Others").strip()
        if eff not in TAGS_21:
            eff = "Others"
        # normalize path key: posix relative
        key = (r.get("path") or r.get("file") or "").replace("\\", "/")
        tag_map[key] = eff
        # also index by basename for convenience
        bn = Path(key).name
        if bn not in tag_map:
            tag_map[bn] = eff

    levels: list[dict[str, Any]] = []
    # natural sort by name
    sorted_paths = sorted(image_paths, key=lambda p: p.relative_to(root).as_posix().lower())

    base = http_base.rstrip("/")
    # Detect start order from http_base? keep 101 default
    # If image count huge, continue from 101
    start = 101

    for idx, p in enumerate(sorted_paths):
        rel = p.relative_to(root).as_posix()
        bn = p.name
        # try rel, then bn
        eff = tag_map.get(rel) or tag_map.get(bn) or "Others"
        # effective tags is single-element array (single primary tag)
        url = f"{base}/main/{urllib.parse.quote(bn)}"
        levels.append({
            "url": url,
            "tags": [eff],
            "order": start + idx,
            "_file": rel,  # debug, stripped before write
            "_effectiveTag": eff,
        })

    return levels


class Handler(BaseHTTPRequestHandler):
    # class var set by main()
    serve_dir: Path = Path(__file__).parent

    def log_message(self, format, *args):
        # quiet except errors; print to stdout
        sys.stdout.write(f"[{self.log_date_time_string()}] {format % args}\n")

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)

        # Static
        if path in ("/", "/index.html"):
            self._serve_file(self.serve_dir / "index.html", "text/html; charset=utf-8")
            return
        if path == "/api/health":
            self._json({"ok": True, "has_pil": HAS_PIL, "tags": TAGS_21})
            return
        if path == "/api/scan":
            self._handle_scan(qs)
            return
        if path == "/api/thumb":
            self._handle_thumb(qs)
            return
        if path == "/api/tags":
            self._handle_get_tags(qs)
            return
        if path == "/api/file":
            # serve arbitrary image for preview (same as thumb but full)
            self._handle_file(qs)
            return

        # fallback static
        rel = Path(path.lstrip("/"))
        cand = self.serve_dir / rel
        if cand.exists() and cand.is_file():
            ctype, _ = mimetypes.guess_type(str(cand))
            self._serve_file(cand, ctype or "application/octet-stream")
            return

        self.send_error(404, f"Not found: {path}")

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        try:
            data = json.loads(body.decode("utf-8")) if body else {}
        except Exception:
            data = {}

        if path == "/api/tags":
            self._handle_post_tags(data)
            return
        if path == "/api/export/main":
            self._handle_export_main(data)
            return
        if path == "/api/export/events":
            self._handle_export_events(data)
            return
        if path == "/api/export/daily":
            self._handle_export_daily(data)
            return

        self.send_error(404, f"Not found POST {path}")

    # ---- handlers ----

    def _json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self._cors()
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_file(self, p: Path, ctype: str):
        if not p.exists():
            self.send_error(404, str(p))
            return
        data = p.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self._cors()
        self.send_header("Content-Length", str(len(data)))
        # cache thumbs
        if "thumb" in self.path:
            self.send_header("Cache-Control", "public, max-age=3600")
        self.end_headers()
        self.wfile.write(data)

    def _handle_scan(self, qs):
        dir_s = (qs.get("dir") or qs.get("path") or [""])[0]
        if not dir_s:
            self._json({"error": "missing ?dir=PATH"}, 400)
            return
        root = Path(dir_s)
        if not root.exists():
            self._json({"error": f"dir not found: {dir_s}"}, 404)
            return
        if not root.is_dir():
            self._json({"error": f"not a directory: {dir_s}"}, 400)
            return

        images = scan_images(root)
        tag_file = find_tags_file(root)
        tag_records: list[dict[str, Any]] | None = None
        tag_format: str | None = None
        tag_error: str | None = None
        raw_tags: Any = None
        if tag_file is not None:
            raw_tags = load_tags_file(tag_file)
            if isinstance(raw_tags, dict) and "_error" in raw_tags:
                tag_error = raw_tags["_error"]
            else:
                tag_records, tag_format = normalize_tags_records(raw_tags, root)

        # build response
        img_list = []
        for p in images:
            try:
                stat = p.stat()
                rel = p.relative_to(root).as_posix()
                img_list.append({
                    "path": rel,
                    "file": p.name,
                    "size": stat.st_size,
                    "mtime": int(stat.st_mtime),
                })
            except Exception:
                continue

        # stats by effective tag
        tag_stats: dict[str, int] = {}
        review_count = 0
        if tag_records is not None:
            # quick map for stats
            for r in tag_records:
                eff = (r.get("correctedTag") or r.get("tag") or "Others")
                tag_stats[eff] = tag_stats.get(eff, 0) + 1
                if r.get("review_required"):
                    review_count += 1
                # low confidence also
                try:
                    if float(r.get("confidence", 1)) < 0.75:
                        # already counted if review_required, but ensure
                        pass
                except Exception:
                    pass

        self._json({
            "dir": str(root.resolve()),
            "tagFile": str(tag_file.resolve()) if tag_file else None,
            "tagFormat": tag_format,
            "tagError": tag_error,
            "tagRecords": tag_records,
            "rawTags": raw_tags if isinstance(raw_tags, list) and len(str(raw_tags)) < 20000 else None,
            "images": img_list,
            "total": len(img_list),
            "stats": {"byTag": tag_stats, "reviewCount": review_count},
        })

    def _handle_get_tags(self, qs):
        dir_s = (qs.get("dir") or [""])[0]
        if not dir_s:
            self._json({"error": "missing ?dir"}, 400)
            return
        root = Path(dir_s)
        tag_file = find_tags_file(root)
        if tag_file is None:
            # also allow explicit tags.json path via ?path=
            alt = qs.get("path", [None])[0]
            if alt and Path(alt).exists():
                tag_file = Path(alt)
            else:
                self._json({"error": "tags.json not found", "dir": str(root)}, 404)
                return
        raw = load_tags_file(tag_file)
        self._json({"file": str(tag_file), "data": raw})

    def _handle_post_tags(self, data):
        dir_s = data.get("dir") or data.get("root") or ""
        records = data.get("records") or data.get("images") or data.get("tags")
        # flexible: allow either list of records, or object {images:[...]}
        if not dir_s:
            self._json({"error": "missing dir"}, 400)
            return
        root = Path(dir_s)
        if not root.exists():
            self._json({"error": "dir not found"}, 404)
            return
        if records is None:
            self._json({"error": "missing records"}, 400)
            return

        # normalize incoming records to ai_tag_images list format for compatibility
        # incoming may be [{path, tag, confidence, correctedTag, ...}]
        # we want to persist as list[{path, tag, correctedTag, confidence, review_required, ...}]
        # Keep existing sha1 if available
        existing_raw = None
        tag_file = root / "tags.json"
        existing = find_tags_file(root)
        if existing and existing.exists():
            existing_raw = load_tags_file(existing)
            # if existing was list, keep sha1 mapping
            tag_file = existing

        # Build sha map from existing list
        sha_map: dict[str, str] = {}
        if isinstance(existing_raw, list):
            for item in existing_raw:
                if isinstance(item, dict) and item.get("path"):
                    sha_map[item["path"]] = item.get("sha1", "")

        out_list: list[dict[str, Any]] = []
        # records may be dict with images
        flat: list[dict[str, Any]]
        if isinstance(records, dict) and "images" in records:
            flat = records["images"]  # type: ignore
        elif isinstance(records, list):
            flat = records  # type: ignore
        else:
            flat = []

        for item in flat:
            if not isinstance(item, dict):
                continue
            rel = (item.get("path") or item.get("file") or "").replace("\\", "/")
            if not rel:
                continue
            tag = (item.get("correctedTag") or item.get("tag") or "Others").strip()
            if tag not in TAGS_21:
                # allow tag vocab case-insensitive mapping? keep as-is but validate
                # try capitalize
                cap = tag[:1].upper() + tag[1:].lower() if tag else "Others"
                if cap in TAGS_21:
                    tag = cap
                else:
                    tag = "Others"
            conf = item.get("confidence", 0.8)
            try:
                conf = float(conf)
            except Exception:
                conf = 0.8
            eff = tag  # for review flag, use effective
            review = bool(item.get("review_required", False))
            # auto review if low confidence or Others
            if conf < 0.75 or eff == "Others":
                # keep existing review flag if explicitly set false? but spec says auto
                # we compute but allow manual override via review_required field
                if "review_required" not in item:
                    review = (conf < 0.75 or eff == "Others")

            out_list.append({
                "path": rel,
                "sha1": item.get("sha1") or sha_map.get(rel, ""),
                "tag": item.get("tag") or tag,
                "correctedTag": item.get("correctedTag"),
                # Store effective tag as tag if correctedTag present? Keep both.
                # For ai compatibility, store final tag as effective? But we keep tag + correctedTag
                "confidence": conf,
                "subject": item.get("subject", ""),
                "scene": item.get("scene", ""),
                "reason": item.get("reason", ""),
                "review_required": review,
                "model": item.get("model", "manual"),
                "taxonomy_version": "jigsaw-tag-v1.1-21",
            })
            # Ensure tag field reflects effective for downstream?
            # We keep tag as original AI, correctedTag as manual.

        # atomic write
        tmp = tag_file.with_suffix(tag_file.suffix + ".tmp")
        tmp.write_text(json.dumps(out_list, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(tag_file)

        self._json({"ok": True, "file": str(tag_file.resolve()), "count": len(out_list)})

    def _handle_thumb(self, qs):
        path_s = (qs.get("path") or qs.get("p") or [""])[0]
        size_s = (qs.get("size") or qs.get("s") or ["360"])[0]
        try:
            size = int(size_s)
            size = max(64, min(size, 800))
        except Exception:
            size = 360

        if not path_s:
            self.send_error(400, "missing ?path")
            return
        # path may be absolute or relative; try resolve
        p = Path(path_s)
        if not p.exists():
            # try url decoding
            p = Path(urllib.parse.unquote(path_s))
        if not p.exists():
            self.send_error(404, f"file not found: {path_s}")
            return
        if not p.is_file():
            self.send_error(404, "not a file")
            return

        # If PIL available, resize; else serve original
        if HAS_PIL:
            try:
                # Use Pillow to generate thumbnail
                with Image.open(p) as im:  # type: ignore
                    # exif transpose
                    try:
                        from PIL import ImageOps  # type: ignore
                        im = ImageOps.exif_transpose(im)  # type: ignore
                    except Exception:
                        pass
                    # convert to RGB if needed for JPEG thumb
                    if im.mode not in ("RGB", "RGBA"):
                        im = im.convert("RGB")  # type: ignore
                    # thumbnail
                    im.thumbnail((size, size), Image.LANCZOS)  # type: ignore
                    # save to bytes
                    import io
                    buf = io.BytesIO()
                    # Use WEBP for smaller transfer if supported, else JPEG
                    # Browser supports webp, but to keep simple use JPEG
                    # Preserve transparency? convert to JPEG
                    if im.mode == "RGBA":
                        # composite on white
                        bg = Image.new("RGB", im.size, (255, 255, 255))  # type: ignore
                        bg.paste(im, mask=im.split()[3])  # type: ignore
                        im = bg  # type: ignore
                    im.save(buf, format="JPEG", quality=82, optimize=True)  # type: ignore
                    data = buf.getvalue()
                    self.send_response(200)
                    self.send_header("Content-Type", "image/jpeg")
                    self.send_header("Content-Length", str(len(data)))
                    self.send_header("Cache-Control", "public, max-age=3600")
                    self._cors()
                    self.end_headers()
                    self.wfile.write(data)
                    return
            except Exception as e:
                # fallback to original
                sys.stderr.write(f"thumb error {p}: {e}\n")

        # fallback: serve original file bytes
        ctype, _ = mimetypes.guess_type(str(p))
        self._serve_file(p, ctype or "image/jpeg")

    def _handle_file(self, qs):
        path_s = (qs.get("path") or [""])[0]
        if not path_s:
            self.send_error(400, "missing ?path")
            return
        p = Path(urllib.parse.unquote(path_s))
        if not p.exists():
            self.send_error(404, f"file not found: {path_s}")
            return
        ctype, _ = mimetypes.guess_type(str(p))
        self._serve_file(p, ctype or "application/octet-stream")

    def _handle_export_main(self, data):
        src = (data.get("srcDir") or data.get("dir") or "").strip()
        out = (data.get("outDir") or data.get("out") or "").strip()
        http_base = (data.get("httpBase") or data.get("base") or "http://192.168.1.118/data/www/game/test").strip().rstrip("/")
        version = data.get("version")
        try:
            version = int(version) if version not in (None, "") else 0
        except Exception:
            version = 0

        if not src or not out:
            self._json({"error": "missing srcDir/outDir"}, 400)
            return
        src_p = Path(src)
        out_p = Path(out)
        if not src_p.exists() or not src_p.is_dir():
            self._json({"error": f"src not found: {src}"}, 404)
            return

        images = scan_images(src_p)
        # load tags
        tag_file = find_tags_file(src_p)
        records: list[dict[str, Any]] = []
        if tag_file and tag_file.exists():
            raw = load_tags_file(tag_file)
            recs, _ = normalize_tags_records(raw, src_p)
            records = recs

        levels = build_main_levels(records, images, src_p, http_base)

        # auto bump version if not provided or 0
        if version <= 0:
            # try read existing main.json version
            existing_main = out_p / "main.json"
            if existing_main.exists():
                try:
                    ej = json.loads(existing_main.read_text(encoding="utf-8"))
                    version = int(ej.get("version", 0)) + 1
                except Exception:
                    version = 101
            else:
                version = 101
            # fallback to max order+1
            if not version:
                version = max((lv["order"] for lv in levels), default=100) + 1

        payload = {
            "version": version,
            "updatedAt": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat().replace("+00:00", "Z"),
            "levels": [{k: v for k, v in lv.items() if not k.startswith("_")} for lv in levels],
        }

        # ensure out dirs
        out_p.mkdir(parents=True, exist_ok=True)
        main_dir = out_p / "main"
        main_dir.mkdir(parents=True, exist_ok=True)

        # write main.json atomically
        main_json = out_p / "main.json"
        tmp = main_json.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(main_json)

        # copy images
        copied = 0
        errors: list[str] = []
        for p in images:
            try:
                dst = main_dir / p.name
                # avoid self-copy
                if p.resolve() == dst.resolve():
                    continue
                shutil.copy2(p, dst)
                copied += 1
            except Exception as e:
                errors.append(f"{p.name}: {e}")

        # optionally update manifest.json version if present
        manifest = out_p / "manifest.json"
        manifest_note = None
        if manifest.exists():
            try:
                mj = json.loads(manifest.read_text(encoding="utf-8"))
                if "modules" in mj and "main" in mj["modules"]:
                    mj["modules"]["main"]["version"] = version
                    mj["modules"]["main"]["url"] = f"{http_base}/main.json"
                    mj["updatedAt"] = payload["updatedAt"]
                    tmp2 = manifest.with_suffix(".json.tmp")
                    tmp2.write_text(json.dumps(mj, ensure_ascii=False, indent=2), encoding="utf-8")
                    tmp2.replace(manifest)
                    manifest_note = f"manifest.json main.version -> {version}"
            except Exception as e:
                manifest_note = f"manifest update failed: {e}"

        self._json({
            "ok": True,
            "mainJson": str(main_json.resolve()),
            "version": version,
            "total": len(levels),
            "copied": copied,
            "errors": errors,
            "manifest": manifest_note,
            "levelsPreview": payload["levels"][:3],
        })

    def _handle_export_events(self, data):
        # Minimal stub for prototype: create events.json with provided events
        out = (data.get("outDir") or "").strip()
        http_base = (data.get("httpBase") or "http://192.168.1.118/data/www/game/test").strip().rstrip("/")
        events = data.get("events") or []
        if not out:
            self._json({"error": "missing outDir"}, 400)
            return
        out_p = Path(out)
        out_p.mkdir(parents=True, exist_ok=True)
        events_dir = out_p / "events"
        events_dir.mkdir(parents=True, exist_ok=True)

        # For each event, if type zip and srcDir provided, zip images
        for ev in events:
            if not isinstance(ev, dict):
                continue
            eid = ev.get("id") or "event"
            typ = ev.get("type", "zip")
            src = ev.get("srcDir")
            if typ == "zip" and src:
                src_p = Path(src)
                if src_p.exists():
                    zip_path = events_dir / f"{eid}.zip"
                    import zipfile
                    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
                        for p in scan_images(src_p):
                            zf.write(p, arcname=p.name)
                    # auto set zipUrl if missing
                    if not ev.get("zipUrl"):
                        ev["zipUrl"] = f"{http_base}/events/{eid}.zip"
                    # coverUrl auto
                    if not ev.get("coverUrl"):
                        # pick first image as cover
                        imgs = scan_images(src_p)
                        if imgs:
                            ev["coverUrl"] = f"{http_base}/events/{imgs[0].name}"

        out_json = events_dir / "events.json"
        tmp = out_json.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(events, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(out_json)

        self._json({"ok": True, "file": str(out_json.resolve()), "count": len(events)})

    def _handle_export_daily(self, data):
        src = (data.get("srcDir") or "").strip()
        out = (data.get("outDir") or "").strip()
        month = (data.get("month") or data.get("YYYYMM") or "").strip()
        if not src or not out or not month:
            self._json({"error": "missing srcDir/outDir/month (YYYYMM)"}, 400)
            return
        src_p = Path(src)
        out_p = Path(out) / "daily"
        out_p.mkdir(parents=True, exist_ok=True)
        if not __import__("re").match(r"^\d{6}$", month):
            self._json({"error": "month must be YYYYMM"}, 400)
            return
        images = scan_images(src_p)
        import zipfile
        zip_path = out_p / f"{month}.zip"
        # Sort and rename to YYYYMMDD.webp sequentially
        images_sorted = sorted(images, key=lambda p: p.name.lower())
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for idx, p in enumerate(images_sorted, start=1):
                # For prototype, map to YYYYMMDD = YYYYMM + DD
                dd = f"{idx:02d}"
                # If image already named YYYYMMDD, keep it
                import re
                m = re.match(r"^(\d{8})\.", p.name)
                if m:
                    arc = p.name
                else:
                    # preserve ext as webp if original not webp? keep original ext per spec but daily uses webp/jpg/png both ok
                    ext = p.suffix.lower()
                    if ext not in (".webp", ".jpg", ".jpeg", ".png"):
                        ext = ".webp"
                    arc = f"{month}{dd}{ext}"
                zf.write(p, arcname=arc)

        self._json({"ok": True, "zip": str(zip_path.resolve()), "count": len(images_sorted)})


def main():
    ap = argparse.ArgumentParser(description="Content Packaging Studio")
    ap.add_argument("--port", type=int, default=5173, help="port (default 5173)")
    ap.add_argument("--host", default="127.0.0.1", help="bind host (default 127.0.0.1, use 0.0.0.0 to expose)")
    ap.add_argument("--open", action="store_true", help="auto open browser")
    ap.add_argument("--dir", type=Path, default=Path(__file__).parent, help="serve dir (default scripts/packaging)")
    args = ap.parse_args()

    Handler.serve_dir = args.dir.resolve()
    if not (Handler.serve_dir / "index.html").exists():
        print(f"index.html not found in {Handler.serve_dir}", file=sys.stderr)
        sys.exit(1)

    addr = (args.host, args.port)
    httpd = HTTPServer(addr, Handler)
    url = f"http://{args.host}:{args.port}/"
    print(f"Content Studio serving {Handler.serve_dir}")
    print(f" -> {url}")
    print(f" PIL available: {HAS_PIL} (pip install Pillow for thumbnails)")
    print(" Press Ctrl+C to stop")
    if args.open:
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")
        httpd.server_close()


if __name__ == "__main__":
    main()
