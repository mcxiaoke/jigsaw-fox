#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Build my_prompt_library_illust_v5.json directly from my_prompt_library_v5.json.

Maintains 100% structural alignment with the clean catalog subjects and environment
partners from the photo library, replacing photographic camera optics with the pure
vintage storybook illustration style (Dominic Davison & Kim Jacobs gouache/watercolor).
"""

import copy
import json
import os
import re
import sys

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
V5_PHOTO_PATH = os.path.join(PROJECT_ROOT, "scripts", "my_prompt_library_v5.json")
OUTPUT_ILLUST_PATH = os.path.join(PROJECT_ROOT, "scripts", "my_prompt_library_illust_v5.json")

ILLUST_STYLE_POOL = [
    "Dominic Davison and Kim Jacobs style gouache and watercolor painting",
    "classic storybook gouache illustration with textured brushstrokes",
    "detailed watercolor and gouache artwork with crisp painted outlines",
    "vintage storybook illustration with warm painterly nostalgic charm",
    "lively acrylic and gouache artwork with vibrant layered brushwork",
    "textured folk-art inspired painterly illustration with rich detail",
]

ILLUST_QUALITY_PREFIX = (
    "deep depth of field with consistent sharpness, busy composition with clear "
    "visual hierarchy, varied shape color and scale between regions"
)
ILLUST_QUALITY_TAIL = (
    "corner-to-corner fine detail, rich color harmony, full-bleed painterly artwork"
)

RISK_WORDS = [
    r"\bLEGO\b", r"\bGhibli\b", r"\bPixar\b", r"\bShinkai\b", r"\bDisney\b",
    r"\bMona Lisa\b", r"\bThe Last Supper\b", r"\bkaleidoscope\b", r"\bmandala\b",
    r"\bMandelbrot\b", r"\bparchment\b", r"\baccretion disk\b", r"\bHarley\b",
    r"\bVespa\b", r"\bVW\b", r"\bMini Cooper\b", r"\bRolls-Royce\b", r"\bF1\b",
    r"\bFerrari\b", r"\bLamborghini\b", r"\bMustang\b", r"\bCorvette\b",
    r"clean uncluttered", r"clean finish", r"fresh bright daylight",
]
RISK_WORD_RE = re.compile("|".join(RISK_WORDS), re.IGNORECASE)


def build_illust_library() -> None:
    if not os.path.exists(V5_PHOTO_PATH):
        print(f"[FATAL] Base photo library not found: {V5_PHOTO_PATH}")
        sys.exit(1)

    with open(V5_PHOTO_PATH, "r", encoding="utf-8") as f:
        v5 = json.load(f)

    illust_lib = copy.deepcopy(v5)
    illust_lib["version"] = "5.1-illust-clean"
    illust_lib["_comment"] = (
        "Pure storybook illustration library (100% aligned with v5 catalog). "
        "Zero photo-optics words, positive prompting only, corner-to-corner dense hand-painted detail."
    )
    illust_lib["quality_prefix"] = ILLUST_QUALITY_PREFIX
    illust_lib["quality_tail"] = ILLUST_QUALITY_TAIL

    illust_lib["style_pools"] = {
        "illust": ILLUST_STYLE_POOL
    }

    # All tags use illust pool, zero camera optics
    for tag in illust_lib["tags"]:
        tag["style_pool"] = "illust"
        tag["optics"] = []
        if "photo_subjects" in tag:
            del tag["photo_subjects"]

    # Sanity check: Ensure no risk words survive
    content_str = json.dumps(illust_lib, ensure_ascii=False)
    risk_hits = []
    for m in RISK_WORD_RE.finditer(content_str):
        matched = m.group(0)
        start = max(0, m.start() - 20)
        end = min(len(content_str), m.end() + 20)
        snippet = content_str[start:end]
        if "stag beetle" in snippet.lower():
            continue
        risk_hits.append(matched)

    if risk_hits:
        print(f"[FATAL] Risk word(s) detected in generated library: {risk_hits}")
        sys.exit(1)

    with open(OUTPUT_ILLUST_PATH, "w", encoding="utf-8") as f:
        json.dump(illust_lib, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print("=== Illustration Library Build Complete ===")
    print(f"Source: {V5_PHOTO_PATH}")
    print(f"Target: {OUTPUT_ILLUST_PATH}")
    print(f"Tags: {len(illust_lib['tags'])}, Subjects: {sum(len(t.get('catalog_subjects', [])) for t in illust_lib['tags'])}")


if __name__ == "__main__":
    build_illust_library()
