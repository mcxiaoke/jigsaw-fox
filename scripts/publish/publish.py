#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
publish.py — jigsaw-data 素材发布编排器（v2 唯一入口）

方案依据
--------
docs/assets-publish-workflow-v2-20260910.md

设计原则
--------
1. 同构目录，零路径改写：Studio 导出的 Output 结构即远端托管结构，zipUrl 恒为相对路径。
2. 预演前缀隔离：R2 上 _stage（测试预演）与 release（正式生产）两个顶层前缀，先预演后 promote。
3. 相对 URL + Release 备用镜像：index.json 保留相对 zipUrl，另注入 zipUrls 绝对地址做容灾兜底。
4. 备源先上、主源再切：先把新增 zip 传上 Gitee/GitHub Release，最后才做 R2 服务端 promote。
5. 单 master 分支 + 固定移动标签 assets。
6. 最小凭证依赖：JSON 缓存由 Cloudflare Cache Rule 绕过，流水线无需 CF API Token。

子命令
------
  prepare   白名单拷贝（排除 .git）-> 注入 zipUrls -> 重算模块 hash -> 本地硬门禁
  stage     rclone sync 本地 publishRoot -> r2:jigsaw-data/_stage
  verify    巡检（--env stage|prod）
  release   上传新增 zip 到 GitHub / Gitee Release（备源先行就位）
  promote   R2 桶内 Server-Side Copy _stage -> release，随后自动 verify --env prod
  all       prepare -> stage -> verify(stage) -> release -> promote(含 verify prod)
  git       提交并推送 jigsaw-data 的 json/webp（需显式调用，不并入 all）
  purge     极端情况手动清 Cloudflare 缓存（需 CF_API_TOKEN / CF_ZONE_ID）

用法
----
  python publish.py prepare
  python publish.py stage
  python publish.py verify --env stage
  python publish.py release
  python publish.py promote
  python publish.py all
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import posixpath
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from assetmap import load_channels, load_doc  # noqa: E402
import check_local  # noqa: E402
import ledger  # noqa: E402

# C:/Home/Projects/jigsawpuzzle  （scripts/publish/publish.py -> 上溯三级）
REPO_ROOT = HERE.parent.parent

# 需要注入 zip 兜底镜像的模块（均为 zip 型 index）
ZIP_MODULES = ("daily", "events", "collections")


# ------------------------------------------------------------------ 基础工具
def _run(cmd: list, extra_env: dict | None = None, **kw) -> int:
    cmd = [str(c) for c in cmd]
    print("+ " + " ".join(cmd), flush=True)
    env = dict(os.environ)
    if extra_env:
        env.update(extra_env)
    kw.setdefault("env", env)
    return subprocess.run(cmd, **kw).returncode


def _sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _is_hidden(rel: str) -> bool:
    """任何一级目录/文件名以 . 开头即视为隐藏（.git / .gitattributes / .DS_Store 等）。"""
    return any(part.startswith(".") for part in rel.split("/"))


def _ctx(doc: dict) -> tuple[Path, Path, Path]:
    d = doc["dist"]
    return Path(d["root"]), Path(d["repo"]), Path(d["publishRoot"])


def _mirror_channels(doc: dict):
    ids = doc.get("zipMirrorChannels") or []
    by_id = {c.id: c for c in load_channels()}
    chs = [by_id[i] for i in ids if i in by_id]
    if not chs:
        raise SystemExit("[FATAL] zipMirrorChannels 未配置或对应通道不存在")
    return chs


# ------------------------------------------------------- 台账（运行记录）
def _current_run(repo: Path) -> tuple[str | None, dict | None]:
    p = ledger.pub_dir(repo) / "run.json"
    if not p.exists():
        return None, None
    try:
        rec = json.loads(p.read_text(encoding="utf-8"))
        return rec.get("runId"), rec
    except Exception:
        return None, None


