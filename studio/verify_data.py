#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
studio.verify_data — 已导出内容目录的**发布前体检**（只读，不改任何文件）

给定一个（或多个）内容根，读每个 JSON → 定位它引用的每个文件 → 核对
**文件存在 / 字段完整 / 内容哈希 / 文件大小 / zip 条目数 / manifest 自洽**。

用法::

    python -m studio.verify_data F:\\Pictures\\JigsawGame\\Output
    python -m studio.verify_data Output jigsaw-data .studio\\release    # 多个目录
    python -m studio.verify_data Output --json                          # 机器可读
    python -m studio.verify_data Output -v                              # 打印全部问题

可识别的目录形态（自动探测）：
  * 直接是内容根：`<dir>/manifest.json` + `<dir>/{main,daily,events,collections}/index.json`
  * 发布仓库根：`<dir>/release/manifest.json`（自动下钻到 `release/`）

退出码：0 = 全部通过；1 = 存在不一致（CI 可直接用）。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import zipfile
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

# 需要核对的模块（缺省按此顺序探测，实际以目录内是否含 index.json 为准）
MODULES = ("main", "daily", "events", "collections")


# ---------------------------------------------------------------------------
# 结果收集
# ---------------------------------------------------------------------------
class Report:
    """按「类别」累计 通过/总数，并收集失败明细。"""

    def __init__(self, name: str, root: Path):
        self.name = name
        self.root = root
        self.pass_n = 0  # 通过项计数
        self.total_n = 0  # 检查项计数
        # 分项统计
        self.files_ok = self.files_total = 0
        self.field_ok = self.field_total = 0
        self.hash_ok = self.hash_total = 0
        self.size_ok = self.size_total = 0
        self.zip_entry_ok = self.zip_entry_total = 0
        self.manifest_ok = self.manifest_total = 0
        self.refs_ok = self.refs_total = 0
        self.tags_ok = self.tags_total = 0
        self.problems: list[str] = []

    def ok(self, cond: bool, msg: str) -> bool:
        self.total_n += 1
        if cond:
            self.pass_n += 1
        else:
            self.problems.append(msg)
        return cond

    def count(self, category: str, cond: bool) -> None:
        """category ∈ files/field/hash/size/zip_entry/manifest/refs"""
        setattr(self, f"{category}_total", getattr(self, f"{category}_total") + 1)
        if cond:
            setattr(self, f"{category}_ok", getattr(self, f"{category}_ok") + 1)

    @property
    def failed(self) -> int:
        return len(self.problems)


# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------
def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_json(p: Path):
    return json.loads(p.read_text(encoding="utf-8"))


def load_taxonomy_tags(p: Path) -> set[str]:
    """从 data/taxonomy.json 的 main_tags 提取英文主标签 id 集合（数量动态，不硬编码）。"""
    data = read_json(p)
    raw = data.get("main_tags") or []
    tags = {
        str(t.get("id"))
        for t in raw
        if isinstance(t, dict) and isinstance(t.get("id"), str)
    }
    if not tags:
        raise ValueError(f"{p}: main_tags 无有效 id，无法构建标签白名单")
    return tags


def detect_root(path: Path) -> Path | None:
    """定位真正的内容根（支持发布仓库自动下钻 release/）。"""
    if (path / "manifest.json").is_file():
        return path
    if (path / "release" / "manifest.json").is_file():
        return path / "release"
    # 没有 manifest 但有模块索引时，仍按内容根处理（manifest 检查会跳过）
    if any((path / m / "index.json").is_file() for m in MODULES):
        return path
    return None


def short(p: Path, root: Path) -> str:
    try:
        return p.relative_to(root).as_posix()
    except ValueError:
        return p.as_posix()


# ---------------------------------------------------------------------------
# 各类核对
# ---------------------------------------------------------------------------
def check_size(rp: Report, base: Path, f: Path, expect: object, label: str) -> None:
    if expect is None:
        return
    actual = f.stat().st_size
    good = int(expect) == actual
    rp.count("size", good)
    rp.ok(good, f"[size] {label}: 清单 {expect} != 实际 {actual} ({short(f, base)})")


