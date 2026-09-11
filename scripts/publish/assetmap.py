#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
assetmap.py — 多平台 assets 的 key↔URL 映射唯一逻辑（发布脚本与 app 端语义必须一致）

核心约定
--------
1. dist 产物里所有引用都写成 relative canonical key（相对 dist 根的路径），
   永不写平台绝对地址。平台差异完全收敛到 channels.json。
2. canonical key 范例：
     manifest.json
     main/index.json
     main/images/101.webp
     daily/zips/202609.zip
     events/packs/evt_ocean_adventure.zip
3. key -> URL 算法（与 app 端 dart 实现等价）：
     a. 取 key 所在“所在索引文件”的 key（如 daily/index.json 管辖 daily/zips/*），
        用 rules[].prefixSets 找第一条前缀命中的规则；否则用默认规则(base=channel.base, layout=preserve)。
     b. layout==preserve -> rule.base + key
     c. layout==flatten -> rule.base + basename(key)
   base 中的 {tag} 占位符在运行时替换为 releaseTag。

使用
----
  from assetmap import load_channels, key_to_url, Channel, scan_dist_keys
  ch = load_channels()[0]
  url = key_to_url(ch, "daily/zips/202609.zip")   # 按 channel 的 zip 规则展开
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
CHANNELS_JSON = HERE / "channels.json"


# ----------------------------- 数据模型 -----------------------------
@dataclass
class Rule:
    base: str
    layout: str  # 'preserve' | 'flatten'
    prefixes: list[str]


@dataclass
class Channel:
    id: str
    label: str = ""
    base: str = ""
    rules: list[Rule] = field(default_factory=list)
    cn_rank: int = 0
    global_rank: int = 0
    publish: dict = field(default_factory=dict)
    notes: Any = None
    disabled: bool = False
    manifest_backup: bool = False

    def key_to_url(self, key: str, tag: str) -> str:
        rule = self._match_rule(key)
        base = rule.base.replace("{tag}", tag)
        if rule.layout == "flatten":
            return base + Path(key).name
        return base + key

    def _match_rule(self, key: str) -> Rule:
        for r in self.rules:
            if any(key.startswith(p) for p in r.prefixes):
                return r
        return Rule(base=self.base, layout="preserve", prefixes=[])


# ----------------------------- 加载 -----------------------------
def load_channels(path: Path | None = None) -> list[Channel]:
    env_path = os.environ.get("JIGSAW_CHANNELS_JSON")
    p = path or (Path(env_path) if env_path else CHANNELS_JSON)
    doc = json.loads(Path(p).read_text(encoding="utf-8"))
    prefix_sets = doc.get("prefixSets", {})
    channels: list[Channel] = []
    for c in doc["channels"]:
        rules: list[Rule] = []
        for r in c.get("rules", []):
            pres: list[str] = []
            for s in r.get("prefixes", []) or []:
                pres.extend(prefix_sets.get(s, [s]))
            rules.append(
                Rule(base=r["base"], layout=r.get("layout", "preserve"), prefixes=pres)
            )
        channels.append(
            Channel(
                id=c["id"],
                label=c.get("label", ""),
                base=c["base"],
                rules=rules,
                cn_rank=int(c.get("cn", 0)),
                global_rank=int(c.get("global", 0)),
                publish=c.get("publish", {}),
                notes=c.get("notes"),
                disabled=bool(c.get("disabled", False)),
                manifest_backup=bool(c.get("manifestBackup", False)),
            )
        )
    return channels


def load_doc(path: Path | None = None) -> dict:
    env_path = os.environ.get("JIGSAW_CHANNELS_JSON")
    target = Path(path or (env_path if env_path else CHANNELS_JSON))
    return json.loads(target.read_text(encoding="utf-8"))


# ----------------------------- key 空间工具 -----------------------------
_ZIP_RE = re.compile(r"(?:zips|packs)/[^/]+\.zip$")


def is_zip_key(key: str) -> bool:
    return bool(_ZIP_RE.search(key))


def scan_dist_keys(
    dist_root: str | Path, exclude_names: list[str] | None = None
) -> list[str]:
    """枚举 dist 内所有可发布的 canonical key（POSIX 相对路径）。"""
    root = Path(dist_root)
    excl = set(exclude_names or [])
    keys: list[str] = []
    for f in root.rglob("*"):
        if not f.is_file():
            continue
        rel = f.relative_to(root).as_posix()
        if any(part in excl for part in rel.split("/")):
            continue
        keys.append(rel)
    return sorted(keys)


def resolve_relative(base_key: str, ref: str) -> str:
    """把 ref（可能是相对或绝对）解析到相对于 dist 根的 canonical key。"""
    if not ref:
        return base_key
    if ref.startswith("/"):
        return ref.lstrip("/")
    b = Path(base_key)
    return (b.parent / ref).as_posix()


def check_flatten_collisions(keys: list[str]) -> list[tuple[str, list[str]]]:
    """flatten 通道下只看 basename，检查是否有相撞的 key。"""
    by_base: dict[str, list[str]] = {}
    for k in keys:
        if is_zip_key(k):
            by_base.setdefault(Path(k).name, []).append(k)
    return [(b, ks) for b, ks in by_base.items() if len(ks) > 1]


# ----------------------------- 便捷：按区域排序 -----------------------------
def ordered_channels(channels: list[Channel], region: str = "cn") -> list[Channel]:
    key = (lambda c: c.cn_rank) if region == "cn" else (lambda c: c.global_rank)
    return [c for c in sorted(channels, key=key) if key(c) > 0]


def mirrors_for_zip(
    channels: list[Channel], canonical_zip_key: str, tag: str, region: str = "cn"
) -> list[str]:
    """按区域顺序展开 zip 的候选 URL 列表（用于 app 端 zipUrls 合成 / 巡检）。"""
    out: list[str] = []
    for c in ordered_channels(channels, region):
        u = c.key_to_url(canonical_zip_key, tag)
        if u not in out:
            out.append(u)
    return out