def _note(doc: dict, step: str, payload: dict) -> None:
    """把某一步的结果写进本次运行记录（无 run.json 时静默跳过）。"""
    repo = _ctx(doc)[1]
    run_id, _ = _current_run(repo)
    if run_id:
        ledger.update_run(repo, run_id, {step: payload})


def _remote_in_sync(doc: dict, publish_root: Path) -> bool:
    """远端生产区与本地产物是否一致（size 维度快速比对）。

    用于「内容无变化」时判断是否真的不需要重发——例如远端被清空、
    而本地台账仍记录着上次发布，这时仍必须重发。
    """
    d = doc["dist"]
    dst = f"{d['r2Remote']}/{d['releasePrefix']}"
    rc = subprocess.run(
        ["rclone", "check", str(publish_root), dst, "--size-only", "--quiet"],
        capture_output=True, text=True,
    )
    return rc.returncode == 0


# ------------------------------------------------------------------ prepare
def _source_files(dist: Path, doc: dict) -> list[str]:
    """按白名单枚举输入源文件（排除隐藏路径与 excludeNames），返回相对 POSIX key 列表。"""
    whitelist = doc["dist"]["whitelistTop"]
    excl = set(doc["dist"].get("excludeNames", []))
    keys: list[str] = []
    for top in whitelist:
        p = dist / top
        if not p.exists():
            raise SystemExit(f"[prepare][FATAL] 输入源缺失: {p}")
        if p.is_file():
            keys.append(top)
            continue
        for f in p.rglob("*"):
            if not f.is_file():
                continue
            rel = f.relative_to(dist).as_posix()
            if _is_hidden(rel):
                continue
            if any(part in excl for part in rel.split("/")):
                continue
            keys.append(rel)
    return sorted(keys)


def _copy_whitelist(dist: Path, publish_root: Path, keys: list[str]) -> None:
    if publish_root.exists():
        shutil.rmtree(publish_root)
    publish_root.mkdir(parents=True)
    for k in keys:
        dst = publish_root / k
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(dist / k, dst)


def _inject_zip_mirrors(publish_root: Path, doc: dict) -> dict:
    """保留相对 zipUrl 不变，注入 zipKey（兼容保留）与 zipUrls（Release 绝对兜底镜像）。"""
    tag = doc["releaseTag"]
    mchs = _mirror_channels(doc)
    stats: dict[str, int] = {}
    for module in ZIP_MODULES:
        idx = publish_root / module / "index.json"
        if not idx.exists():
            raise SystemExit(f"[prepare][FATAL] 缺少 {module}/index.json")
        data = json.loads(idx.read_text(encoding="utf-8"))
        items = data.get("items") or []
        n = 0
        for it in items:
            zu = it.get("zipUrl")
            if not zu or not isinstance(zu, str):
                continue
            if zu.startswith(("http://", "https://")):
                raise SystemExit(
                    f"[prepare][FATAL] {module} 项 "
                    f"{it.get('id') or it.get('month')} 的 zipUrl 不是相对路径: {zu}"
                )
            key = posixpath.normpath(f"{module}/{zu}")
            it["zipKey"] = key
            it["zipUrls"] = [c.key_to_url(key, tag) for c in mchs]
            n += 1
        idx.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        stats[module] = n
    return stats


def _recompute_hashes(publish_root: Path) -> tuple[dict, dict]:
    """按 Studio 同算法（sha256 of index.json bytes）重算各模块 hash 并回写 manifest.json。"""
    mf = publish_root / "manifest.json"
    manifest = json.loads(mf.read_text(encoding="utf-8"))
    out: dict[str, str] = {}
    for module, mod in (manifest.get("modules") or {}).items():
        idx = publish_root / module / "index.json"
        if not idx.exists():
            continue
        h = _sha256(idx)
        mod["hash"] = h
        out[module] = h
    mf.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    return out, manifest


