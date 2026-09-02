#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""拼图素材批次质检报告（可复用于任意 v5 输出目录）。

输出四张表并导出 JSON 与 HTML 报告：
  A. 整体 + 分 tag 质检分布（对照 docs/puzzle-image-selection-standard.md §1 速查卡）
  B. modifier 去混淆归因（tag 内差值 Δ_adj，消除 tag 基线混淆）
  C. reseed 方差（同 prompt 不同 seed 的分数差）
  D. 批次时间线（按 metadata 的 ts 还原脚本调整历史）

用法:
  python scripts/jigsaw_qa_report.py <out_dir>
  python scripts/jigsaw_qa_report.py --input <out_dir> --output <report_dir>
"""
from __future__ import annotations

import argparse
import html
import json
import os
import statistics
import sys
import time
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIB = ROOT / "scripts" / "my_prompt_library_v5.json"

sys.path.insert(0, str(ROOT / "scripts"))
import puzzle_quality_analyzer as pqa  # noqa: E402


def load_vocab() -> dict[str, list[str]]:
    v = {"lighting": set(), "viewpoint": set(), "atmosphere": set(), "style": set()}
    for lib_file in [
        ROOT / "scripts" / "my_prompt_library_illust_v5.json",
        ROOT / "scripts" / "my_prompt_library_v5.json",
        ROOT / "scripts" / "my_prompt_library_v4.json",
    ]:
        if lib_file.exists():
            try:
                lib = json.loads(lib_file.read_text(encoding="utf-8"))
                for mod in ["lighting", "viewpoint", "atmosphere"]:
                    v[mod].update(lib.get("modifiers", {}).get(mod, []))
                for pool in lib.get("style_pools", {}).values():
                    v["style"].update(pool)
            except Exception:
                pass
    return {k: sorted(vals) for k, vals in v.items()}


def generate_html_report(data: dict) -> str:
    summary = data["summary"]
    tag_rows = data["by_tag"]
    attr_data = data["modifiers_attribution"]
    reseed_info = data["reseed_variance"]
    timeline_info = data["timeline"]
    thresholds = data["threshold_pass_rates"]

    # 生成各 Tag 行 HTML
    tag_trs = []
    for t in tag_rows:
        bad_badges = "".join([f'<span class="px-1.5 py-0.5 rounded text-xs bg-red-900/60 text-red-200 border border-red-700/50 mr-1">{b}</span>' for b in t["bad_indicators"]]) or '<span class="text-slate-500">—</span>'
        tag_trs.append(f"""
        <tr class="hover:bg-slate-800/50 border-b border-slate-800/80 transition-colors">
          <td class="px-3 py-2 font-medium text-slate-200">{html.escape(t['tag'])}</td>
          <td class="px-3 py-2 text-right">{t['count']}</td>
          <td class="px-3 py-2 text-right font-bold text-amber-400">{t['avg_score']:.1f}</td>
          <td class="px-3 py-2 text-right text-emerald-400">{t['grades']['S']}</td>
          <td class="px-3 py-2 text-right text-sky-400">{t['grades']['A']}</td>
          <td class="px-3 py-2 text-right text-yellow-400">{t['grades']['B']}</td>
          <td class="px-3 py-2 text-right text-orange-400">{t['grades']['C']}</td>
          <td class="px-3 py-2 text-right text-rose-500 font-bold">{t['grades']['F']}</td>
          <td class="px-3 py-2 text-right {'text-red-400 font-semibold' if t['core_dead_pct'] > 8 else 'text-slate-300'}">{t['core_dead_pct']:.1f}%</td>
          <td class="px-3 py-2 text-right {'text-red-400 font-semibold' if t['laplacian'] < 300 else 'text-slate-300'}">{t['laplacian']:.0f}</td>
          <td class="px-3 py-2 text-right {'text-red-400 font-semibold' if t['entropy'] < 2.6 else 'text-slate-300'}">{t['entropy']:.2f}</td>
          <td class="px-3 py-2 text-right {'text-red-400 font-semibold' if t['balance'] < 60 else 'text-slate-300'}">{t['balance']:.1f}</td>
          <td class="px-3 py-2">{bad_badges}</td>
        </tr>
        """)

    # 生成 Modifier 归因卡片
    attr_sections = []
    for cat, items in attr_data.items():
        if not items:
            continue
        trs = []
        for it in items:
            tag_class = "text-slate-400"
            badge = ""
            if it["adj"] > 3.0:
                tag_class = "text-emerald-400 font-semibold"
                badge = '<span class="ml-2 px-1.5 py-0.5 rounded text-xs bg-emerald-900/60 text-emerald-200 border border-emerald-700/50">🚀 优质</span>'
            elif it["adj"] < -3.0:
                tag_class = "text-rose-400 font-semibold"
                badge = '<span class="ml-2 px-1.5 py-0.5 rounded text-xs bg-rose-900/60 text-rose-200 border border-rose-700/50">⚠️ 拖分</span>'

            trs.append(f"""
            <tr class="hover:bg-slate-800/40 border-b border-slate-800/50">
              <td class="px-3 py-1.5 font-mono text-xs text-slate-300 truncate max-w-xs">{html.escape(it['word'])}{badge}</td>
              <td class="px-3 py-1.5 text-right">{it['count']}</td>
              <td class="px-3 py-1.5 text-right text-slate-300">{it['raw']:+.1f}</td>
              <td class="px-3 py-1.5 text-right {tag_class}">{it['adj']:+.1f}</td>
              <td class="px-3 py-1.5 text-right text-slate-400">{it['core_dead_pct']:.1f}%</td>
              <td class="px-3 py-1.5 text-right text-slate-400">{it['laplacian']:.0f}</td>
              <td class="px-3 py-1.5 text-right text-slate-400">{it['entropy']:.2f}</td>
            </tr>
            """)
        
        attr_sections.append(f"""
        <div class="bg-slate-900/70 border border-slate-800 rounded-xl p-4 mb-4">
          <h3 class="text-md font-bold text-sky-400 mb-2 flex items-center capitalize">
            <span class="w-2 h-2 rounded-full bg-sky-400 mr-2"></span>{cat}
          </h3>
          <div class="overflow-x-auto">
            <table class="w-full text-xs text-left">
              <thead class="text-slate-400 border-b border-slate-800">
                <tr>
                  <th class="px-3 py-1.5">修饰词</th>
                  <th class="px-3 py-1.5 text-right">频次</th>
                  <th class="px-3 py-1.5 text-right">Δ_raw</th>
                  <th class="px-3 py-1.5 text-right">Δ_adj (消偏)</th>
                  <th class="px-3 py-1.5 text-right">死区%</th>
                  <th class="px-3 py-1.5 text-right">锐度</th>
                  <th class="px-3 py-1.5 text-right">色相熵</th>
                </tr>
              </thead>
              <tbody>
                {''.join(trs)}
              </tbody>
            </table>
          </div>
        </div>
        """)

    # 时间线行
    timeline_trs = []
    for t in timeline_info:
        timeline_trs.append(f"""
        <tr class="hover:bg-slate-800/40 border-b border-slate-800/60 text-xs">
          <td class="px-3 py-2 font-mono text-slate-300">{html.escape(t['time_slot'])}</td>
          <td class="px-3 py-2 text-right">{t['count']}</td>
          <td class="px-3 py-2 text-right font-bold text-amber-400">{t['avg_score']:.1f}</td>
          <td class="px-3 py-2 text-right text-slate-300">{html.escape(str(t['steps']))}</td>
          <td class="px-3 py-2 text-right text-slate-300">{html.escape(str(t['cfg']))}</td>
          <td class="px-3 py-2 text-slate-400 truncate max-w-sm">{html.escape(', '.join(t['tags']))}</td>
        </tr>
        """)

    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>🧩 拼图批次质量与归因报告 · Jigsaw QA Report</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <style>
    body {{
      background: #0b1120;
      color: #f8fafc;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
    }}
  </style>
</head>
<body class="p-6 md:p-10 max-w-7xl mx-auto">
  <header class="mb-8 border-b border-slate-800 pb-6">
    <div class="flex flex-col md:flex-row justify-between items-start md:items-center gap-4">
      <div>
        <h1 class="text-2xl font-bold tracking-tight text-white flex items-center">
          <span class="mr-3 text-3xl">🧩</span>拼图批次质检与归因深度报告
        </h1>
        <p class="text-slate-400 text-sm mt-1 font-mono">{html.escape(summary['source_directory'])}</p>
      </div>
      <div class="text-xs text-slate-400 bg-slate-900 px-3 py-2 rounded-lg border border-slate-800">
        生成时间: <span class="text-slate-200">{summary['generated_at']}</span>
      </div>
    </div>
    
    <!-- KPI 看板 -->
    <div class="grid grid-cols-2 md:grid-cols-5 gap-3 mt-6">
      <div class="bg-slate-900/80 border border-slate-800 p-4 rounded-xl">
        <div class="text-xs text-slate-400">总样本数</div>
        <div class="text-2xl font-bold text-white mt-1">{summary['total_samples']} 张</div>
        <div class="text-xs text-slate-500 mt-0.5">{len(tag_rows)} 个分类</div>
      </div>
      <div class="bg-slate-900/80 border border-slate-800 p-4 rounded-xl">
        <div class="text-xs text-slate-400">总体加权均分</div>
        <div class="text-2xl font-bold text-amber-400 mt-1">{summary['overall_average_score']:.1f}</div>
        <div class="text-xs text-slate-500 mt-0.5">满分 100</div>
      </div>
      <div class="bg-slate-900/80 border border-slate-800 p-4 rounded-xl">
        <div class="text-xs text-slate-400">可入库率 (S+A)</div>
        <div class="text-2xl font-bold text-emerald-400 mt-1">{summary['pass_rate_sa']:.1f}%</div>
        <div class="text-xs text-slate-500 mt-0.5">{summary['grades']['S'] + summary['grades']['A']} 张优选</div>
      </div>
      <div class="bg-slate-900/80 border border-slate-800 p-4 rounded-xl">
        <div class="text-xs text-slate-400">淘汰率 (F 级)</div>
        <div class="text-2xl font-bold {'text-rose-500' if summary['fail_rate_f'] > 0 else 'text-slate-300'} mt-1">{summary['fail_rate_f']:.1f}%</div>
        <div class="text-xs text-slate-500 mt-0.5">{summary['grades']['F']} 张死区/模糊</div>
      </div>
      <div class="bg-slate-900/80 border border-slate-800 p-4 rounded-xl">
        <div class="text-xs text-slate-400">评级分布</div>
        <div class="text-xs text-slate-300 mt-2 flex justify-between">
          <span class="text-emerald-400 font-bold">S: {summary['grades']['S']}</span>
          <span class="text-sky-400">A: {summary['grades']['A']}</span>
          <span class="text-yellow-400">B: {summary['grades']['B']}</span>
          <span class="text-orange-400">C: {summary['grades']['C']}</span>
        </div>
      </div>
    </div>

    <!-- 四大门槛达标率 -->
    <div class="mt-4 grid grid-cols-2 md:grid-cols-4 gap-2 text-xs">
      <div class="bg-slate-900/40 border border-slate-800/80 px-3 py-2 rounded-lg flex justify-between">
        <span class="text-slate-400">核心死区 ≤ 8%:</span>
        <span class="font-bold text-emerald-400">{thresholds['core_dead_pass_pct']:.1f}% 达标</span>
      </div>
      <div class="bg-slate-900/40 border border-slate-800/80 px-3 py-2 rounded-lg flex justify-between">
        <span class="text-slate-400">Laplacian ≥ 300:</span>
        <span class="font-bold text-emerald-400">{thresholds['laplacian_pass_pct']:.1f}% 达标</span>
      </div>
      <div class="bg-slate-900/40 border border-slate-800/80 px-3 py-2 rounded-lg flex justify-between">
        <span class="text-slate-400">色相熵 ≥ 2.6:</span>
        <span class="font-bold text-emerald-400">{thresholds['entropy_pass_pct']:.1f}% 达标</span>
      </div>
      <div class="bg-slate-900/40 border border-slate-800/80 px-3 py-2 rounded-lg flex justify-between">
        <span class="text-slate-400">空间均衡 ≥ 60:</span>
        <span class="font-bold text-emerald-400">{thresholds['balance_pass_pct']:.1f}% 达标</span>
      </div>
    </div>
  </header>

  <!-- 模块 A: 质检分布 -->
  <section class="mb-10">
    <h2 class="text-lg font-bold text-white mb-3 flex items-center">
      <span class="text-xl mr-2">📊</span>A. 整体与分 Tag 质检分布
    </h2>
    <div class="overflow-x-auto rounded-xl border border-slate-800 bg-slate-900/60">
      <table class="w-full text-xs text-left">
        <thead class="bg-slate-900/90 text-slate-400 border-b border-slate-800 uppercase tracking-wider">
          <tr>
            <th class="px-3 py-3">Tag 分类</th>
            <th class="px-3 py-3 text-right">数量</th>
            <th class="px-3 py-3 text-right">均分</th>
            <th class="px-3 py-3 text-right text-emerald-400">S</th>
            <th class="px-3 py-3 text-right text-sky-400">A</th>
            <th class="px-3 py-3 text-right text-yellow-400">B</th>
            <th class="px-3 py-3 text-right text-orange-400">C</th>
            <th class="px-3 py-3 text-right text-rose-400">F</th>
            <th class="px-3 py-3 text-right">核心死区</th>
            <th class="px-3 py-3 text-right">锐度Lap</th>
            <th class="px-3 py-3 text-right">色相熵</th>
            <th class="px-3 py-3 text-right">空间均衡</th>
            <th class="px-3 py-3">不达标卡点</th>
          </tr>
        </thead>
        <tbody>
          {''.join(tag_trs)}
        </tbody>
      </table>
    </div>
  </section>

  <!-- 模块 B: Modifier 去混淆归因 -->
  <section class="mb-10">
    <h2 class="text-lg font-bold text-white mb-2 flex items-center">
      <span class="text-xl mr-2">🧪</span>B. Modifier 增益/拖分去混淆归因
    </h2>
    <p class="text-xs text-slate-400 mb-4">
      消除不同 Tag 本身题材基线得分高低的混淆，采用 Tag 内部差值（Δ_adj）。Δ_adj > +3 为显著优质词，Δ_adj < -3 为拖分词。
    </p>
    <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
      {''.join(attr_sections)}
    </div>
  </section>

  <!-- 模块 C & D: Reseed 与 时间线 -->
  <div class="grid grid-cols-1 md:grid-cols-2 gap-6 mb-10">
    <!-- C: Reseed 方差 -->
    <section class="bg-slate-900/60 border border-slate-800 rounded-xl p-5">
      <h2 class="text-md font-bold text-white mb-3 flex items-center">
        <span class="text-lg mr-2">🎲</span>C. Reseed 收益与极差方差
      </h2>
      <div class="space-y-2 text-xs text-slate-300">
        <div class="flex justify-between py-1 border-b border-slate-800/80">
          <span class="text-slate-400">同 Prompt Reseed 组数:</span>
          <span class="font-bold">{reseed_info.get('multi_count', 0)} 组</span>
        </div>
        <div class="flex justify-between py-1 border-b border-slate-800/80">
          <span class="text-slate-400">组内极差 (均值 / 中位 / 最大):</span>
          <span>{reseed_info.get('diff_mean', 0):.1f} / {reseed_info.get('diff_median', 0):.1f} / {reseed_info.get('diff_max', 0):.0f}</span>
        </div>
        <div class="flex justify-between py-1 border-b border-slate-800/80">
          <span class="text-slate-400">取组内最优 vs 总体提升:</span>
          <span class="text-emerald-400 font-bold">{reseed_info.get('best_mean', 0):.1f} (+{reseed_info.get('gain_vs_overall', 0):.1f})</span>
        </div>
        <div class="flex justify-between py-1">
          <span class="text-slate-400">极差 ≥ 10 分大波动组占比:</span>
          <span class="{'text-amber-400 font-bold' if reseed_info.get('big_diff_pct', 0) > 20 else 'text-slate-400'}">{reseed_info.get('big_diff_pct', 0):.1f}%</span>
        </div>
      </div>
    </section>

    <!-- D: 时间线 -->
    <section class="bg-slate-900/60 border border-slate-800 rounded-xl p-5">
      <h2 class="text-md font-bold text-white mb-3 flex items-center">
        <span class="text-lg mr-2">⏱️</span>D. 批次时间线与参数一致性
      </h2>
      <div class="overflow-x-auto max-h-44 overflow-y-auto">
        <table class="w-full text-xs text-left">
          <thead class="text-slate-400 border-b border-slate-800">
            <tr>
              <th class="px-3 py-1.5">时段</th>
              <th class="px-3 py-1.5 text-right">张数</th>
              <th class="px-3 py-1.5 text-right">均分</th>
              <th class="px-3 py-1.5 text-right">steps</th>
              <th class="px-3 py-1.5 text-right">cfg</th>
              <th class="px-3 py-1.5">涉及 Tag</th>
            </tr>
          </thead>
          <tbody>
            {''.join(timeline_trs)}
          </tbody>
        </table>
      </div>
    </section>
  </div>

  <footer class="text-center text-xs text-slate-500 pt-6 border-t border-slate-800">
    Jigsaw Puzzle Quality Assurance Pipeline v5 · Generated automatically by jigsaw_qa_report.py
  </footer>
</body>
</html>
"""


