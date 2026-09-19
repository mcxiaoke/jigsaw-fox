#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gitee_publish.py — Gitee 自动发布（git 推送 + Release 标签 + 资产上传）

Gitee 无官方 CLI，这里用 Gitee OpenAPI 完成 Release 部分；git 推送到 master。
需要 Gitee 私人令牌（repo 权限），可二选一提供：
  - 环境变量 GITEE_TOKEN
  - 运行时交互输入

用法
----
  python gitee_publish.py                 # 推送 + 建 tag=assets + 上传所有 zip 到 Release
  python gitee_publish.py --no-push      # 仅上传 Release 资产（远端内容已就绪时）
"""
from __future__ import annotations

import getpass
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from assetmap import load_channels, load_doc, scan_dist_keys, is_zip_key  # noqa: E402
import urllib.request, urllib.error

DOC = load_doc()
DIST = Path(DOC["dist"]["root"])
EXCL = DOC["dist"].get("excludeNames", [])
TAG = DOC["releaseTag"]
GITEE_OWNER_REPO = "macitee/jigsaw-data"  # 与 channels.json gitee 通道一致
STAGE = Path(DOC["dist"]["stage"])


def _run(cmd, env=None):
    print("+ " + " ".join(cmd), flush=True)
    return subprocess.run(cmd, env=env).returncode


import atexit
import tempfile

_askpass_file: str | None = None


def _cleanup_askpass():
    global _askpass_file
    if _askpass_file and os.path.exists(_askpass_file):
        try:
            os.remove(_askpass_file)
        except OSError:
            pass
        _askpass_file = None


atexit.register(_cleanup_askpass)


def _git_env() -> dict:
    global _askpass_file
    env = dict(os.environ)
    token = env.get("GITEE_TOKEN") or env.get("MODELSCOPE_TOKEN")
    if token:
        if not _askpass_file or not os.path.exists(_askpass_file):
            fd, path = tempfile.mkstemp(prefix="_git_askpass_", suffix=".py")
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write("import sys\nsys.stdout.write(" + repr(token) + ")\n")
            _askpass_file = path
        env["GIT_ASKPASS"] = str(_askpass_file)
        env["GCM_INTERACTIVE"] = "never"
    return env


def prepare_git(remote: str, branch: str) -> Path:
    dst = STAGE.parent / f"_git_{remote.split('/')[-1]}"
    dst.mkdir(parents=True, exist_ok=True)
    for p in dst.iterdir():
        if p.name.startswith(".git"):
            continue
        if p.is_dir():
            shutil.rmtree(p)
        else:
            p.unlink()
    for k in scan_dist_keys(DIST, EXCL):
        if is_zip_key(k):
            continue
        src = DIST / k
        d = dst / k
        d.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, d)
    if not (dst / ".git").exists():
        _run(["git", "-C", str(dst), "init", "-q"])
        _run(["git", "-C", str(dst), "remote", "add", "origin", "https://gitee.com/macitee/jigsaw-data.git"])
    _run(["git", "-C", str(dst), "add", "-A"])
    _run(["git", "-C", str(dst), "commit", "-q", "-m",
          f"publish assets {time.strftime('%Y%m%d-%H%M%S')}"], stderr=subprocess.DEVNULL)
    return dst


def api_post(url, token, data=None, files=None):
    headers = {"Authorization": f"token {token}"}
    if files:
        import urllib.request as u
        boundary = "----jigboundary"
        body = bytearray()
        for fk, fpath in files:
            body += f"--{boundary}\r\n".encode()
            body += f'Content-Disposition: form-data; name="{fk}"; filename="{Path(fpath).name}"\r\n'.encode()
            body += b"Content-Type: application/octet-stream\r\n\r\n"
            body += open(fpath, "rb").read() + b"\r\n"
        body += f"--{boundary}--\r\n".encode()
        req = urllib.request.Request(url, data=body, headers={**headers, "Content-Type": f"multipart/form-data; boundary={boundary}"})
    else:
        req = urllib.request.Request(url, data=json.dumps(data).encode() if data else None,
                                     headers={**headers, "Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def api_get(url, token):
    req = urllib.request.Request(url, headers={"Authorization": f"token {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def main():
    no_push = "--no-push" in sys.argv
    token = sys.environ.get("GITEE_TOKEN") or getpass.getpass("Gitee 私人令牌 (repo): ")
    base = f"https://gitee.com/api/v5/repos/{GITEE_OWNER_REPO}"

    if not no_push:
        print("[gitee] 准备并推送 git 内容")
        dst = prepare_git("https://gitee.com/macitee/jigsaw-data.git", "master")
        gitee_url = "https://gitee.com/macitee/jigsaw-data.git"
        _run(["git", "-C", str(dst), "fetch", gitee_url, "master"], _git_env())
        if _run(["git", "-C", str(dst), "push", gitee_url, "HEAD:master"], _git_env()):
            print("[gitee] push 失败，尝试 force-with-lease")
            if _run(["git", "-C", str(dst), "push", "--force-with-lease", gitee_url, "HEAD:master"], _git_env()):
                print("[gitee] push 仍失败，请检查令牌权限/网络")
                return 1

    # 建 tag（若已存在则跳过）
    st, _ = api_get(f"{base}/tags/{TAG}", token)
    if st == 404:
        st, body = api_post(f"{base}/tags", token, data={"tag_name": TAG, "ref": "master",
                                                         "message": f"assets {TAG}"})
        print(f"[gitee] create tag {TAG}: {st}")

    # 建/取 release
    st, body = api_get(f"{base}/releases/tags/{TAG}", token)
    if st == 404:
        st, body = api_post(f"{base}/releases", token, data={"tag_name": TAG,
                                                              "name": f"assets {TAG}",
                                                              "body": "jigsaw-data assets (zip packs)"})
        print(f"[gitee] create release: {st}")
    # 上传 zip
    zips = {k: DIST / k for k in scan_dist_keys(DIST, EXCL) if is_zip_key(k)}
    ok = 0
    for k, p in zips.items():
        st, b = api_post(f"{base}/releases/{TAG}/attach_files", token, files=[("file", str(p))])
        print(f"  upload {k}: {st}")
        ok += 1 if st in (200, 201) else 0
    print(f"[gitee] 上传完成 {ok}/{len(zips)}")
    _cleanup_askpass()
    return 0


if __name__ == "__main__":
    sys.exit(main())