def _gate_zips_exist(publish_root: Path, doc: dict) -> list[str]:
    """门禁 1+2：所有引用的 zip 本地真实存在；zip basename 全局无冲突。"""
    referenced: list[str] = []
    for module in ZIP_MODULES:
        data = json.loads((publish_root / module / "index.json").read_text("utf-8"))
        for it in data.get("items") or []:
            zu = it.get("zipUrl")
            if zu:
                referenced.append(posixpath.normpath(f"{module}/{zu}"))

    missing = [k for k in referenced if not (publish_root / k).exists()]
    if missing:
        raise SystemExit(f"[prepare][FATAL] 以下 zip 在本地不存在: {missing}")

    names = sorted(p.name for p in publish_root.rglob("*.zip"))
    dupes = sorted({n for n in names if names.count(n) > 1})
    if dupes:
        raise SystemExit(
            f"[prepare][FATAL] zip basename 存在重名（Release 扁平命名冲突）: {dupes}"
        )

    unreferenced = sorted(set(names) - {posixpath.basename(k) for k in referenced})
    if unreferenced:
        print(f"[prepare][warn] 磁盘上存在未被 index.json 引用的 zip: {unreferenced}")
    return referenced


def _read_prev_main_version(doc: dict, repo: Path, publish_root: Path) -> int | None:
    """读取「上一版已发布」的 main.version，作为递增门禁的基线。

    优先级：
      1. .publish/latest.json —— 上一次真正成功完成发布的快照，
         杜绝被上一次失败的半成品误导；
      2. 远端 R2 生产区 manifest.json —— 兜底本地副本与台账缺失的场景；
      3. 本地工作副本 <publishRoot>/manifest.json —— 降级兼容；
      4. 都没有 -> None，视为首次发布。
    """
    d = doc["dist"]
    url = (
        f"{d['r2Host'].rstrip('/')}/{d['releasePrefix']}/"
        f"{d.get('manifestName', 'manifest.json')}"
    )
    v = ledger.load_baseline_main_version(repo, r2_url=url)
    if v is not None:
        print(f"[prepare] 读取上一版基线 main.version={v}")
    else:
        print("[prepare] 无历史已发布基线（首次发布或首次建台账），放行")
    return v


def _gate_main_version(publish_root: Path, prev: int | None) -> None:
    """门禁 3：main.version 严格递增。

    客户端 MainContentPipeline 有 `remoteVersion <= _localVersion` 的短路：
    版本不涨，已装机 App 完全不会重新拉取内容。故此处做门禁提前拦住。

      prev is None -> 首次发布（或无历史基线），放行
      cur  >  prev -> 通过
      cur == prev  -> 告警放行（允许同版本重复 prepare 重试）
      cur  <  prev -> 中断（版本回退；确需回滚请见 README §8，回滚版本号要更高）
    """
    manifest = json.loads((publish_root / "manifest.json").read_text("utf-8"))
    cur = int(((manifest.get("modules") or {}).get("main") or {}).get("version") or 0)

    if prev is None:
        print(f"[prepare] main.version={cur}：无历史基线（首次发布），放行")
        return
    if cur < prev:
        raise SystemExit(
            f"[prepare][FATAL] main.version 回退: current={cur} < previous={prev}；"
            f"客户端将无法感知更新。若确需回滚，请手动把 version 调得比 {prev} 更高。"
        )
    if cur == prev:
        print(f"[prepare][warn] main.version={cur} 与上一版相同："
              f"客户端不会重新拉取，若本次是改图/纠错请手动递增 version")
        return
    print(f"[prepare] main.version 递增校验通过: {prev} -> {cur}")