def parse_args():
    parser = argparse.ArgumentParser(description="拼图素材批次质检报告（输出终端分析、JSON 及 HTML 报告）")
    parser.add_argument("input", nargs="?", default=None, help="批次图片源目录 (含 _metadata/*.jsonl)")
    parser.add_argument("-i", "--input-dir", dest="input_opt", help="批次图片源目录")
    parser.add_argument("-o", "--output", "--output-dir", dest="output", default=None, help="报告输出目录 (默认与 input 目录一致)")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    raw_src = args.input_opt or args.input
    if not raw_src:
        print("用法: python scripts/jigsaw_qa_report.py <out_dir> [--output <report_dir>]")
        return 2

    src = Path(raw_src)
    if not src.exists():
        print(f"[fatal] 目录不存在: {src}")
        return 2

    if args.output:
        out_dir = Path(args.output)
    else:
        out_dir = src
    out_dir.mkdir(parents=True, exist_ok=True)

    vocab = load_vocab()
    engine = pqa.PhysicalQualityEngine(grid_rows=8, grid_cols=8, embed_thumbnails=False)

    meta: dict[str, dict] = {}
    for jf in sorted((src / "_metadata").glob("*.jsonl")):
        for line in jf.read_text(encoding="utf-8").splitlines():
            if line.strip():
                try:
                    r = json.loads(line)
                    meta[r["filename"]] = r
                except json.JSONDecodeError:
                    pass

    rows = []
    for f in sorted(src.rglob("*.png")) + sorted(src.rglob("*.jpg")) + sorted(src.rglob("*.webp")):
        # 跳过报告生成的相关资源
        if "report" in f.name.lower():
            continue
        rep = engine.analyze_physical(f, base_dir=src)
        if rep is None:
            continue
        m = meta.get(f.name, {})
        rows.append(
            {
                "tag": f.parent.name if f.parent != src else m.get("tag", "Default"),
                "file": f.name,
                "key": m.get("key", f.stem),
                "prompt": m.get("prompt", ""),
                "seed": m.get("seed", 0),
                "ts": m.get("ts", ""),
                "steps": m.get("steps", None),
                "cfg": m.get("cfg", None),
                "score": rep.playability_score,
                "grade": rep.grade,
                "core_dead": rep.core_dead_ratio,
                "lap": rep.sharpness_score,
                "entropy": getattr(rep, "color_entropy", 0.0),
                "balance": rep.spatial_balance_score,
            }
        )

    if not rows:
        print(f"[fatal] 在 {src} 中未扫描到任何有效图片素材或分析结果为空")
        return 2

    n = len(rows)
    overall = statistics.mean([r["score"] for r in rows])
    by_tag: dict[str, list] = defaultdict(list)
    for r in rows:
        by_tag[r["tag"]].append(r)

    print(f"批次源路径: {src.resolve()}")
    print(f"报告输出路径: {out_dir.resolve()}")
    print(f"有效样本: {n} 张 / {len(by_tag)} 个分类    总体加权均分: {overall:.1f}\n")

    # ---------- A. 质检分布 ----------
    print("=" * 100)
    print("A. 质检分布（对照 selection-standard §1 速查卡：死区≤8% / Lap≥300 / 熵≥2.6 / 均衡≥60）")
    print("=" * 100)
    hdr = (
        f"{'tag':<16}{'n':>4}{'均分':>7}{'S':>4}{'A':>4}{'B':>4}{'C':>4}{'F':>4}"
        f"{'死区%':>7}{'Lap':>9}{'熵':>6}{'均衡':>7}  卡点"
    )
    print(hdr)
    print("-" * 100)

    by_tag_data = []

    def line(tag_name: str, rs: list, record: bool = True) -> None:
        g = {"S": 0, "A": 0, "B": 0, "C": 0, "F": 0}
        for r in rs:
            gr = r.get("grade", "F")
            g[gr] = g.get(gr, 0) + 1
        cd = statistics.mean([r["core_dead"] for r in rs]) * 100
        lv = statistics.mean([r["lap"] for r in rs])
        ce = statistics.mean([r["entropy"] for r in rs])
        sb = statistics.mean([r["balance"] for r in rs])
        bad = []
        if cd > 8:
            bad.append("死区")
        if lv < 300:
            bad.append("锐度")
        if ce < 2.6:
            bad.append("色相熵")
        if sb < 60:
            bad.append("均衡")
        score_avg = statistics.mean([r['score'] for r in rs])
        print(
            f"{tag_name:<16}{len(rs):>4}{score_avg:>7.1f}"
            f"{g['S']:>4}{g['A']:>4}{g['B']:>4}{g['C']:>4}{g['F']:>4}"
            f"{cd:>6.1f}{'✗' if cd > 8 else ' '}{lv:>8.0f}{'✗' if lv < 300 else ' '}"
            f"{ce:>5.2f}{'✗' if ce < 2.6 else ' '}{sb:>6.1f}{'✗' if sb < 60 else ' '}"
            f"   {','.join(bad) or '—'}"
        )
        if record:
            by_tag_data.append({
                "tag": tag_name,
                "count": len(rs),
                "avg_score": score_avg,
                "grades": dict(g),
                "core_dead_pct": cd,
                "laplacian": lv,
                "entropy": ce,
                "balance": sb,
                "bad_indicators": bad
            })

    for tag in sorted(by_tag, key=lambda t: -statistics.mean([r["score"] for r in by_tag[t]])):
        line(tag, by_tag[tag])
    print("-" * 100)
    line("TOTAL", rows, record=False)

    print("\n四项硬门槛达标率：")
    checks = [
        ("核心死区 ≤ 8%", [r["core_dead"] for r in rows], 0.08, "le", "{:.2f}"),
        ("Laplacian ≥ 300", [r["lap"] for r in rows], 300.0, "ge", "{:.0f}"),
        ("色相熵 ≥ 2.6", [r["entropy"] for r in rows], 2.6, "ge", "{:.2f}"),
        ("空间均衡 ≥ 60", [r["balance"] for r in rows], 60.0, "ge", "{:.1f}"),
    ]
    threshold_pass_rates = {}
    key_mapping = {
        "核心死区 ≤ 8%": "core_dead_pass_pct",
        "Laplacian ≥ 300": "laplacian_pass_pct",
        "色相熵 ≥ 2.6": "entropy_pass_pct",
        "空间均衡 ≥ 60": "balance_pass_pct"
    }
    for name, vals, thr, op, fmt in checks:
        ok = sum(1 for v in vals if (v <= thr if op == "le" else v >= thr))
        pct = ok / n * 100
        threshold_pass_rates[key_mapping[name]] = pct
        print(
            f"  {name:<20} 达标 {ok:>4}/{n} ({pct:5.1f}%)   "
            f"中位 {fmt.format(statistics.median(vals))}   "
            f"P10 {fmt.format(sorted(vals)[int(n * 0.1)])}   P90 {fmt.format(sorted(vals)[int(n * 0.9)])}"
        )
    gs = {"S": 0, "A": 0, "B": 0, "C": 0, "F": 0}
    for r in rows:
        gr = r.get("grade", "F")
        gs[gr] = gs.get(gr, 0) + 1
    sa_rate = (gs['S'] + gs['A']) / n * 100
    f_rate = gs['F'] / n * 100
    print(f"\n  可入库率 (S+A): {sa_rate:.1f}%     淘汰率 (F): {f_rate:.1f}%")

    # ---------- B. Modifier 去混淆归因 ----------
    print("\n" + "=" * 100)
    print("B. modifier 去混淆归因  Δ_raw=含词均分-总均分   Δ_adj=tag 内差值均值（已消混淆，更可信）")
    print("=" * 100)
    attr_data = {}
    for cat, words in vocab.items():
        buckets: dict[str, list] = defaultdict(list)
        for r in rows:
            for w in words:
                if w in r["prompt"]:
                    buckets[w].append(r)
        print(f"\n[{cat}]   {'取值':<58}{'n':>4}{'Δ_raw':>8}{'Δ_adj':>8}{'死区%':>7}{'Lap':>7}{'熵':>6}")
        out = []
        cat_items = []
        for w, hit in buckets.items():
            if not hit:
                continue
            raw = statistics.mean([r["score"] for r in hit]) - overall
            adjs = []
            for t, rs in by_tag.items():
                inn = [r["score"] for r in rs if w in r["prompt"]]
                out_ = [r["score"] for r in rs if w not in r["prompt"]]
                if inn and out_:
                    adjs.append(statistics.mean(inn) - statistics.mean(out_))
            adj_val = statistics.mean(adjs) if adjs else 0.0
            cd_val = statistics.mean([r["core_dead"] for r in hit]) * 100
            lv_val = statistics.mean([r["lap"] for r in hit])
            ce_val = statistics.mean([r["entropy"] for r in hit])
            out.append((adj_val, w, len(hit), raw, cd_val, lv_val, ce_val))
            cat_items.append({
                "word": w,
                "count": len(hit),
                "raw": raw,
                "adj": adj_val,
                "core_dead_pct": cd_val,
                "laplacian": lv_val,
                "entropy": ce_val,
                "is_good": adj_val > 3.0,
                "is_bad": adj_val < -3.0
            })
        cat_items.sort(key=lambda x: x["adj"], reverse=True)
        attr_data[cat] = cat_items

        for adj, w, cnt, raw, cd, lv, ce in sorted(out):
            mark = "  <== 拖分" if adj < -3 else ("  <== 优质" if adj > 3 else "")
            print(f"  {w[:56]:<58}{cnt:>4}{raw:>+8.1f}{adj:>+8.1f}{cd:>7.1f}{lv:>7.0f}{ce:>6.2f}{mark}")

    # ---------- C. Reseed 方差 ----------
    print("\n" + "=" * 100)
    print("C. reseed 方差（同 prompt 不同 seed）")
    print("=" * 100)
    pairs: dict[str, list] = defaultdict(list)
    for r in rows:
        pairs[r["key"].rsplit(":r", 1)[0]].append(r)
    multi = {k: v for k, v in pairs.items() if len(v) >= 2}
    reseed_info = {}
    if multi:
        diffs = [max(x["score"] for x in v) - min(x["score"] for x in v) for v in multi.values()]
        best = [max(x["score"] for x in v) for v in multi.values()]
        worst = [min(x["score"] for x in v) for v in multi.values()]
        big = sum(1 for d in diffs if d >= 10)
        reseed_info = {
            "multi_count": len(multi),
            "diff_mean": statistics.mean(diffs),
            "diff_median": statistics.median(diffs),
            "diff_max": max(diffs),
            "best_mean": statistics.mean(best),
            "gain_vs_overall": statistics.mean(best) - overall,
            "worst_mean": statistics.mean(worst),
            "big_diff_count": big,
            "big_diff_pct": big / len(diffs) * 100
        }
        print(f"  同 prompt 组数        : {len(multi)}")
        print(f"  组内极差 均值/中位/最大: {reseed_info['diff_mean']:.1f} / {reseed_info['diff_median']:.1f} / {reseed_info['diff_max']:.0f}")
        print(f"  取组内最好 → 均分     : {reseed_info['best_mean']:.1f}  (当前 {overall:.1f}, +{reseed_info['gain_vs_overall']:.1f})")
        print(f"  取组内最差 → 均分     : {reseed_info['worst_mean']:.1f}")
        print(f"  极差 ≥10 分组占比     : {big}/{len(diffs)} ({reseed_info['big_diff_pct']:.0f}%)")
    else:
        reseed_info = {
            "multi_count": 0,
            "diff_mean": 0.0,
            "diff_median": 0.0,
            "diff_max": 0.0,
            "best_mean": overall,
            "gain_vs_overall": 0.0,
            "worst_mean": overall,
            "big_diff_count": 0,
            "big_diff_pct": 0.0
        }
        print("  无 reseed>1 的样本（每组仅 1 张）")

    # ---------- D. 时间线 ----------
    print("\n" + "=" * 100)
    print("D. 批次时间线（按 metadata ts，还原脚本调整历史）")
    print("=" * 100)
    by_ts: dict[str, list] = defaultdict(list)
    for r in rows:
        ts_key = r["ts"][:13] if r["ts"] else "未记录"
        by_ts[ts_key].append(r)
    print(f"  {'时段':<16}{'张数':>5}{'均分':>7}{'steps':>7}{'cfg':>6}   涉及 tag")
    timeline_list = []
    for ts in sorted(by_ts):
        rs = by_ts[ts]
        tags = sorted({r["tag"] for r in rs})
        st = {r["steps"] for r in rs if r["steps"] is not None}
        cf = {r["cfg"] for r in rs if r["cfg"] is not None}
        avg_s = statistics.mean([r['score'] for r in rs])
        print(
            f"  {ts:<16}{len(rs):>5}{avg_s:>7.1f}"
            f"{str(sorted(st))[:7]:>7}{str(sorted(cf))[:6]:>6}   {','.join(tags)[:60]}"
        )
        timeline_list.append({
            "time_slot": ts,
            "count": len(rs),
            "avg_score": avg_s,
            "steps": sorted(st),
            "cfg": sorted(cf),
            "tags": tags
        })

    # ---------- 保存 JSON 与 HTML 报告 ----------
    report_data = {
        "summary": {
            "source_directory": str(src.resolve()),
            "output_directory": str(out_dir.resolve()),
            "generated_at": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime()),
            "total_samples": n,
            "overall_average_score": round(overall, 2),
            "pass_rate_sa": round(sa_rate, 2),
            "fail_rate_f": round(f_rate, 2),
            "grades": dict(gs),
        },
        "threshold_pass_rates": threshold_pass_rates,
        "by_tag": by_tag_data,
        "modifiers_attribution": attr_data,
        "reseed_variance": reseed_info,
        "timeline": timeline_list,
        "rows": rows
    }

    json_path = out_dir / "jigsaw_qa_report.json"
    html_path = out_dir / "jigsaw_qa_report.html"

    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(report_data, f, ensure_ascii=False, indent=2)

    html_content = generate_html_report(report_data)
    with open(html_path, "w", encoding="utf-8") as f:
        f.write(html_content)

    print("\n" + "=" * 100)
    print(f"📄 JSON 数据产物: {json_path.resolve()}")
    print(f"🌐 交互 HTML 报告: {html_path.resolve()}")
    print("=" * 100)

    return 0


if __name__ == "__main__":
    sys.exit(main())
