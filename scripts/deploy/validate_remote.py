#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
validate_remote.py — 远端 URL / 代理连通全链路巡检（发布后执行）

验证对象：github.com/mcxiaoke/jigsaw-data（master + Release v0.1.0）

通道：
  repo 文件通道    raw 直连 / jsDelivr / gh 代理(候选列表，域名易漂移，可配)
  release 通道     官方 github.com 直连 / gh 代理
行为：
  1) 全量资源 URL 逐条请求（并发 8，8s 超时），输出每通道成功率与延迟分布；
  2) 直连通道下载全部 11 个 zip 并校验 sha256 == index.json zipSha256、条目数一致；
  3) 输出 JSON 报告到 <build>/verify_report.json 并打印摘要。

用法：python scripts/deploy/validate_remote.py
退出码：0 = 至少一个 repo 通道与一个 release 通道可用；1 = 全部失败。
"""

from __future__ import annotations

import concurrent.futures as cf
import hashlib
import json
import sys
import time
import zipfile
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT))

import requests  # noqa: E402

OUT = Path(r"C:\Home\Temp\jigsawdata_build\out")
REPO = "mcxiaoke/jigsaw-data"
BRANCH = "master"
TAG = "v0.1.0"
RAW_BASE = f"https://raw.githubusercontent.com/{REPO}/{BRANCH}"
RELEASE_BASE = f"https://github.com/{REPO}/releases/download/{TAG}"
GH_PROXY_HOSTS = ["ghfast.top", "gh-proxy.com", "ghproxy.net",
                  "mirror.ghproxy.com", "ghproxy.com"]
TIMEOUT = 8
UA = {"User-Agent": "jigsaw-data-validator/1.0"}


def repo_rel_paths() -> list[str]:
    """仓库内应存在的相对路径清单（依据本地 out 结构，zip 目录除外）"""
    rels: list[str] = []
    skip_dirs = {"zips", "packs"}
    for p in sorted(OUT.rglob("*")):
        if p.is_file() and p.suffix != ".zip":
            parts = p.relative_to(OUT).parts
            if any(s in skip_dirs for s in parts):
                continue
            rels.append(p.relative_to(OUT).as_posix())
    return rels


def fetch(url: str, method: str = "GET", read: int = 4096) -> tuple[int, float, str, bytes | None]:
    t0 = time.time()
    try:
        if method == "HEAD":
            r = requests.head(url, headers=UA, timeout=TIMEOUT, allow_redirects=True)
            return r.status_code, time.time() - t0, r.url, None
        r = requests.get(url, headers=UA, timeout=TIMEOUT, stream=True)
        body = None
        if read:
            it = r.iter_content(read)
            body = next(it, b"")
            r.close()
        return r.status_code, time.time() - t0, r.url, body
    except Exception as e:
        return 0, time.time() - t0, f"ERR:{type(e).__name__}", None


def check(url: str) -> tuple[bool, float]:
    """HEAD 优先，405/不允许则降级 GET 探测"""
    code, ms, _u, _b = fetch(url, "HEAD")
    if code in (0, 405, 403, 501):
        code2, ms2, _u2, _b2 = fetch(url, "GET", read=1024)
        if code2 > 0:
            return code2 < 400, ms2
    return 200 <= code < 400, ms


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        while chunk := f.read(1 << 16):
            h.update(chunk)
    return h.hexdigest()


def zip_entries(p: Path) -> list[str]:
    with zipfile.ZipFile(p) as zf:
        return sorted(zf.namelist())


def main() -> int:
    rels = repo_rel_paths()
    plan = json.loads((OUT.parent / "publish_plan.json").read_text(encoding="utf-8"))
    assets = plan["assets"]  # 相对 out，如 daily/zips/202607.zip
    zip_map = {}
    for a in assets:
        p = OUT / a
        zip_map[p.name] = p  # name -> local path（用于 hash 对照）
    print(f"repo 文件清单 {len(rels)} 项；zip 资产 {len(zip_map)} 个\n", flush=True)

    repo_channels = {
        "raw": lambda rel: f"{RAW_BASE}/{rel}",
        "jsdelivr": lambda rel: f"https://cdn.jsdelivr.net/gh/{REPO}@{BRANCH}/{rel}",
    }
    for h in GH_PROXY_HOSTS:
        repo_channels[f"proxy:{h}"] = (lambda hh: (lambda rel: f"https://{hh}/{RAW_BASE}/{rel}"))(h)

    release_channels = {
        "direct": lambda name: f"{RELEASE_BASE}/{name}",
    }
    for h in GH_PROXY_HOSTS:
        release_channels[f"proxy:{h}"] = (lambda hh: (lambda name: f"https://{hh}/{RELEASE_BASE}/{name}"))(h)

    report: dict = {"repo": REPO, "branch": BRANCH, "tag": TAG,
                    "channels": {}, "release_sha256_check": {}}

    def _run_channel(name: str, urls: list[str]) -> dict:
        ok = 0
        lat: list[float] = []
        samples: list[dict] = []
        with cf.ThreadPoolExecutor(max_workers=8) as ex:
            for url in urls:
                fut = ex.submit(check, url)
                good, ms = fut.result()
                if good:
                    ok += 1
                    lat.append(ms)
                samples.append({"url": url, "ok": good, "ms": round(ms, 1)})
        n = len(urls)
        return {"ok": ok, "total": n, "rate": round(ok / n, 3),
                "avg_ms": round(sum(lat) / len(lat), 1) if lat else None,
                "p50_ms": round(sorted(lat)[len(lat) // 2], 1) if lat else None,
                "samples": samples}

    # 1) repo 文件通道
    for name, build in repo_channels.items():
        urls = [build(rel) for rel in rels]
        res = _run_channel(name, urls)
        report["channels"][f"repo:{name}"] = {k: v for k, v in res.items() if k != "samples"}
        report["channels"][f"repo:{name}"]["failed"] = [
            s["url"] for s in res["samples"] if not s["ok"]][:8]
        print(f"[repo:{name}] {res['ok']}/{res['total']}  "
              f"avg={res['avg_ms']}ms p50={res['p50_ms']}ms", flush=True)

    # 2) release 通道（HEAD）
    names = sorted(zip_map)
    for name, build in release_channels.items():
        res = _run_channel(name, [build(n) for n in names])
        report["channels"][f"release:{name}"] = {k: v for k, v in res.items() if k != "samples"}
        report["channels"][f"release:{name}"]["failed"] = [
            s["url"] for s in res["samples"] if not s["ok"]][:8]
        print(f"[release:{name}] {res['ok']}/{res['total']}  "
              f"avg={res['avg_ms']}ms p50={res['p50_ms']}ms", flush=True)

    # 3) 直连下载 zip 全量校验（sha256 + 条目）
    print("\n下载直连 release zip 校验 sha256...", flush=True)
    d = OUT / ".dl_check"
    d.mkdir(exist_ok=True)
    all_hash_ok = True
    for n in names:
        local = zip_map[n]
        dst = d / n
        try:
            r = requests.get(f"{RELEASE_BASE}/{n}", headers=UA, timeout=60)
            if r.status_code != 200:
                report["release_sha256_check"][n] = {"error": f"HTTP {r.status_code}"}
                all_hash_ok = False
                continue
            dst.write_bytes(r.content)
            got = sha256_file(dst)
        except Exception as e:
            report["release_sha256_check"][n] = {"error": str(e)}
            all_hash_ok = False
            continue
        # 期望 hash 从对应 index.json 读取
        want = _expected_hash(n)
        entries_ok = len(zip_entries(dst)) == _expected_count(n, local)
        ok_hash = want is not None and got == want
        if not (ok_hash and entries_ok):
            all_hash_ok = False
        report["release_sha256_check"][n] = {
            "bytes": dst.stat().st_size, "sha256": got, "expect": want,
            "hash_ok": ok_hash, "entries_ok": entries_ok}
        print(f"  {n}: sha256 {'OK' if ok_hash else 'MISMATCH'} "
              f"entries {'OK' if entries_ok else 'MISMATCH'}", flush=True)

    (OUT.parent / "verify_report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    repo_ok = any(v["rate"] == 1.0 for k, v in report["channels"].items() if k.startswith("repo:"))
    rel_ok = any(v["rate"] == 1.0 for k, v in report["channels"].items() if k.startswith("release:"))
    print(f"\n✅ 报告已写入 verify_report.json | repo 全通通道存在: {repo_ok} | "
          f"release 全通通道存在: {rel_ok} | zip sha 全对: {all_hash_ok}")
    return 0 if (repo_ok and rel_ok and all_hash_ok) else 1


def _expected_hash(zip_name: str) -> str | None:
    """从本地 index.json 中查找 zip 的 zipSha256"""
    for module, key in (("daily", "month"), ("events", "id"), ("collections", "id")):
        idx = json.loads((OUT / module / "index.json").read_text(encoding="utf-8"))
        for it in idx.get("items", []):
            if key == "month":
                if f"{it['month']}.zip" == zip_name:
                    return it.get("zipSha256")
            elif f"{it['id']}.zip" == zip_name:
                return it.get("zipSha256")
    return None


def _expected_count(zip_name: str, local: Path) -> int:
    """zip 条目数预期：daily 按月份天数，pack 按 index totalCount"""
    for module, key in (("daily", "month"), ("events", "id"), ("collections", "id")):
        idx = json.loads((OUT / module / "index.json").read_text(encoding="utf-8"))
        for it in idx.get("items", []):
            if key == "month":
                if f"{it['month']}.zip" == zip_name:
                    return it.get("totalCount", 0)
            elif f"{it['id']}.zip" == zip_name:
                return it.get("totalCount", 0)
    return 0


if __name__ == "__main__":
    sys.exit(main())