def do_prepare(args) -> int:
    doc = load_doc()
    dist, _repo, publish_root = _ctx(doc)
    min_files = int(doc["dist"].get("minSourceFiles", 200))

    print(f"[prepare] dist        = {dist}")
    print(f"[prepare] publishRoot = {publish_root}")

    keys = _source_files(dist, doc)
    total_all = sum(1 for f in dist.rglob("*") if f.is_file())
    if len(keys) < min_files:
        raise SystemExit(
            f"[prepare][FATAL] 源文件数量守卫未通过: 白名单内 {len(keys)} < {min_files}"
            f"（输出目录总文件数 {total_all}）；疑似误拷贝空目录，已中断。"
        )
    print(f"[prepare] 源文件 {len(keys)} 个（目录总文件 {total_all} 个，已排除隐藏路径）")

    # 基线优先从已归档台账或生产区读取
    prev_version = _read_prev_main_version(doc, _repo, publish_root)

    # 源指纹：同样要在覆盖前算，此时 dist 内还是未被改动的原始导出产物
    src_fp, src_count = ledger.source_fingerprint(dist, keys)

    _copy_whitelist(dist, publish_root, keys)
    print(f"[prepare] 白名单拷贝完成 -> {publish_root}")

    stats = _inject_zip_mirrors(publish_root, doc)
    print("[prepare] zipUrls 注入: " + ", ".join(f"{k}={v}" for k, v in stats.items()))

    hashes, manifest = _recompute_hashes(publish_root)
    print("[prepare] 模块 hash 重算:")
    for k, v in hashes.items():
        print(f"           {k:<12} {v[:16]}...")

    referenced = _gate_zips_exist(publish_root, doc)
    print(f"[prepare] 门禁通过: zip 引用 {len(referenced)} 个全部存在，basename 无冲突")
    _gate_main_version(publish_root, prev_version)

    # ---- 台账：文件级指纹 + 变化清单
    #     注意指纹必须算在「注入/hash 重写之后」的发布产物上：那才是真正会被
    #     上传到远端的树；源指纹单独记录，用于区分"数据变了"还是"注入逻辑变了"。
    pub_now = ledger.tree_files(publish_root)
    prev = ledger.load_latest(_repo)

    if prev is None:
        changes = {"added": [], "removed": [], "changed": [], "unchanged": [],
                   "counts": {"added": 0, "removed": 0, "changed": 0,
                              "unchanged": len(pub_now)}}
        source_changed = True
        print("[ledger] 无历史台账，视为首次发布（不拦截）")
    else:
        diff = ledger.diff_files(prev.get("publishedFiles") or {}, pub_now)
        counts = {k: len(v) for k, v in diff.items()}
        changes = {**diff, "counts": counts}
        source_changed = prev.get("sourceFingerprint") != src_fp
        ledger.print_change_report(changes)

        if counts["added"] or counts["removed"] or counts["changed"]:
            print(f"[ledger] 检测到实质变化（源指纹是否变化: {source_changed}），允许发布")
        else:
            print("[ledger] 发布产物与上次完全一致，正在核对远端是否同步...")
            if not _remote_in_sync(doc, publish_root):
                print("[ledger] 远端与本地不一致（可能远端被清空/回滚），"
                      "仍允许继续发布以补齐全量内容")
            elif getattr(args, "force", False):
                print("[ledger] 显式 --force，忽略无变化拦截")
            else:
                print(
                    "\n[prepare][ABORT] 内容与上次发布完全一致且远端已同步，"
                    "没有需要发布的变更。\n"
                    "  若你确实要重发（例如刷新 CDN / 重新上传 Release 附件），"
                    "请加 --force。\n"
                    "  若这次是为了修正数据，请先确认 Studio 已重新导出 Output。",
                    file=sys.stderr,
                )
                return 3

    modules = manifest.get("modules") or {}
    main_ver = (modules.get("main") or {}).get("version")
    ledger.start_run(_repo, {
        "schema": 2,
        "sourceRoot": str(dist),
        "publishRoot": str(publish_root),
        "mainVersion": main_ver,
        "modules": {k: {"version": v.get("version"), "hash": v.get("hash")}
                    for k, v in modules.items()},
        "sourceFingerprint": src_fp,
        "sourceFileCount": src_count,
        "publishedFileCount": len(pub_now),
        "publishedFiles": pub_now,
        "sourceChanged": source_changed,
        "changes": changes,
        "previousRunId": (prev or {}).get("runId"),
        "prepare": {"rc": 0, "files": len(pub_now)},
    })

    n_files = len(pub_now)
    n_zip = len(list(publish_root.rglob("*.zip")))
    print(f"[prepare] 完成: {n_files} 文件 / {n_zip} zip / main.version={main_ver}")
    print(f"[ledger] 本次运行记录已写入 {ledger.pub_dir(_repo) / 'run.json'}")
    return 0


