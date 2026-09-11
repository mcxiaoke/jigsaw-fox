#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ledger.py — 素材发布台账（文件级指纹、变化清单、按次运行记录）

背景
----
publish 侧原先只有 stdout 打印，进程结束即丢失，没有任何留存。
本模块在 **jigsaw-data 仓库**内维护台账（而非主项目的 temp/），因为它会随
Step 5 的 `git push` 入库，天然持久化且可跨机器共享，同时充当下次运行的
「变化检测基线」。

台账布局（均位于 jigsaw-data/.publish/，刻意放在 release/ 之外，
以免被 prepare 的整目录重建清掉）
------------------------------------------------------------------
  run.json           当前进行中的运行记录，每个子命令结束后增量更新
  latest.json        最近一次「已完成」发布的完整快照（下次 diff 的基线）
  history.ndjson     每次完成发布追加一行摘要（审计留痕，约 300B/行）
  runs/<runId>.json  详情归档，按 PUBLISH_HISTORY_KEEP 条数滚动保留

双层指纹（回答「复制到 release/ 后内容被改过，怎么比对」）
--------------------------------------------------------
发布流水线会对产物做两处修改：
  1. daily/events/collections/index.json —— 注入 zipKey / zipUrls；
  2. manifest.json —— 按 index.json 字节流重写 modules.*.hash。
因此「源」与「发布产物」并不逐字节相同。这里同时记录两层指纹：

  sourceFingerprint   输入源 Output 那份未被改动的原始文件的聚合摘要。
                      用于归因：变了说明 Studio 重新导出过。
  publishedFiles      真正被上传的那棵树（release/）的逐文件 {size, sha256}。
                      用于判定"远端会不会真的变化"，也是下一次 diff 的基线。

判定逻辑：
  - publishedFiles 无变化  => 远端不需要更新，拦下来提示无需重新发布（除非 --force）
  - 仅 sourceFingerprint 变、publishedFiles 未变 => 不可能（变换是确定性的），
    一旦出现说明注入逻辑变了，需要人工确认
  - 两者都变 => 数据源变化，正常发布
"""

from __future__ import annotations

import hashlib
import json
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

# 滚动保留的运行详情数量
PUBLISH_HISTORY_KEEP = 50


def now_id() -> str:
    return time.strftime("%Y%m%d-%H%M%S")


def _sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tree_files(root: Path, keys: list[str] | None = None) -> dict[str, dict]:
    """对目录树（或指定的 key 列表）逐文件算 size + sha256。返回 {key: {size, sha256}}。"""
    root = Path(root)
    if keys is None:
        keys = sorted(
            f.relative_to(root).as_posix() for f in root.rglob("*") if f.is_file()
        )
    out: dict[str, dict] = {}

    def _one(k: str):
        f = root / k
        st = f.stat()
        return k, {"size": st.st_size, "sha256": _sha256_file(f)}

    with ThreadPoolExecutor(max_workers=8) as ex:
        for k, meta in ex.map(_one, keys):
            out[k] = meta
    return dict(sorted(out.items()))


def source_fingerprint(source_root: Path, keys: list[str]) -> tuple[str, int]:
    """对「未被改动的源」做聚合摘要（不落地逐文件清单，避免体积膨胀）。

    算法：按 key 排序后，把 `key\\tsize\\tsha256\\n` 逐行拼起来再取 sha256。
    返回 (聚合摘要, 文件数)。
    """
    root = Path(source_root)
    files = tree_files(root, keys)
    buf = [f"{k}\t{m['size']}\t{m['sha256']}\n" for k, m in files.items()]
    return hashlib.sha256("".join(buf).encode("utf-8")).hexdigest(), len(files)


def diff_files(
    prev: dict[str, dict], now: dict[str, dict]
) -> dict[str, list[str]]:
    """对比两次发布产物，返回 {added, removed, changed, unchanged} 的 key 列表。"""
    pk, nk = set(prev), set(now)
    changed = sorted(k for k in pk & nk if prev[k]["sha256"] != now[k]["sha256"])
    return {
        "added": sorted(nk - pk),
        "removed": sorted(pk - nk),
        "changed": changed,
        "unchanged": sorted((pk & nk) - set(changed)),
    }


# ------------------------------------------------------------------ 读写
def pub_dir(repo: Path) -> Path:
    return Path(repo) / ".publish"


def _write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
    )


def load_latest(repo: Path) -> dict | None:
    p = pub_dir(repo) / "latest.json"
    if not p.exists():
        return None
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else None
    except Exception:
        return None


def start_run(repo: Path, base: dict) -> dict:
    """初始化本次运行记录，写入 .publish/run.json。"""
    rec = {**base, "runId": now_id(), "startedAt": time.strftime("%Y-%m-%dT%H:%M:%S")}
    _write_json(pub_dir(repo) / "run.json", rec)
    return rec


def update_run(repo: Path, run_id: str, patch: dict) -> dict | None:
    p = pub_dir(repo) / "run.json"
    if not p.exists():
        return None
    try:
        rec = json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None
    if rec.get("runId") != run_id:
        return None
    steps = rec.setdefault("steps", {})
    for k, v in patch.items():
        steps[k] = v
    rec["updatedAt"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    _write_json(p, rec)
    return rec


def finish_run(repo: Path, run_id: str) -> Path | None:
    """把 run.json 归档为 latest.json + runs/<runId>.json，并向 history 追加一行。"""
    p = pub_dir(repo) / "run.json"
    if not p.exists():
        return None
    rec = json.loads(p.read_text(encoding="utf-8"))
    if rec.get("runId") != run_id:
        return None
    rec["finishedAt"] = time.strftime("%Y-%m-%dT%H:%M:%S")

    d = pub_dir(repo)
    _write_json(d / "latest.json", rec)
    _write_json(d / "runs" / f"{run_id}.json", rec)

    changes = rec.get("changes") or {}
    counts = changes.get("counts") or {}
    summary = {
        "ts": rec["finishedAt"],
        "runId": run_id,
        "mainVersion": rec.get("mainVersion"),
        "files": rec.get("publishedFileCount"),
        "added": counts.get("added", 0),
        "removed": counts.get("removed", 0),
        "changed": counts.get("changed", 0),
        "sourceChanged": rec.get("sourceChanged"),
        "verify": (rec.get("steps") or {}).get("promote", {}).get("rc", None),
    }
    with (d / "history.ndjson").open("a", encoding="utf-8") as f:
        f.write(json.dumps(summary, ensure_ascii=False) + "\n")

    _prune_runs(d)
    return d / "latest.json"


def _prune_runs(d: Path) -> None:
    runs = sorted((d / "runs").glob("*.json")) if (d / "runs").exists() else []
    if len(runs) <= PUBLISH_HISTORY_KEEP:
        return
    for old in runs[: len(runs) - PUBLISH_HISTORY_KEEP]:
        try:
            old.unlink()
        except Exception:
            pass


def print_change_report(changes: dict, limit: int = 20) -> None:
    """打印可读性变化报告（默认最多列出 20 项，超出折叠计数）。"""
    c = changes["counts"]
    print(
        f"[ledger] 相对上次发布: +{c['added']} 新增 / "
        f"-{c['removed']} 删除 / ~{c['changed']} 内容变更 / "
        f"{c['unchanged']} 未变"
    )
    for op, label in (("added", "新增"), ("removed", "删除"), ("changed", "变更")):
        items = changes[op]
        if not items:
            continue
        print(f"  [{label}] {len(items)} 项:")
        for k in items[:limit]:
            print(f"      {k}")
        if len(items) > limit:
            print(f"      ... 其余 {len(items) - limit} 项省略")
