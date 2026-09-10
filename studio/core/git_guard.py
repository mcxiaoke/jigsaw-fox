#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.core.git_guard — .studio 目录 git 版本化守卫

将源素材库的 .studio/ 私有工作区纳入独立 git 仓库管理：
- repo 建在 <src_dir>/.studio 内（自包含，不扫描素材库主体）；
- 导出/回滚等节点事件自动 checkpoint / commit，形成可追溯时间线；
- 支持 off / auto / strict 三种守卫模式（.studio/git_guard.json 配置）；
- git 不可用时优雅降级为 no-op，绝不阻塞业务主流程（strict 显式拦截除外）。

设计文档：studio/docs/git-guard-design-20260910.md
"""

from __future__ import annotations

import logging
import subprocess
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

# GitPython 可用性探测：import 失败则后续全部走 CLI fallback / no-op
try:
    import git as _gitpython

    _HAS_GITPYTHON = True
except Exception:  # pragma: no cover - 环境相关
    _gitpython = None
    _HAS_GITPYTHON = False

DEFAULT_MODE = "auto"
_VALID_MODES = ("off", "auto", "strict")
_MODE_FILE = "git_guard.json"

# 托管区标记：guard 只维护两个标记之间的内容，标记之外的用户自定义行一律保留。
# 这样用户可以自由追加忽略规则，且模板升级仍能下发到老仓库。
_MANAGED_BEGIN = "# >>> studio git guard managed, do not edit >>>"
_MANAGED_END = "# <<< studio git guard managed <<<"

# .gitignore 托管区内容：高频二进制缓存、构建镜像与 rollback 快照，
# 体积大、可重建、持续变动（WAL / 每次导出新增的账本快照 / 回滚产物）。
# ledger/backups/ 必须忽略：回滚会把 release 镜像里的 zip/webp 移入
# ledger/backups/trashed-<op>/ 保留，一旦入库会让仓库迅速膨胀。
GITIGNORE_MANAGED_BODY = """\
# 高频二进制缓存、构建镜像与 rollback 快照（可重建，勿入库）
cache/
staging/
release/
ledger/backups/