# ------------------------------------------------------------------ test
def do_test(args) -> int:
    doc = load_doc()
    _, repo, publish_root = _ctx(doc)
    ledger.assert_pipeline_state(
        repo,
        ("PREPARED", "LOCAL_VERIFIED"),
        "test",
        force=getattr(args, "force", False) or getattr(args, "dry_run", False),
    )
    skip_flutter = getattr(args, "skip_flutter", False)
    verbose = getattr(args, "verbose", False)
    rc = check_local.run_all_local_checks(
        publish_root,
        repo_root=REPO_ROOT,
        skip_flutter=skip_flutter,
        verbose=verbose,
    )
    if rc == 0 and not getattr(args, "dry_run", False):
        ledger.set_pipeline_state(repo, "LOCAL_VERIFIED", {"test": {"rc": 0}})
    return rc


# ------------------------------------------------------------------ stage
def do_stage(args) -> int:
    doc = load_doc()
    _, repo, publish_root = _ctx(doc)
    ledger.assert_pipeline_state(
        repo,
        ("LOCAL_VERIFIED", "STAGED"),
        "stage",
        force=getattr(args, "force", False) or getattr(args, "dry_run", False),
    )
    d = doc["dist"]
    if not publish_root.exists():
        raise SystemExit(f"[stage][FATAL] publishRoot 不存在，请先运行 prepare: {publish_root}")

    n = sum(1 for p in publish_root.rglob("*") if p.is_file())
    if n < int(d.get("minSourceFiles", 200)):
        raise SystemExit(
            f"[stage][FATAL] 源非空守卫未通过: {n} 个文件 < {d.get('minSourceFiles')}"
        )

    target = f"{d['r2Remote']}/{d['stagePrefix']}"
    cmd = ["rclone", "sync", str(publish_root), target, "--checksum", "--stats-one-line"]
    if args.dry_run:
        cmd.append("--dry-run")
    rc = _run(cmd)
    print(
        f"[stage] {'DRY-RUN ' if args.dry_run else ''}同步完成: "
        f"{publish_root} -> {target} ({n} 文件)"
    )
    if not args.dry_run:
        _note(doc, "stage", {"rc": rc, "files": n, "target": target})
        if rc == 0:
            ledger.set_pipeline_state(
                repo, "STAGED", {"stage": {"rc": rc, "files": n, "target": target}}
            )
    return rc


# ------------------------------------------------------------------ verify
def _verify_cmd(env: str) -> list:
    return [sys.executable, str(HERE / "verify_channels.py"), "--env", env]


def do_verify(args) -> int:
    doc = load_doc()
    _, repo, _ = _ctx(doc)
    if args.env == "stage":
        ledger.assert_pipeline_state(
            repo,
            ("STAGED", "STAGE_VERIFIED"),
            "verify(stage)",
            force=getattr(args, "force", False) or getattr(args, "dry_run", False),
        )
    if getattr(args, "dry_run", False):
        print(f"[verify] DRY-RUN：模拟针对 {args.env} 巡检通过")
        return 0
    rc = _run(_verify_cmd(args.env))
    if rc == 0 and args.env == "stage":
        ledger.set_pipeline_state(
            repo, "STAGE_VERIFIED", {"verify_stage": {"rc": 0}}
        )
    return rc


# ------------------------------------------------------------------ release
def _release_zips(publish_root: Path) -> list[Path]:
    return sorted(p for p in publish_root.rglob("*.zip"))