def check_hash(rp: Report, base: Path, f: Path, expect: str | None, label: str) -> None:
    if not expect:
        return
    actual = sha256_file(f)
    good = str(expect).strip().lower() == actual
    rp.count("hash", good)
    rp.ok(
        good,
        f"[hash] {label}: 不一致 ({short(f, base)})\n        期望 {expect}\n        实际 {actual}",
    )


def check_ref_suffix(
    rp: Report, base: Path, f: Path, val, key: str, label: str
) -> None:
    """发布流水线注入的 zipKey / zipUrls：末段必须与本地文件名一致。"""
    items = val if isinstance(val, list) else ([val] if isinstance(val, str) else [])
    for u in items:
        if not isinstance(u, str) or not u:
            continue
        good = u.rsplit("/", 1)[-1] == f.name
        rp.count("refs", good)
        rp.ok(good, f"[refs] {label}.{key} 末段 != 本地文件名 {f.name}: {u}")


def verify_zip_item(rp: Report, base: Path, module: str, it: dict) -> None:
    """events / collections / daily 的 zip 条目。"""
    name = str(it.get("id") or it.get("month") or "?")
    label = f"{module}/{name}"

    url = it.get("zipUrl")
    rp.count("field", isinstance(url, str) and bool(url))
    if not rp.ok(isinstance(url, str) and bool(url), f"[field] {label}: 缺 zipUrl"):
        return

    zp = base / module / url
    rp.count("files", zp.is_file())
    if not rp.ok(zp.is_file(), f"[files] {label}: zip 不存在 {url}"):
        return

    rp.count("field", it.get("zipSha256") is not None)
    rp.ok(it.get("zipSha256") is not None, f"[field] {label}: 缺 zipSha256")
    rp.count("field", it.get("fileSizeBytes") is not None)
    rp.ok(it.get("fileSizeBytes") is not None, f"[field] {label}: 缺 fileSizeBytes")

    check_size(rp, base, zp, it.get("fileSizeBytes"), label)
    check_hash(rp, base, zp, it.get("zipSha256"), label)

    # zip 完整性 + 条目数
    try:
        with zipfile.ZipFile(zp) as zf:
            bad = zf.testzip()
            rp.ok(bad is None, f"[zip] {label}: 损坏，首个坏条目 {bad}")
            names = [n for n in zf.namelist() if not n.endswith("/")]
            if it.get("totalCount") is not None:
                good = len(names) == int(it["totalCount"])
                rp.count("zip_entry", good)
                rp.ok(
                    good,
                    f"[zip] {label}: 条目 {len(names)} != totalCount {it['totalCount']}",
                )
            empty = [n for n in names if zf.getinfo(n).file_size == 0]
            rp.ok(not empty, f"[zip] {label}: 内含空文件 {empty[:3]}")
    except zipfile.BadZipFile as e:
        rp.ok(False, f"[zip] {label}: 无法打开 {e}")
        return

    if it.get("coverUrl"):
        cp = base / module / it["coverUrl"]
        rp.count("files", cp.is_file())
        rp.ok(cp.is_file(), f"[files] {label}: 封面不存在 {it['coverUrl']}")
        if cp.is_file():
            rp.ok(cp.stat().st_size > 0, f"[files] {label}: 封面为空 {it['coverUrl']}")

    for key in ("zipKey", "zipUrls"):
        if key in it:
            check_ref_suffix(rp, base, zp, it[key], key, label)


