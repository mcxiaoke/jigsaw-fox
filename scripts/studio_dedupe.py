#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio_dedupe.py — 基于 SHA-256 的内容级重复文件清理（studio 素材库去重）

核心行为
--------
1. 判定重复组来源：
   - 若 <SRC>/.studio/cache/studio.db 存在（即该目录是 studio 工作区），
     直接从缓存库 file_cache 表读取「同 hash、>=2 个路径」的重复组；
     读取后会对磁盘做一致性校验（mtime/size 未变则信任缓存，变化则现场重算），
     避免陈旧缓存造成误判。
   - 否则现场递归计算 SHA-256 并聚合重复组。
2. 每个「完全重复组」仅保留一个文件（默认保留相对路径最短者），
   其余候选项会被列出；只有加 --apply 才真正删除。
3. 删除方式默认软删除：移入 <SRC>/<Deleted>/_dedupe/<时间戳>/<相对路径>，
   可手工找回；--permanent 才物理删除（需同时加 --yes）。

安全约束
--------
- 默认 dry-run（只预览、零改动）。
- 只删除 <SRC> 内的文件；扫描自动忽略 .studio / Deleted / temp / 隐藏目录。
- --permanent 必须显式 --yes，否则拒绝执行。

用法
----
  # 预览（推荐先跑，看看将保留/删除哪些）
  python scripts/studio_dedupe.py "F:/Pictures/JigsawGame/Source"

  # 确认后软删除（移入 Deleted/_dedupe/）
  python scripts/studio_dedupe.py "F:/Pictures/JigsawGame/Source" --apply

  # 保留最旧的一份，并输出 JSON 报告
  python scripts/studio_dedupe.py <SRC> --keep oldest --apply --report temp/dedupe.json

  # 强制现场计算（即使存在 .studio 缓存库）
  python scripts/studio_dedupe.py <SRC> --no-cache
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import shutil
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

# --------------------------------------------------------------------------
# Windows 控制台 UTF-8 修正
# --------------------------------------------------------------------------
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

# 让 scripts/ 下的脚本能 import 到仓库根的 studio 包
REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from studio.core.scanner import (  # noqa: E402
    IMAGE_EXTS,
    compute_file_sha256,
    find_duplicate_groups,
    scan_images,
)

# 目录级忽略（大小写不敏感）；与 scanner.IGNORE_DIRS 保持一致并追加 studio 私有目录
IGNORE_DIRS = {
    ".git", ".svn", ".idea", ".vscode", "__pycache__",
    "node_modules", "temp", "tmp", "deleted", ".studio",
}

KEEP_MODES = ("shortest", "oldest", "newest")


# --------------------------------------------------------------------------
# 工具函数
# --------------------------------------------------------------------------

def _norm_rel(p: str) -> str:
    return str(p).replace("\\", "/")


def _is_ignored(rel: str, delete_dir_name: str) -> bool:
    """判断相对路径是否应被忽略（隐藏目录 / 忽略名单 / 回收目录）。"""
    parts = [seg.lower() for seg in Path(rel).parts]
    if not parts:
        return True
    if delete_dir_name.lower() in parts:
        return True
    for seg in parts:
        if seg.startswith("."):
            return True
    # 末段是文件名，不参与目录级忽略判断
    return any(seg in IGNORE_DIRS for seg in parts[:-1])


def _scan_all_files(root: Path, delete_dir_name: str) -> list[Path]:
    """递归收集根目录下全部（非忽略目录内的）文件。"""
    out: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [
            d for d in dirnames
            if not d.startswith(".") and d.lower() not in IGNORE_DIRS
            and d.lower() != delete_dir_name.lower()
        ]
        base = Path(dirpath)
        for f in filenames:
            if f.startswith("."):
                continue
            out.append(base / f)
    return sorted(out, key=lambda p: p.relative_to(root).as_posix().lower())


def _unique_path(p: Path) -> Path:
    """若目标已存在，追加 .1 / .2 ... 直到不冲突。"""
    if not p.exists():
        return p
    stem, suffix, parent = p.stem, p.suffix, p.parent
    i = 1
    while True:
        cand = parent / f"{stem}.{i}{suffix}"
        if not cand.exists():
            return cand
        i += 1


# --------------------------------------------------------------------------
# 重复组来源 A：studio 缓存库
# --------------------------------------------------------------------------

