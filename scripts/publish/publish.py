#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
publish.py — jigsaw-data 多平台 assets 发布编排器（唯一入口）

设计原则
--------
- dist 产物（含 zipKey 的相对 key）在所有平台完全一致，平台差异只在通道表；
- 发布顺序严格按依赖：blobs(zip) -> index.json -> manifest.json，避免半更新窗口；
- git 平台（github/gitee/modelscope）走“工作副本投影 + 推送”，zip 走 Release；
- R2 走 rclone 整树同步（json/图片/zip 同一 base，最省心）；
- 每个子命令可单独跑，便于只修一处时局部发布。

用法
----
  python publish.py normalize          # 生成 stage/（注入 zipKey，复制 .gitattributes）
  python publish.py r2                 # rclone 同步 stage/ -> r2:jigsaw-data
  python publish.py github             # 推送 github + 上传 Release zip（用 gh）
  python publish.py gitee              # 推送 gitee + 打印 Release 手动清单
python publish.py modelscope         # 【禁用中】modelscope：token 鉴权异常，disabled 时自动跳过
  python publish.py all                # normalize -> r2 -> github -> gitee（modelscope 自动跳过）
  python publish.py verify             # 跨通道巡检（见 verify_channels.py）

注意
----
- gitee / modelscope 的 Release 资产与 git push：Release 上传脚本内给出手动步骤，
  其余全自动。真正 push 前请确保已 git add/commit 本地 jigsaw-data（脚本会要求确认）。
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from assetmap import (  # noqa: E402
    load_channels,
    load_doc,
    scan_dist_keys,
    is_zip_key,
    Channel,
)

REPO_LOCAL = Path(
    "C:/Home/Projects/jigsaw-data"
)  # jigsaw-data 本地 git 仓（已配好 remote）
STAGE = Path("C:/Home/Temp/jigsawdata_build/stage")


def _run(cmd: list[str], **kw) -> int:
    print("+ " + " ".join(cmd), flush=True)
    kw.setdefault("env", _git_env())
    return subprocess.run(cmd, **kw).returncode


def _git_env() -> dict:
    """为需要鉴权的远端（modelscope/gitee）注入令牌到 Git 凭据。
    通过 GIT_ASKPASS 脚本把 token 喂给 git，避免明文字段留在进程参数中。"""
    import os

    env = dict(os.environ)
    token = env.get("MODELSCOPE_TOKEN") or env.get("GITEE_TOKEN")
    if token:
        askpass = STAGE.parent / "_git_askpass.py"
        askpass.write_text(
            "import sys\nsys.stdout.write(" + repr(token) + ")\n",
            encoding="utf-8",
        )
        env["GIT_ASKPASS"] = str(askpass)
        env["GCM_INTERACTIVE"] = "never"
    return env


def _confirm(msg: str) -> bool:
    r = input(f"\n[confirm] {msg} (y/N) ").strip().lower()
    return r == "y" or r == "yes"


# ----------------------------- 通用 -----------------------------
def do_normalize() -> int:
    return _run([sys.executable, str(HERE / "normalize.py")])


def _zip_files_in_dist(dist: Path, exclude: list[str]) -> dict[str, Path]:
    out: dict[str, Path] = {}
    for k in scan_dist_keys(dist, exclude):
        if k.endswith(".zip"):
            out[k] = dist / k
    return out


def _prepare_git_repo(
    remote: str, branch: str, dist: Path, exclude: list[str]
) -> Path | None:
    """把 dist 投影进一个 git 工作副本并 commit，返回该工作副本路径。

    remote 为真实 URL（如 https://github.com/...），工作副本内 remote 命名为 origin。
    """
    dst = STAGE.parent / f"_git_{remote.split('/')[-1].replace('.', '_')}"
    dst.mkdir(parents=True, exist_ok=True)
    # 仅保留 git 文件（排除 zip / 临时目录）
    for p in dst.iterdir():
        if p.name.startswith(".git"):
            continue
        if p.is_dir():
            shutil.rmtree(p)
        else:
            p.unlink()
    for k in scan_dist_keys(dist, exclude):
        if is_zip_key(k):
            continue  # git 平台不提交 zip
        src = dist / k
        d = dst / k
        d.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, d)
    # git 初始化（不依赖 named remote：push 时直接对 URL 推，规避凭据助手噪音）
    if not (dst / ".git").exists():
        if _run(["git", "-C", str(dst), "init", "-q"]):
            return None
    _run(["git", "-C", str(dst), "add", "-A"])
    _run(
        [
            "git",
            "-C",
            str(dst),
            "commit",
            "-q",
            "-m",
            f"publish assets {time.strftime('%Y%m%d-%H%M%S')}",
        ],
        stderr=subprocess.DEVNULL,
    )
    return dst


def _push_git(dst: Path, remote: str, branch: str) -> int:
    # 远端可能已有独立历史，先 fetch 建立 lease 基线，再 force-with-lease；
    # 仍失败（无 lease 基线等）退回普通 --force（发布仓库，内容由 dist 决定、可重发）。
    _run(["git", "-C", str(dst), "fetch", remote, branch], stderr=subprocess.DEVNULL)
    rc = _run(
        ["git", "-C", str(dst), "push", "--force-with-lease", remote, f"HEAD:{branch}"]
    )
    if rc != 0:
        print("[warn] force-with-lease 失败，退回 --force")
        rc = _run(["git", "-C", str(dst), "push", "--force", remote, f"HEAD:{branch}"])
    return rc