def verify_main_image(
    rp: Report, base: Path, bj: Path, it: dict, tag_whitelist: set[str] | None = None
) -> None:
    """main 散图条目。"""
    label = f"main/{it.get('id') or it.get('order') or '?'}"
    url = it.get("url")
    rp.count("field", isinstance(url, str) and bool(url))
    if not rp.ok(isinstance(url, str) and bool(url), f"[field] {label}: 缺 url"):
        return

    img = bj.parent / url
    rp.count("files", img.is_file())
    if not rp.ok(img.is_file(), f"[files] {label}: 图片不存在 {bj.parent.name}/{url}"):
        return

    rp.count("field", it.get("hash") is not None)
    rp.ok(it.get("hash") is not None, f"[field] {label}: 缺 hash")
    rp.count("field", it.get("fileSizeBytes") is not None)
    rp.ok(it.get("fileSizeBytes") is not None, f"[field] {label}: 缺 fileSizeBytes")

    rp.ok(img.stat().st_size > 0, f"[files] {label}: 图片为空")
    check_size(rp, base, img, it.get("fileSizeBytes"), label)
    check_hash(rp, base, img, it.get("hash"), label)

    check_tags(rp, label, it.get("tags"), tag_whitelist)


def check_tags(rp: Report, label: str, tags, whitelist: set[str] | None) -> None:
    """tags 检查：白名单未配置时跳过（不计数）；tags 允许空数组；非空时逐项必须在白名单。"""
    if whitelist is None:
        return
    if not isinstance(tags, list):
        rp.count("tags", False)
        rp.ok(False, f"[tags] {label}: tags 不是数组: {tags!r}")
        return
    bad = sorted({t for t in tags if not isinstance(t, str) or t not in whitelist})
    good = not bad
    rp.count("tags", good)
    rp.ok(
        good,
        f"[tags] {label}: 非白名单标签 {bad}"
        + ("（白名单见 data/taxonomy.json main_tags）" if bad else ""),
    )


def verify_root(
    path: Path, name: str | None = None, tag_whitelist: set[str] | None = None
) -> Report:
    root = detect_root(path)
    rp = Report(name or path.name, root or path)
    if root is None:
        rp.ok(
            False,
            f"[root] 未识别为内容根（缺 manifest.json 与任何模块 index.json）: {path}",
        )
        return rp

    for module in MODULES:
        idx_p = root / module / "index.json"
        if not idx_p.is_file():
            continue
        data = read_json(idx_p)

        if module == "main":
            # 形态一（现行）：items 为批次条目，指向 batches/{id}/index.json
            batch_urls = [
                it.get("url")
                for it in data.get("items", [])
                if isinstance(it, dict)
                and isinstance(it.get("url"), str)
                and it["url"].endswith(".json")
            ]
            if batch_urls:
                for b_url in batch_urls:
                    bj = root / module / b_url
                    rp.count("files", bj.is_file())
                    if not rp.ok(bj.is_file(), f"[files] main: 批次清单不存在 {b_url}"):
                        continue
                    for it in read_json(bj).get("items", []):
                        verify_main_image(rp, root, bj, it, tag_whitelist)
            else:
                # 形态二（legacy）：items 直接就是关卡
                for it in data.get("items", []):
                    verify_main_image(rp, root, idx_p, it, tag_whitelist)
        else:
            for it in data.get("items", []):
                verify_zip_item(rp, root, module, it)

    # manifest 自洽
    man_p = root / "manifest.json"
    if man_p.is_file():
        man = read_json(man_p)
        for m, entry in (man.get("modules") or {}).items():
            if not isinstance(entry, dict) or not entry.get("hash"):
                continue
            idx_p = root / m / "index.json"
            if not idx_p.is_file():
                continue
            good = entry["hash"] == hashlib.sha256(idx_p.read_bytes()).hexdigest()
            rp.count("manifest", good)
            rp.ok(good, f"[manifest] {m}.hash 与 {m}/index.json 不一致")

    return rp


# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------
def fmt(rp: Report) -> str:
    def line(title: str, ok_n: int, total_n: int, note: str = "") -> str:
        if total_n == 0:
            return f"  {title:<12} —（无此项）"
        mark = "✅" if ok_n == total_n else "❌"
        tail = f"{ok_n}/{total_n}" + (f"  {note}" if note else "")
        return f"  {mark} {title:<12} {tail}"

    out = [f"[{rp.name}]  {rp.root}"]
    out.append(line("引用文件", rp.files_ok, rp.files_total))
    out.append(line("字段完整", rp.field_ok, rp.field_total))
    out.append(line("内容哈希", rp.hash_ok, rp.hash_total))
    out.append(line("文件大小", rp.size_ok, rp.size_total))
    out.append(line("zip 条目数", rp.zip_entry_ok, rp.zip_entry_total))
    out.append(line("manifest", rp.manifest_ok, rp.manifest_total))
    if rp.refs_total:
        out.append(
            line("URL 引用", rp.refs_ok, rp.refs_total, "(zipKey/zipUrls 与本地文件名)")
        )
    if rp.tags_total:
        out.append(
            line("标签白名单", rp.tags_ok, rp.tags_total, "(taxonomy main_tags)")
        )
    out.append(
        f"  —— {'✅ 全部通过' if rp.failed == 0 else f'❌ {rp.failed} 项不一致'}"
    )
    return "\n".join(out)