# 兜底：.studio 只版本化文本元数据（tags/ledger/logs），压缩包与图片产物
# 一律不属于版本化范围。目录名白名单不可能穷尽，按扩展名兜底可确保未来
# 新增产物目录即使漏配，也不会把 MB 级二进制提交进仓库。
*.zip
*.png
*.jpg
*.webp
# 运行日志：文本但体量大且可重建，不入库（结构化审计仍以 logs/*.jsonl 版本化）
*.log
"""

# .gitattributes 托管区内容：与主仓库决策一致，彻底关闭行尾转换防 CRLF 污染
GITATTRIBUTES_MANAGED_BODY = "* -text\n"

_CONFIG_KEYS = ("core.autocrlf", "user.name", "user.email", "gc.auto")
_CONFIG_VALUES = ("false", "studio", "studio@local", "0")

_GIT_TIMEOUT_SECONDS = 10
_commit_lock = threading.Lock()


class GitGuardError(RuntimeError):
    """git_guard 内部错误（strict 拦截等场景由调用方据此构造提示）"""


# ---------------------------------------------------------------------------
# 内部工具
# ---------------------------------------------------------------------------

def _run_git(args: list[str], cwd: Path) -> subprocess.CompletedProcess | None:
    """同步执行 git CLI（带超时）；git 不可用或超时返回 None。"""
    try:
        return subprocess.run(
            ["git", *args],
            cwd=str(cwd),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=_GIT_TIMEOUT_SECONDS,
            shell=False,
        )
    except FileNotFoundError:
        logger.warning("[GIT_GUARD] git CLI 不可用 (FileNotFoundError)")
        return None
    except subprocess.TimeoutExpired:
        logger.warning("[GIT_GUARD] git 命令超时: %s", " ".join(args))
        return None


def _git_call(fn, *args, **kwargs) -> Any | None:
    """带超时执行 GitPython 调用；异常/超时返回 None 并记 warning。"""
    if not _HAS_GITPYTHON:
        return None
    with ThreadPoolExecutor(max_workers=1) as pool:
        try:
            return pool.submit(fn, *args, **kwargs).result(timeout=_GIT_TIMEOUT_SECONDS)
        except Exception as e:  # noqa: BLE001 - 降级路径必须吞掉一切异常
            logger.warning("[GIT_GUARD] GitPython 调用失败: %s", e)
            return None


def _repo_dir_ok(studio_dir: Path) -> bool:
    git_dir = studio_dir / ".git"
    return git_dir.exists()


# ---------------------------------------------------------------------------
# 模式配置
# ---------------------------------------------------------------------------

def load_mode(studio_dir: Path) -> str:
    """读取 .studio/git_guard.json 的 mode 字段；缺失/损坏/非法值一律回退 auto。"""
    p = Path(studio_dir) / _MODE_FILE
    try:
        import json

        raw = json.loads(p.read_text(encoding="utf-8"))
        mode = str(raw.get("mode") or "").strip().lower()
        if mode in _VALID_MODES:
            logger.debug("[GIT_GUARD] 守卫模式: %s (来自 %s)", mode, p)
            return mode
        logger.warning(
            "[GIT_GUARD] git_guard.json mode 值非法 (%r)，回退 %s", mode, DEFAULT_MODE
        )
    except FileNotFoundError:
        logger.debug("[GIT_GUARD] 未配置 git_guard.json，使用默认模式 %s", DEFAULT_MODE)
    except Exception as e:  # noqa: BLE001 - 配置损坏不报错
        logger.warning("[GIT_GUARD] git_guard.json 解析失败，回退默认模式: %s", e)
    return DEFAULT_MODE


def is_managed(studio_dir: Path) -> bool:
    """.studio 是否已被 git 管理（存在合法 .git）。"""
    studio_dir = Path(studio_dir)
    return _repo_dir_ok(studio_dir)


def last_commit_summary(studio_dir: Path) -> str:
    """最近一次 commit 的摘要文本；无 commit 或不可用时返回空串。"""
    studio_dir = Path(studio_dir)
    if not _repo_dir_ok(studio_dir):
        return ""
    if _HAS_GITPYTHON:
        try:
            repo = _git_call(_gitpython.Repo, str(studio_dir))
            if repo is not None and repo.head.commit is not None:
                return str(repo.head.commit.summary)
        except Exception:  # noqa: BLE001
            pass
    proc = _run_git(["log", "-1", "--format=%s"], studio_dir)
    if proc is not None and proc.returncode == 0:
        return proc.stdout.strip()
    return ""


def describe_status(studio_dir: Path, mode: str | None = None) -> str:
    """单行状态摘要：是否纳管 / 守卫模式 / 是否有未提交变更 / 最近 commit。"""
    studio_dir = Path(studio_dir)
    if mode is None:
        mode = load_mode(studio_dir)
    if mode == "off":
        return f"未启用 (mode=off)"
    if not _repo_dir_ok(studio_dir):
        return f"未纳管 (mode={mode})：导出时将自动初始化"
    try:
        dirty = is_dirty(studio_dir)
        last = last_commit_summary(studio_dir)
        state = "有未提交变更" if dirty else "clean"
        tail = f" | 最近: {last[:60]}" if last else " | 暂无 commit"
        return f"已纳管 (mode={mode}) | 工作区{state}{tail}"
    except Exception as e:  # noqa: BLE001
        return f"已纳管 (mode={mode}) | 状态读取失败: {e}"


# ---------------------------------------------------------------------------
# 仓库初始化
# ---------------------------------------------------------------------------

def ensure_repo(studio_dir: Path) -> bool:
    """幂等初始化 .studio git 仓库；成功返回 True，失败返回 False（不抛异常）。

    - 已存在合法 repo：仅校准 ignore 托管区与配置，直接返回 True；
    - 首次初始化：git init → 写 .gitignore/.gitattributes → 局部配置 → 首次提交。

    ignore 文件采用「托管区校准」而非整文件覆盖：guard 只维护标记之间的内容，
    用户在标记之外追加的任何规则都会被保留，绝不会被静默抹掉。
    """
    studio_dir = Path(studio_dir)
    try:
        studio_dir.mkdir(parents=True, exist_ok=True)

        first_time = not _repo_dir_ok(studio_dir)

        if _calibrate_managed_file(
            studio_dir / ".gitignore", GITIGNORE_MANAGED_BODY
        ):
            logger.info(
                "[GIT_GUARD] 已校准 .gitignore 托管区（用户自定义行保留）: %s",
                studio_dir,
            )
        _calibrate_managed_file(
            studio_dir / ".gitattributes", GITATTRIBUTES_MANAGED_BODY
        )

        if first_time:
            logger.info(
                "[GIT_GUARD] 首次初始化 .studio git 仓库: %s", studio_dir
            )
            if not _init_repo(studio_dir):
                return False
        else:
            logger.info(
                "[GIT_GUARD] .studio git 仓库已存在，校验配置: %s", studio_dir
            )

        _apply_local_config(studio_dir)
        if first_time:
            logger.info(
                "[GIT_GUARD] 初始化完成 (跟踪范围: tags/ledger/logs；"
                "忽略托管区: cache/staging/release/ledger/backups)"
            )
        return True
    except Exception as e:  # noqa: BLE001
        logger.warning("[GIT_GUARD] ensure_repo 失败: %s", e)
        return False


def _managed_block(body: str) -> str:
    """把托管区内容渲染为带首尾标记的完整文本块（标记行是合法注释）。"""
    return f"{_MANAGED_BEGIN}\n{body}{_MANAGED_END}\n"


def _calibrate_managed_file(p: Path, body: str) -> bool:
    """校准 ignore 类文件的托管区；返回是否发生了写入。

    语义（关键：绝不吞掉用户内容）：
    - 文件不存在：写入完整托管区；
    - 含托管标记：只替换标记之间的内容（模板升级可下发），标记之外原样保留；
    - 无托管标记（老文件或用户自建）：原有内容全部保留，托管区追加到末尾。
    """
    block = _managed_block(body)
    try:
        existing = p.read_text(encoding="utf-8") if p.exists() else None
    except Exception:  # noqa: BLE001 - 读取失败按不存在处理
        existing = None

    if existing is None:
        new = block
    elif _MANAGED_BEGIN in existing and _MANAGED_END in existing:
        head, _, rest = existing.partition(_MANAGED_BEGIN)
        _, _, tail = rest.partition(_MANAGED_END)
        tail = tail.lstrip("\r\n")
        if head and not head.endswith("\n"):
            head += "\n"
        if tail and not tail.endswith("\n"):
            tail += "\n"
        new = head + block + tail
    else:
        sep = "\n" if existing and not existing.endswith("\n") else ""
        new = existing + sep + block

    if new == existing:
        return False
    p.write_text(new, encoding="utf-8", newline="\n")
    return True


def _init_repo(studio_dir: Path) -> bool:
    """git init（优先 GitPython，失败回退 CLI），成功后立即做首次整体提交。"""
    if _HAS_GITPYTHON:
        repo = _git_call(_gitpython.Repo.init, str(studio_dir))
        if repo is not None:
            return _initial_commit(studio_dir)

    proc = _run_git(["init"], studio_dir)
    if proc is None or proc.returncode != 0:
        logger.warning(
            "[GIT_GUARD] git init 失败: %s", (getattr(proc, "stderr", "") or "").strip()
        )
        return False
    return _initial_commit(studio_dir)


def _initial_commit(studio_dir: Path) -> bool:
    return _commit_all(studio_dir, "chore: init studio git guard")


def _apply_local_config(studio_dir: Path) -> None:
    for key, value in zip(_CONFIG_KEYS, _CONFIG_VALUES):
        if _HAS_GITPYTHON:
            repo = _git_call(_gitpython.Repo, str(studio_dir))
            if repo is not None:
                try:
                    with repo.config_writer() as cw:
                        cw.set_value("core" if key.startswith("core.") else "user" if key.startswith("user.") else "gc", key.split(".", 1)[1], value)
                    continue
                except Exception as e:  # noqa: BLE001
                    logger.warning("[GIT_GUARD] 局部配置写入失败 (%s): %s", key, e)
        _run_git(["config", key, value], studio_dir)


# ---------------------------------------------------------------------------
# 状态检查与提交
# ---------------------------------------------------------------------------

def is_dirty(studio_dir: Path) -> bool:
    """是否存在未提交变更（含未跟踪文件，ignore 规则生效后判定）。"""
    studio_dir = Path(studio_dir)
    if not _repo_dir_ok(studio_dir):
        return False
    if _HAS_GITPYTHON:
        try:
            repo = _git_call(_gitpython.Repo, str(studio_dir))
            if repo is not None:
                return bool(repo.is_dirty(untracked_files=True))
        except Exception as e:  # noqa: BLE001
            logger.warning("[GIT_GUARD] is_dirty 判定失败，降级 CLI: %s", e)
    proc = _run_git(["status", "--porcelain"], studio_dir)
    if proc is None or proc.returncode != 0:
        return False
    return bool(proc.stdout.strip())


def _commit_all(studio_dir: Path, message: str) -> bool:
    """git add -A + commit；clean 时跳过返回 False。失败返回 False 并 warning。"""
    with _commit_lock:
        return _commit_all_locked(studio_dir, message)


def _commit_all_locked(studio_dir: Path, message: str) -> bool:
    if not is_dirty(studio_dir):
        return False

    if _HAS_GITPYTHON:
        try:
            repo = _git_call(_gitpython.Repo, str(studio_dir))
            if repo is not None:
                repo.git.add(A=True)
                commit = repo.index.commit(message)
                logger.info("[GIT_GUARD] committed %s %s", commit.hexsha[:8], message)
                return True
        except Exception as e:  # noqa: BLE001
            logger.warning("[GIT_GUARD] GitPython commit 失败，降级 CLI: %s", e)

    add = _run_git(["add", "-A"], studio_dir)
    if add is None or add.returncode != 0:
        logger.warning("[GIT_GUARD] git add 失败: %s", (getattr(add, "stderr", "") or "").strip())
        return False
    commit = _run_git(["commit", "-m", message], studio_dir)
    if commit is None or commit.returncode != 0:
        logger.warning(
            "[GIT_GUARD] git commit 失败: %s", (getattr(commit, "stderr", "") or "").strip()
        )
        return False
    logger.info("[GIT_GUARD] committed (cli) %s", message)
    return True


def checkpoint(studio_dir: Path, msg: str) -> bool:
    """有未提交变更时整体提交一次；clean 时返回 False（不产生空 commit）。"""
    studio_dir = Path(studio_dir)
    if not _repo_dir_ok(studio_dir):
        return False
    try:
        return _commit_all(studio_dir, msg)
    except Exception as e:  # noqa: BLE001
        logger.warning("[GIT_GUARD] checkpoint 异常: %s", e)
        return False


# ---------------------------------------------------------------------------
# 业务挂点
# ---------------------------------------------------------------------------

def guard_export(studio_dir: Path, exp_type: str, *, strict: bool) -> str | None:
    """导出前置守卫。

    返回 None = 放行；返回 str = 拦截原因（仅 strict 且 checkpoint 失败时）。
    非 strict 模式下 checkpoint 失败只降级 warning，不影响导出。
    """
    studio_dir = Path(studio_dir)
    if not _repo_dir_ok(studio_dir):
        if strict:
            return f".studio git 仓库不可用（strict 模式拦截），目录: {studio_dir}"
        logger.warning("[GIT_GUARD] .studio 未被 git 管理，跳过导出前 checkpoint")
        return None

    msg = f"checkpoint(pre-export): {exp_type} (auto)"
    try:
        committed = _commit_all(studio_dir, msg)
    except Exception as e:  # noqa: BLE001 - 守卫异常不得冒泡
        logger.warning("[GIT_GUARD] 导出前 checkpoint 异常: %s", e)
        committed = False
    if committed:
        logger.info("[GIT_GUARD] 导出前 checkpoint 完成: %s", msg)
        return None
    # 未提交（clean）或提交失败
    if strict and is_dirty(studio_dir):
        return (
            f"strict 守卫: .studio 存在未提交变更且自动 checkpoint 失败，"
            f"已拦截导出。请手动处理 {studio_dir} 的 git 状态后重试"
        )
    return None


def commit_after_export(studio_dir: Path, exp_type: str, n: int, failed: bool = False) -> None:
    """正式导出结束后提交账本/流水/标签变化；失败仅 warning，绝不抛异常。"""
    studio_dir = Path(studio_dir)
    try:
        if failed:
            msg = f"export({exp_type}): failed after checkpoint (auto)"
        else:
            msg = f"export({exp_type}): {n} images"
        committed = _commit_all(studio_dir, msg)
        if committed:
            logger.info("[GIT_GUARD] 导出后 commit 完成: %s", msg)
    except Exception as e:  # noqa: BLE001
        logger.warning("[GIT_GUARD] commit_after_export 异常（忽略）: %s", e)


def commit_after_rollback(
    studio_dir: Path, modules: list[str], op_id: str, reason: str
) -> None:
    """回滚成功后提交账本/流水变化；失败仅 warning，绝不抛异常。"""
    studio_dir = Path(studio_dir)
    try:
        mods = ",".join(m for m in modules if m) or "unknown"
        suffix = f" {reason.strip()[:120]}" if reason.strip() else ""
        msg = f"rollback({mods}): op={op_id}{suffix}"
        committed = _commit_all(studio_dir, msg)
        if committed:
            logger.info("[GIT_GUARD] 回滚后 commit 完成: %s", msg)
    except Exception as e:  # noqa: BLE001
        logger.warning("[GIT_GUARD] commit_after_rollback 异常（忽略）: %s", e)