def _github_release(publish_root: Path, doc: dict, force: bool = False) -> int:
    tag = doc["releaseTag"]
    ch = next(c for c in load_channels() if c.id == "github")
    repo = ch.publish["remote"].split("github.com/")[-1].removesuffix(".git")
    zips = _release_zips(publish_root)

    # 1. 幂等确保 release 存在（tag assets 可能已存在，故先 --verify-tag 再退化创建）
    if _run(["gh", "release", "view", tag, "-R", repo], stderr=subprocess.DEVNULL) != 0:
        print(f"[release][github] release {tag} 不存在，创建中")
        if _run(
            ["gh", "release", "create", tag, "-R", repo, "--title", f"assets {tag}",
             "--notes", "jigsaw-data zip packs", "--verify-tag"],
            stderr=subprocess.DEVNULL,
        ) != 0:
            _run(
                ["gh", "release", "create", tag, "-R", repo, "--title", f"assets {tag}",
                 "--notes", "jigsaw-data zip packs"],
            )

    # 2. 已有附件清单 -> 仅上传缺失（文件名自带 -r{rev}，同名即同内容）
    #    --force 时不看清单，全部重传（用于「内容改了但文件名没变」的场景）
    existing: set[str] = set()
    if not force:
        p = subprocess.run(
            ["gh", "release", "view", tag, "-R", repo, "--json", "assets",
             "-q", ".assets[].name"],
            capture_output=True, text=True,
        )
        if p.returncode == 0:
            existing = {ln.strip() for ln in p.stdout.splitlines() if ln.strip()}

    missing = [z for z in zips if z.name not in existing]
    if not missing:
        print(f"[release][github] 已是最新，无需上传（已有 {len(existing)} 个附件）")
        return 0
    print(f"[release][github] {'强制重传' if force else '新增'} {len(missing)} 个 zip: "
          f"{[z.name for z in missing]}")
    return _run(["gh", "release", "upload", tag, "-R", repo,
                 *[str(z) for z in missing], "--clobber"])


def _gitee_release(publish_root: Path, doc: dict, force: bool = False) -> int:
    token = os.environ.get("GITEE_TOKEN")
    if not token:
        print("[release][gitee][FATAL] 未设置 GITEE_TOKEN，无法上传 Gitee 备源", file=sys.stderr)
        return 2
    cmd = [sys.executable, str(HERE / "gitee_release.py"), "--publish-root", str(publish_root)]
    if force:
        cmd.append("--force")
    return _run(cmd, extra_env={"GITEE_TOKEN": token})


def do_release(args) -> int:
    doc = load_doc()
    _, repo, publish_root = _ctx(doc)
    ledger.assert_pipeline_state(
        repo,
        ("STAGE_VERIFIED", "RELEASED"),
        "release",
        force=getattr(args, "force", False) or getattr(args, "dry_run", False),
    )
    if not publish_root.exists():
        raise SystemExit(f"[release][FATAL] publishRoot 不存在，请先运行 prepare: {publish_root}")
    if args.dry_run:
        zips = _release_zips(publish_root)
        print(f"[release] DRY-RUN：待处理 {len(zips)} 个 zip")
        for z in zips:
            print(f"           {z.name}  {z.stat().st_size:,} bytes")
        return 0
    rc1 = _github_release(publish_root, doc, args.force)
    rc2 = _gitee_release(publish_root, doc, args.force)
    _note(doc, "release", {
        "rc": rc1 or rc2,
        "githubRc": rc1,
        "giteeRc": rc2,
        "zips": [z.name for z in _release_zips(publish_root)],
    })
    if rc1 or rc2:
        print(f"[release][warn] github rc={rc1} gitee rc={rc2}")
        return 1
    ledger.set_pipeline_state(
        repo, "RELEASED", {
            "release": {
                "rc": 0,
                "githubRc": rc1,
                "giteeRc": rc2,
                "zips": [z.name for z in _release_zips(publish_root)],
            }
        }
    )
    print("[release] 备源附件已全部就位")
    return 0