def _groups_from_cache(root: Path, args: argparse.Namespace):
    """
    从 .studio/cache/studio.db 的 file_cache 表读取重复组，并做磁盘一致性校验。

    返回 (groups, cache, stats)：
      groups: {hash: [item, ...]}，item = {rel, abs, hash, size, mtime}
      cache : CacheDB 实例（供删除后同步缓存），失败时为 None
      stats : {candidates, trusted, recomputed, missing}
    """
    from studio.core.cache_db import CacheDB

    cache = CacheDB(root)
    entries = cache.load_file_cache()  # rel -> (mtime, size, hash, width, height, format)

    by_hash: dict[str, list[str]] = {}
    meta: dict[str, tuple[int, int, str]] = {}
    for rel, (mtime, size, h, _w, _ht, _fmt) in entries.items():
        rel_n = _norm_rel(rel)
        hh = (h or "").strip().lower()
        if not hh:
            continue
        if _is_ignored(rel_n, args.delete_dir):
            continue
        if not args.all_files and Path(rel_n).suffix.lower() not in IMAGE_EXTS:
            continue
        by_hash.setdefault(hh, []).append(rel_n)
        meta[rel_n] = (int(mtime), int(size), hh)

    candidates = {h: rels for h, rels in by_hash.items() if len(set(rels)) >= 2}
    if not candidates:
        return {}, cache, {"candidates": 0, "trusted": 0, "recomputed": 0, "missing": 0}

    # 收集待校验成员（去重）
    to_check = sorted({r for rels in candidates.values() for r in rels})

    stats = {"candidates": len(to_check), "trusted": 0, "recomputed": 0, "missing": 0}
    items: list[dict[str, Any]] = []
    need_hash: list[tuple[str, Path]] = []

    for rel in to_check:
        abs_p = root / rel
        c_mtime, c_size, c_hash = meta[rel]
        try:
            st = abs_p.stat()
        except OSError:
            stats["missing"] += 1
            continue
        if not abs_p.is_file():
            stats["missing"] += 1
            continue
        if (not args.no_verify) and st.st_mtime_ns == c_mtime and st.st_size == c_size:
            stats["trusted"] += 1
            items.append({
                "path": rel, "rel": rel, "abs": str(abs_p), "hash": c_hash,
                "size": st.st_size, "mtime": st.st_mtime_ns,
            })
        else:
            need_hash.append((rel, abs_p))

    # 对 mtime/size 变化（或禁用校验）的成员现场重算 SHA-256
    if need_hash:
        def _work(pair: tuple[str, Path]):
            rel, abs_p = pair
            try:
                digest = compute_file_sha256(abs_p)
                st = abs_p.stat()
                return rel, digest, st.st_size, st.st_mtime_ns
            except Exception as e:  # noqa: BLE001
                print(f"  [warn] 重算失败，跳过: {rel} ({e})", file=sys.stderr)
                return rel, "", 0, 0

        workers = max(1, min(args.workers, len(need_hash)))
        with ThreadPoolExecutor(max_workers=workers) as pool:
            for rel, digest, size, mtime in pool.map(_work, need_hash):
                if not digest:
                    stats["missing"] += 1
                    continue
                stats["recomputed"] += 1
                items.append({
                    "path": rel, "rel": rel, "abs": str(root / rel), "hash": digest,
                    "size": size, "mtime": mtime,
                })

    groups = find_duplicate_groups(items)
    return groups, cache, stats


# --------------------------------------------------------------------------
# 重复组来源 B：现场扫描计算
# --------------------------------------------------------------------------

def _groups_from_scan(root: Path, args: argparse.Namespace):
    """现场递归计算 SHA-256 并聚合重复组。返回 (groups, None, stats)。"""
    if args.all_files:
        files = _scan_all_files(root, args.delete_dir)
    else:
        files = scan_images(root)

    stats = {"candidates": len(files), "trusted": 0, "recomputed": 0, "missing": 0}
    if not files:
        return {}, None, stats

    def _work(p: Path):
        try:
            digest = compute_file_sha256(p)
            st = p.stat()
            return p, digest, st.st_size, st.st_mtime_ns
        except Exception:  # noqa: BLE001
            return p, "", 0, 0

    items: list[dict[str, Any]] = []
    workers = max(1, min(args.workers, len(files)))
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for p, digest, size, mtime in pool.map(_work, files):
            if not digest:
                stats["missing"] += 1
                continue
            rel = p.relative_to(root).as_posix()
            stats["recomputed"] += 1
            items.append({
                "path": rel, "rel": rel, "abs": str(p), "hash": digest, "size": size, "mtime": mtime,
            })

    groups = find_duplicate_groups(items)
    return groups, None, stats


# --------------------------------------------------------------------------
# 计划构建与展示
# --------------------------------------------------------------------------

def _keep_key(item: dict[str, Any], mode: str):
    rel = item["rel"]
    if mode == "oldest":
        return (item.get("mtime") or 0, len(rel), rel.lower())
    if mode == "newest":
        return (-(item.get("mtime") or 0), len(rel), rel.lower())
    # shortest（默认）：相对路径字符数最短 → 同长按字典序
    return (len(rel), rel.lower())