def to_dict(rp: Report) -> dict:
    return {
        "name": rp.name,
        "root": str(rp.root),
        "files": [rp.files_ok, rp.files_total],
        "fields": [rp.field_ok, rp.field_total],
        "hash": [rp.hash_ok, rp.hash_total],
        "size": [rp.size_ok, rp.size_total],
        "zipEntries": [rp.zip_entry_ok, rp.zip_entry_total],
        "manifest": [rp.manifest_ok, rp.manifest_total],
        "refs": [rp.refs_ok, rp.refs_total],
        "tags": [rp.tags_ok, rp.tags_total],
        "problems": rp.problems,
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="python -m studio.verify_data",
        description="已导出内容目录体检：文件存在 / 字段完整 / 哈希 / 大小 / zip 条目数 / manifest 自洽 / tags 白名单",
    )
    ap.add_argument(
        "paths", nargs="+", help="内容根路径（或含 release/ 的发布仓库根），可多个"
    )
    ap.add_argument(
        "-v", "--verbose", action="store_true", help="打印全部问题（默认最多 20 条）"
    )
    ap.add_argument(
        "--json", action="store_true", dest="as_json", help="输出 JSON（供 CI 使用）"
    )
    ap.add_argument(
        "--taxonomy",
        metavar="PATH",
        default=None,
        help="data/taxonomy.json 路径（主标签白名单）；不传则按 ../data/taxonomy.json 自动探测，找不到则跳过 tags 校验",
    )
    args = ap.parse_args(argv)

    tag_whitelist: set[str] | None = None
    if args.taxonomy:
        try:
            tag_whitelist = load_taxonomy_tags(Path(args.taxonomy))
        except (OSError, ValueError, json.JSONDecodeError) as e:
            print(f"[taxonomy] 读取白名单失败: {e}")
            return 2
    else:
        auto = Path(sys.argv[0] if sys.argv and sys.argv[0] else __file__).resolve()
        for cand in (
            auto.parent.parent / "data" / "taxonomy.json",
            Path(__file__).resolve().parent.parent / "data" / "taxonomy.json",
        ):
            if cand.is_file():
                try:
                    tag_whitelist = load_taxonomy_tags(cand)
                except (OSError, ValueError, json.JSONDecodeError):
                    tag_whitelist = None
                break
        if tag_whitelist is None:
            print(
                "[taxonomy] 未找到 data/taxonomy.json，跳过 tags 白名单校验（可用 --taxonomy 指定）"
            )

    reports = [verify_root(Path(p), tag_whitelist=tag_whitelist) for p in args.paths]

    if args.as_json:
        print(json.dumps([to_dict(r) for r in reports], ensure_ascii=False, indent=2))
    else:
        for rp in reports:
            print(fmt(rp))
            if rp.failed:
                shown = rp.problems if args.verbose else rp.problems[:20]
                for m in shown:
                    print("     " + m)
                if not args.verbose and rp.failed > len(shown):
                    print(f"     ... 另有 {rp.failed - len(shown)} 条（-v 查看全部）")
            print()

    bad = sum(r.failed for r in reports)
    total_checks = sum(r.total_n for r in reports)
    if args.as_json:
        return 1 if bad else 0
    print(
        f"共 {len(reports)} 个目录，{total_checks} 项检查："
        + ("✅ 全部通过" if bad == 0 else f"❌ {bad} 项不一致")
    )
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