# ------------------------------------------------------------------ promote
def do_promote(args) -> int:
    doc = load_doc()
    _, repo, _ = _ctx(doc)
    ledger.assert_pipeline_state(
        repo,
        ("RELEASED", "PROMOTED"),
        "promote",
        force=getattr(args, "force", False) or getattr(args, "dry_run", False),
    )
    d = doc["dist"]
    src = f"{d['r2Remote']}/{d['stagePrefix']}"
    dst = f"{d['r2Remote']}/{d['releasePrefix']}"
    cmd = ["rclone", "copy", src, dst, "--checksum", "--stats-one-line"]
    if args.dry_run:
        cmd.append("--dry-run")
    rc = _run(cmd)
    print(f"[promote] {'DRY-RUN ' if args.dry_run else ''}R2 服务端同步: {src} -> {dst}")
    if rc or args.dry_run:
        _note(doc, "promote", {"rc": rc, "dryRun": bool(args.dry_run)})
        return rc
    print("[promote] 生产区已生效，开始生产全量巡检")
    vrc = _run(_verify_cmd("prod"))
    _note(doc, "promote", {"rc": rc, "verifyRc": vrc})
    if vrc:
        return vrc
    ledger.set_pipeline_state(
        repo, "PROMOTED", {"promote": {"rc": rc, "verifyRc": vrc}}
    )
    # 全流程完成 -> 台账归档
    run_id, _ = _current_run(repo)
    if run_id:
        latest = ledger.finish_run(repo, run_id, state="PROMOTED")
        print(f"[ledger] 本次发布已归档 -> {latest}")
        print(f"[ledger] 摘要已追加 -> {ledger.pub_dir(repo) / 'history.ndjson'}")
    return 0


# ------------------------------------------------------------------ all / git / reset / purge
def do_all(args) -> int:
    steps = (
        ("prepare", do_prepare, args),
        ("test", do_test, args),
        ("stage", do_stage, args),
        (
            "verify(stage)",
            do_verify,
            argparse.Namespace(
                env="stage",
                force=args.force,
                dry_run=getattr(args, "dry_run", False),
            ),
        ),
        ("release", do_release, args),
        ("promote", do_promote, args),
    )
    for step, fn, arg in steps:
        print(f"\n===== [{step}] =====")
        rc = fn(arg)
        if rc == 3:
            print(f"\n[all][STOP] {step} 判定无需发布（内容无变化），流水线正常终止")
            return 0
        if rc:
            print(f"[all][FATAL] 步骤 {step} 失败 rc={rc}，流水线中断")
            return rc
    print("\n[all] 全流程完成")
    return 0


def do_reset(_args) -> int:
    doc = load_doc()
    _, repo, _ = _ctx(doc)
    ok = ledger.reset_run(repo)
    if ok:
        print("[reset] ✅ 已重置当前发布会话，状态已恢复为 INIT。")
        return 0
    return 1


def do_git(args) -> int:
    """提交并推送 jigsaw-data 的 json/webp（zip 被 .gitignore 排除）。需显式调用。"""
    doc = load_doc()
    _, repo, _ = _ctx(doc)
    ledger.assert_pipeline_state(
        repo,
        ("PROMOTED", "FINISHED"),
        "git",
        force=getattr(args, "force", False) or getattr(args, "dry_run", False),
    )
    msg = args.message or f"publish assets {time.strftime('%Y%m%d')}"
    if getattr(args, "dry_run", False):
        print(f"[git] DRY-RUN：模拟提交与推送 (commit: '{msg}')")
        return 0
    if _run(["git", "-C", str(repo), "add", "-A"]):
        return 1
    rc = _run(["git", "-C", str(repo), "commit", "-m", msg])
    if rc:
        print("[git][warn] commit 无改动或失败，继续尝试推送")
    for remote in ("origin", "gitee"):
        if _run(["git", "-C", str(repo), "push", remote, "master"]):
            return 1
    ledger.set_pipeline_state(repo, "FINISHED", {"git": {"rc": 0}})
    run_id, _ = _current_run(repo)
    if run_id:
        ledger.finish_run(repo, run_id, state="FINISHED")
    return 0