def _build_plan(groups: dict[str, list[dict[str, Any]]], keep_mode: str):
    plans: list[dict[str, Any]] = []
    for h, members in groups.items():
        members = sorted(members, key=lambda it: it["rel"].lower())
        if len(members) < 2:
            continue
        idx = min(range(len(members)), key=lambda i: _keep_key(members[i], keep_mode))
        keep = members[idx]
        victims = members[:idx] + members[idx + 1:]
        plans.append({
            "hash": h,
            "size": keep.get("size", 0),
            "keep": keep,
            "delete": victims,
            "reclaim": keep.get("size", 0) * len(victims),
        })
    # 组内删除数多的排前面，便于人工优先复核
    plans.sort(key=lambda p: (-len(p["delete"]), p["keep"]["rel"].lower()))
    return plans


def _fmt_size(n: int) -> str:
    v = float(n)
    for unit in ("B", "KB", "MB", "GB"):
        if v < 1024 or unit == "GB":
            return f"{v:.1f}{unit}" if unit != "B" else f"{int(v)}B"
        v /= 1024
    return f"{v:.1f}GB"


def _print_plan(plans, root: Path, source: str, keep_mode: str, pending_apply: bool) -> None:
    n_groups = len(plans)
    n_del = sum(len(p["delete"]) for p in plans)
    reclaim = sum(p["reclaim"] for p in plans)

    mode_line = ("待执行（--apply，以下即将被删除项）" if pending_apply
                 else "预览（未改动任何文件）")
    print()
    print("=" * 92)
    print(f"  源目录     : {root}")
    print(f"  重复组来源 : {source}")
    print(f"  保留策略   : {keep_mode}")
    print(f"  重复组     : {n_groups}   待删除文件: {n_del}   可回收: {_fmt_size(reclaim)}")
    print(f"  执行模式   : {mode_line}")
    print("=" * 92)

    if not plans:
        print("\n  没有发现内容完全重复的文件组。\n")
        return

    for i, pl in enumerate(plans, 1):
        n = len(pl["delete"]) + 1
        print(f"\n  [{i}/{n_groups}] hash={pl['hash'][:16]}…  副本 {n} 份  单份 {_fmt_size(pl['size'])}")
        print(f"      KEEP  {pl['keep']['rel']}")
        for v in pl["delete"]:
            print(f"      DEL   {v['rel']}")
    print()


# --------------------------------------------------------------------------
# 执行删除
# --------------------------------------------------------------------------

def _execute(plans, root: Path, args: argparse.Namespace):
    """按计划删除。返回 (moved_rels, errors, trash_root)。"""
    ts = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    trash_root = root / args.delete_dir / "_dedupe" / ts

    moved: list[str] = []
    errors: list[tuple[str, str]] = []

    for pl in plans:
        for it in pl["delete"]:
            abs_p = Path(it["abs"])
            # 安全兜底：目标必须位于源目录之内
            try:
                abs_p.resolve().relative_to(root.resolve())
            except ValueError:
                errors.append((it["rel"], "路径越界，拒绝删除"))
                continue
            try:
                if args.permanent:
                    abs_p.unlink()
                else:
                    dest = _unique_path(trash_root / it["rel"])
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    shutil.move(str(abs_p), str(dest))
                moved.append(it["rel"])
            except Exception as e:  # noqa: BLE001
                errors.append((it["rel"], str(e)))

    return moved, errors, trash_root