# ----------------------------- R2 -----------------------------
def do_r2() -> int:
    target = "r2:jigsaw-data"
    print(f"[r2] rclone copy stage -> {target} (zip 用 --immutable 防覆盖)")
    # zip 文件名不可变 -> 用 --immutable 锁死；json/webp 随版本更新允许覆盖。
    # 分两批：先 immutable 传 zip，再传其余文件（排除 zip 与 .gitattributes）。
    rc1 = _run(
        [
            "rclone",
            "copy",
            str(STAGE),
            target,
            "--immutable",
            "--stats-one-line",
            "--progress=false",
            "--include",
            "*.zip",
        ]
    )
    rc2 = _run(
        [
            "rclone",
            "copy",
            str(STAGE),
            target,
            "--stats-one-line",
            "--progress=false",
            "--exclude",
            ".gitattributes",
            "--exclude",
            "*.zip",
        ]
    )
    return rc1 or rc2


# ----------------------------- GitHub -----------------------------
def do_github() -> int:
    doc = load_doc()
    tag = doc["releaseTag"]
    dist = Path(doc["dist"].get("publishRoot", doc["dist"]["root"]))
    excl = doc["dist"].get("excludeNames", [])
    ch = next(c for c in load_channels() if c.id == "github")
    work = _prepare_git_repo(ch.publish["remote"], "master", dist, excl)
    if work is None:
        return 1
    # 先推分支，再打/更新固定标签 assets（指向本次发布内容，确保 master 与 tag 一致）
    if _push_git(work, ch.publish["remote"], "master"):
        return 1
    _run(["git", "-C", str(work), "tag", "-f", tag])
    if _run(
        ["git", "-C", str(work), "push", "-f", ch.publish["remote"], f"refs/tags/{tag}"]
    ):
        pass
    # 上传 zip 到 Release（gh）
    zips = _zip_files_in_dist(dist, excl)
    _run(
        [
            "gh",
            "release",
            "create",
            tag,
            "--title",
            f"assets {tag}",
            "--notes",
            "jigsaw-data assets (zip packs)",
            "--latest",
        ],
        stderr=subprocess.DEVNULL,
    )
    files = [str(p) for p in zips.values()]
    print(f"[github] gh release upload {tag} x{len(files)}")
    return _run(["gh", "release", "upload", tag, *files, "--clobber"])


# ----------------------------- Gitee -----------------------------
def do_gitee() -> int:
    doc = load_doc()
    tag = doc["releaseTag"]
    dist = Path(doc["dist"].get("publishRoot", doc["dist"]["root"]))
    excl = doc["dist"].get("excludeNames", [])
    ch = next(c for c in load_channels() if c.id == "gitee")
    rc = _prepare_git_repo(ch.publish["remote"], "master", dist, excl)
    if rc is None:
        return 1
    if _push_git(rc, ch.publish["remote"], "master"):
        return 1
    _run(["git", "-C", str(rc), "tag", "-f", tag])
    _run(["git", "-C", str(rc), "push", "-f", ch.publish["remote"], f"refs/tags/{tag}"])
    zips = _zip_files_in_dist(dist, excl)
    print(
        "\n[gitee] 请用 gitee.exe 登录态上传以下 Release 资产到 tag "
        f"{tag}（gitee.exe 优先；OpenAPI 令牌 gitee_publish.py 仅为兜底）："
    )
    for k, p in zips.items():
        print(f"   {k}  <-  {p}")
    print(
        f"\n  Release 地址模式：{ch.key_to_url(k, tag) if (k := 'events/packs/evt_ocean_adventure.zip') else ''}"
    )
    return 0


# ----------------------------- ModelScope -----------------------------
def do_modelscope() -> int:
    ch = next(c for c in load_channels() if c.id == "modelscope")
    if ch.disabled:
        print(
            "[modelscope] 通道已禁用（channels.json disabled=true，token git push 鉴权异常），跳过。"
        )
        return 0
    doc = load_doc()
    dist = Path(doc["dist"].get("publishRoot", doc["dist"]["root"]))
    excl = doc["dist"].get("excludeNames", [])
    rc = _prepare_git_repo(ch.publish["remote"], "master", dist, excl)
    if rc is None:
        return 1
    if _push_git(rc, ch.publish["remote"], "master"):
        return 1
    print(
        "[modelscope] 已推送 json+webp 镜像；zip 不在此仓库，app 端走 R2 兜底（见通道表 rules）。"
    )
    return 0


# ----------------------------- all / verify -----------------------------
def do_all() -> int:
    if do_normalize():
        return 1
    if do_r2():
        return 1
    if do_github():
        return 1
    if do_gitee():
        return 1
    if do_modelscope():
        return 1
    return 0


def main() -> int:
    sub = sys.argv[1] if len(sys.argv) > 1 else "all"
    handlers = {
        "normalize": do_normalize,
        "r2": do_r2,
        "github": do_github,
        "gitee": do_gitee,
        "modelscope": do_modelscope,
        "all": do_all,
        "verify": lambda: _run([sys.executable, str(HERE / "verify_channels.py")]),
    }
    h = handlers.get(sub)
    if not h:
        print(
            f"unknown subcommand: {sub}\nusage: {', '.join(handlers)}", file=sys.stderr
        )
        return 2
    return h()


if __name__ == "__main__":
    sys.exit(main())