def do_purge(_args) -> int:
    """极端情况手动应急：清 Cloudflare 边缘缓存。正常发布无需调用（JSON 由 Cache Rule 绕过）。"""
    token = os.environ.get("CF_API_TOKEN")
    zone = os.environ.get("CF_ZONE_ID")
    if not token or not zone:
        print("[purge][FATAL] 需设置 CF_API_TOKEN 与 CF_ZONE_ID", file=sys.stderr)
        return 2
    import urllib.request

    req = urllib.request.Request(
        f"https://api.cloudflare.com/client/v4/zones/{zone}/purge_cache",
        data=json.dumps({"purge_everything": True}).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        print(f"[purge] HTTP {r.status} {r.read().decode()[:200]}")
    return 0


# ------------------------------------------------------------------ main
def main() -> int:
    ap = argparse.ArgumentParser(prog="publish.py", description="jigsaw-data v3 素材发布编排器")
    sub = ap.add_subparsers(dest="cmd", required=True)

    pp = sub.add_parser("prepare", help="白名单拷贝 + 注入 zipUrls + 重算 hash + 硬门禁 + 变化检测")
    pp.add_argument("--force", action="store_true",
                    help="忽略「内容与上次发布完全一致」的拦截，强制继续")

    tp = sub.add_parser("test", aliases=["check-local"], help="本地全量深度体检门禁（静态体检 + WebP解码 + Flutter反序列化）")
    tp.add_argument("--skip-flutter", action="store_true", help="跳过 flutter test 步骤")
    tp.add_argument("-v", "--verbose", action="store_true", help="打印全部问题明细")
    tp.add_argument("--force", action="store_true", help="强制忽略状态门禁")

    sp = sub.add_parser("stage", help="rclone sync -> r2:_stage")
    sp.add_argument("--dry-run", action="store_true")
    sp.add_argument("--force", action="store_true", help="强制忽略状态门禁")

    sv = sub.add_parser("verify", help="巡检")
    sv.add_argument("--env", choices=("stage", "prod"), default="prod")
    sv.add_argument("--dry-run", action="store_true")
    sv.add_argument("--force", action="store_true", help="强制忽略状态门禁")

    sr = sub.add_parser("release", help="上传新增 zip 到 GitHub / Gitee Release")
    sr.add_argument("--dry-run", action="store_true")
    sr.add_argument("--force", action="store_true",
                    help="忽略远端已有附件/状态门禁，强制重传全部 zip")

    spp = sub.add_parser("promote", help="R2 服务端 _stage -> release 并巡检生产")
    spp.add_argument("--dry-run", action="store_true")
    spp.add_argument("--force", action="store_true", help="强制忽略状态门禁")

    sa = sub.add_parser("all", help="按安全时序跑全套 (prepare -> test -> stage -> verify -> release -> promote)")
    sa.add_argument("--dry-run", action="store_true")
    sa.add_argument("--skip-flutter", action="store_true", help="跳过 flutter test")
    sa.add_argument("--force", action="store_true", help="强制忽略无变化/状态拦截")

    sub.add_parser("reset", help="重置当前发布会话，清理进行中状态回 INIT")

    sg = sub.add_parser("git", help="提交并推送 jigsaw-data")
    sg.add_argument("--dry-run", action="store_true")
    sg.add_argument("--message", "-m", default=None)
    sg.add_argument("--force", action="store_true", help="强制忽略状态门禁")

    sub.add_parser("purge", help="手动清 Cloudflare 缓存（应急）")

    args = ap.parse_args()
    if not hasattr(args, "dry_run"):
        args.dry_run = False
    if not hasattr(args, "force"):
        args.force = False
    if not hasattr(args, "skip_flutter"):
        args.skip_flutter = False
    if not hasattr(args, "verbose"):
        args.verbose = False

    handlers = {
        "prepare": do_prepare,
        "test": do_test,
        "check-local": do_test,
        "stage": do_stage,
        "verify": do_verify,
        "release": do_release,
        "promote": do_promote,
        "all": do_all,
        "reset": do_reset,
        "git": do_git,
        "purge": do_purge,
    }
    return handlers[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