# --------------------------------------------------------------------------
# 主流程
# --------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(
        description="按 SHA-256 内容去重：同 hash 重复组只保留一份（默认预览，软删除）。",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("src", help="源素材目录（studio 工作区或普通目录）")
    ap.add_argument("--apply", action="store_true", help="真正执行删除；缺省仅预览")
    ap.add_argument("--permanent", action="store_true",
                    help="物理删除（默认软删除：移入 Deleted/_dedupe/时间戳/）")
    ap.add_argument("--yes", action="store_true", help="与 --permanent 搭配的二次确认")
    ap.add_argument("--keep", choices=KEEP_MODES, default="shortest",
                    help="每组保留哪个：shortest(默认)/oldest/newest")
    ap.add_argument("--no-cache", action="store_true",
                    help="忽略 .studio 缓存库，强制现场计算 SHA-256")
    ap.add_argument("--no-verify", action="store_true",
                    help="缓存库模式下跳过磁盘一致性校验（更快，但陈旧缓存可能误判）")
    ap.add_argument("--all-files", action="store_true",
                    help="不限于图片扩展名，对所有文件去重")
    ap.add_argument("--delete-dir", default="Deleted",
                    help="软删除回收目录名（默认 Deleted）")
    ap.add_argument("--workers", type=int, default=16, help="哈希计算并发线程数（默认 16）")
    ap.add_argument("--report", metavar="PATH", help="将去重计划/结果写入 JSON 报告")

    args = ap.parse_args()

    root = Path(args.src).expanduser().resolve()
    if not root.exists() or not root.is_dir():
        print(f"[error] 源目录不存在或不是目录: {root}", file=sys.stderr)
        return 2
    if root.parent == root:
        print("[error] 拒绝在文件系统根目录上执行去重。", file=sys.stderr)
        return 2
    if args.permanent and args.apply and not args.yes:
        print("[error] --permanent 为不可逆物理删除，必须同时加 --yes 才执行。", file=sys.stderr)
        return 2

    t0 = time.time()
    db_file = root / ".studio" / "cache" / "studio.db"

    cache = None
    stats: dict[str, int]
    if db_file.is_file() and not args.no_cache:
        source = f"缓存库 {db_file.relative_to(root).as_posix()}"
        print(f"[mode] 使用 studio 缓存库读取重复组: {db_file}")
        groups, cache, stats = _groups_from_cache(root, args)
        if stats["recomputed"] or stats["missing"]:
            print(f"[verify] 校验成员: 信任缓存 {stats['trusted']}，"
                  f"重算 {stats['recomputed']}，缺失 {stats['missing']}")
    else:
        reason = "--no-cache 指定" if args.no_cache else "未发现 .studio 缓存库"
        source = "现场计算 (SHA-256)"
        print(f"[mode] {reason}，现场扫描计算 SHA-256")
        groups, cache, stats = _groups_from_scan(root, args)

    plans = _build_plan(groups, args.keep)
    n_del = sum(len(p["delete"]) for p in plans)

    _print_plan(plans, root, source, args.keep, pending_apply=bool(args.apply and n_del))

    moved: list[str] = []
    errors: list[tuple[str, str]] = []
    trash_root: Path | None = None

    if args.apply and n_del:
        if args.permanent:
            print(f"  !! 物理删除 {n_del} 个文件（不可逆）…")
        else:
            print(f"  软删除：将 {n_del} 个文件移入 {args.delete_dir}/_dedupe/…")
        moved, errors, trash_root = _execute(plans, root, args)
        print(f"  完成：已处理 {len(moved)} 个，失败 {len(errors)} 个")
        if not args.permanent and trash_root is not None and moved:
            print(f"  回收位置（可手工找回）: {trash_root}")

        # 同步 studio 缓存库，摘除已删除条目
        if cache is not None and moved:
            try:
                cache.delete_files(moved)
                print(f"  已从缓存库摘除 {len(moved)} 条 file_cache 记录")
            except Exception as e:  # noqa: BLE001
                print(f"  [warn] 缓存库同步失败（不影响文件删除）: {e}", file=sys.stderr)

        # 记录 studio 审计流水
        if cache is not None:
            try:
                cache.workspace.record_audit(
                    action="dedupe_by_hash",
                    scope="source",
                    entity=str(root),
                    result="ok" if not errors else "partial",
                    detail=f"groups={len(plans)} deleted={len(moved)} errors={len(errors)}",
                    keep_policy=args.keep,
                    permanent=bool(args.permanent),
                    trash=str(trash_root) if trash_root else "",
                )
            except Exception:  # noqa: BLE001
                pass
    elif args.apply:
        print("  没有需要删除的文件，未做改动。")
    else:
        print("  以上为预览。确认无误后，加 --apply 执行（默认软删除）。")

    if errors:
        print("\n  失败明细:", file=sys.stderr)
        for rel, msg in errors:
            print(f"    - {rel}: {msg}", file=sys.stderr)

    elapsed = time.time() - t0
    print(f"\n  耗时 {elapsed:.1f}s")

    # 关闭缓存连接
    if cache is not None:
        try:
            cache.close()
        except Exception:  # noqa: BLE001
            pass

    if args.report:
        report = {
            "source": str(root),
            "group_source": source,
            "keep": args.keep,
            "applied": bool(args.apply and n_del),
            "permanent": bool(args.permanent),
            "deleted_dir": args.delete_dir,
            "trash_root": str(trash_root) if trash_root else "",
            "generated_at": dt.datetime.now().isoformat(timespec="seconds"),
            "elapsed_seconds": round(elapsed, 2),
            "stats": stats,
            "summary": {
                "groups": len(plans),
                "to_delete": n_del,
                "deleted": len(moved),
                "errors": len(errors),
                "reclaim_bytes": sum(p["reclaim"] for p in plans),
            },
            "groups": [
                {
                    "hash": p["hash"],
                    "size": p["size"],
                    "keep": p["keep"]["rel"],
                    "delete": [v["rel"] for v in p["delete"]],
                }
                for p in plans
            ],
            "errors": [{"path": r, "error": m} for r, m in errors],
        }
        outp = Path(args.report).expanduser()
        outp.parent.mkdir(parents=True, exist_ok=True)
        outp.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"  报告已写入: {outp}")

    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
