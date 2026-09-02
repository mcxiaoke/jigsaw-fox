#!/usr/bin/env python3
"""One-shot: derive my_prompt_library_v4.json from my_prompt_library v3.0.

v3.0 defects found in visual review of ~4300 generated images:
  A) style pool was 8 entries with 7 illustration/flat styles -> ~half the output
     became flat anime/cartoon illustration.
  B) 9 subjects literally contained "soft ... blur behind", instructing the model
     to defocus the background -> blurry backgrounds / flat colour areas.
  C) quality_suffix had no depth-of-field or sharpness constraint at all.

v4.0 fixes:
  A) style is split into per-tag pools ("photo" / "illust"). Real-world tags use
     the photographic pool; only Art/Cartoon/Fantasy/Holidays/Space/Abstract
     (subjects that are not photographs by nature) use the illustration pool,
     which itself now demands layered depth and brushwork instead of flat colour.
  B) every "blur" phrase is rewritten to a sharp/detailed equivalent.
  C) quality_suffix gains deep-depth-of-field / edge-to-edge sharpness phrasing
     (positive-only, because CFG ~1.1 makes negative prompts inert).
  D) the 20-category "visual anchor" list (temp/comfyuizimage) is folded in as a
     new per-tag modifier so each image gets concrete puzzle landmarks.

Run:  python temp/build_v4_library.py
"""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "scripts" / "my_prompt_library.json"
DST = ROOT / "scripts" / "my_prompt_library_v4.json"


# --- B) blur phrase repair --------------------------------------------------
BLUR_FIX = [
    ("blurred canopy depth behind", "layered canopy depth behind"),
    ("and soft garden blur behind", "with a sharply detailed garden behind"),
    ("and a warm field blur behind", "and a sunlit field with visible detail behind"),
    ("and soft green blur behind", "and layered green foliage behind"),
    ("and soft blur behind", "and layered garden foliage behind"),
    ("and soft beach blur behind", "and a detailed shoreline behind"),
]
BLUR_RE = re.compile(r"\b(?:soft|blurred|shallow)\b[^,]*\bblur(?:red)?\b[^,]*")

# --- F1/F2 (v4.2): portrait-framing repair --------------------------------
# Visual review of the diagnostic run (3 tags x 8 x reseed) showed 5/7 failures
# were the SAME failure mode: the model defocused everything behind the subject.
# The trigger is NOT a missing "deep focus" word -- every bad prompt already had
# "small aperture / deep focus / consistent sharpness" -- it is the COMPOSITION
# template itself:
#     "[subject] as the focal subject, with ..., and [X] behind"
# Z-Image-Turbo reads "subject + behind + close-up" as a portrait shot and
# applies shallow DOF, and at CFG 1.1 the suffix cannot override that prior.
#
# F1 drops the "as the focal subject / central subject / focal point" wording so
# the subject becomes one landmark among several instead of a portrait sitter.
# F2 rewrites "behind" -> "in the distance": "behind" is the single strongest
# spatial word the model associates with "out-of-focus background".
#
# Note: "point" is restricted to "focal point" so it can never match the word
# "viewpoint" (which appears once in the source data).
FOCAL_RE = re.compile(
    r"(?:,?\s*as the |,?\s*)(?:clear central |clear |central )?(?:focal )?"
    r"(?:subject|focal point)\b,?",
    re.IGNORECASE,
)
BEHIND_RE = re.compile(r"\bbehind\b")


def clean_composition(text: str) -> str:
    """F1: drop focal-subject framing. F2: drop 'behind' -> 'in the distance'."""
    out = FOCAL_RE.sub("", text)
    out = BEHIND_RE.sub("in the distance", out)
    out = re.sub(r"\s{2,}", " ", out).strip()
    out = re.sub(r"\s+,", ",", out)  # tidy " ," leftovers
    return out


# --- B2) haze / low-saturation repair --------------------------------------
# Found by scanning every subject for the contrast-killing vocabulary. Haze on
# a distant background does two bad things at once: it desaturates (the user's
# v2.0 complaint was "colours not vivid enough") and it flattens the background
# into featureless colour (the v3.0 complaint). prompt-rec.txt also lists
# "heavy atmospheric haze" among the things to avoid.
#
# Deliberately NOT changed: Space's "an atmospheric haze band above" -- that is
# a glowing nebula band, which is luminous subject matter, not distance haze.
HAZE_FIX = [
    ("and hazy hills behind", "and layered hills behind"),
    ("and hazy strata behind", "and layered rock strata behind"),
    ("and hazy city depth behind", "and layered city depth behind"),
    ("and hazy mountains behind", "and layered mountains behind"),
    ("and a hazy skyline behind", "and a detailed skyline behind"),
    ("and faded ink borders", "and aged ink borders"),
    # F6 (v4.2): "misty" slipped through v4.1 because HAZE_FIX only caught
    # "hazy". "misty X behind" is the exact same bokeh trigger -- the model
    # reads "misty + behind" as a defocused background. Rewrite the whole phrase
    # to "layered X in the distance" so F2's "behind" pass has nothing to do.
    ("and misty hills behind", "and layered hills in the distance"),
    ("and misty slopes behind", "and layered slopes in the distance"),
]

# F7 (v4.3): "shallow" in subject descriptions (e.g. "a shallow stream") is
# read by the model as a DOF instruction -- Nature:0006 had "a shallow stream"
# and its image showed confirmed background blur.  The v4.2 BLUR_RE only
# matches "shallow blur", so "shallow stream/water" slipped through.
SHALLOW_FIX = [
    ("a shallow stream", "a rocky stream"),
    ("shallow water above", "clear water above"),
    ("shallow water reflections", "calm water reflections"),
]

# F8 (v4.3): "soft" in subject descriptions can trigger softening/blur.
# Only fixes subject text; lighting pool "soft" entries are already replaced.
SOFT_SUBJECT_FIX = [
    ("soft garden", "lush garden"),
    ("soft woodland light", "diffused woodland light"),
    ("soft forest", "dense forest"),
    ("soft coral", "textured coral"),
]

# F10 (v4.3): Subject-level spatial rewrite.  diag2/3/4 proved that even with
# all trigger words removed (no "close-up", "shallow", "soft", "focal point"),
# Z-Image-Turbo still produces shallow DOF when the subject description itself
# stacks all elements in the foreground plane (e.g. "X in the lower left, Y in
# the upper right, Z along the bottom edge").  The model reads this layout as a
# macro/close-up composition and applies bokeh regardless of suffix wording.
#
# Fix: rewrite the subject from "foreground element pile" to "wide scene with
# distributed depth".  Key changes:
#   - opening noun becomes a scene, not a single object ("a forest floor
#     scene" vs "an ancient tree trunk")
#   - elements are distributed across the ground plane, not pinned to frame
#     edges ("scattered across the ground" vs "in the lower left")
#   - spatial depth is explicit ("at center", "in the distance", "overhead")
#
# Applied BEFORE other fixes so clean_composition / fix_blur run on the new text.
SUBJECT_REWRITE = {
    "Nature:0": (
        "a forest floor scene with an ancient moss-covered tree trunk at "
        "center, ferns and toadstools scattered across the ground, hanging "
        "vines from the upper branches, and layered canopy depth in the distance"
    ),
    "Cities:0": (
        "a wide street corner with a flower-boxed cafe at left, cobbled "
        "pavement extending into the distance, old town facades lining both "
        "sides, and hanging signs above"
    ),
}


def fix_blur(text: str, log: list) -> str:
    out = text
    for old, new in BLUR_FIX:
        if old in out:
            out = out.replace(old, new)
    if "blur" in out:
        m = BLUR_RE.search(out)
        if m:
            out = out.replace(m.group(0), "detailed layered background")
            log.append(f"    fallback blur fix: {m.group(0)!r}")
    if "blur" in out:
        log.append(f"    !! still contains blur: {out[:90]}")
    return out


# --- F11: Edge-pinning position fix -----------------------------------------
# Problem (diag6, 840 images): 176/252 subjects (70%) use phrases like
# "at the left edge", "in the lower left", "along the bottom" that tell the
# model to place elements at frame edges. At CFG=1.0 the model obeys
# literally, producing off-center compositions with 80% empty background.
#
# Fix: replace all edge/corner positions with distributed language. Main
# subject edge positions become "at center"; secondary element positions
# become "scattered across the foreground" / "above" / "across the ground".
POSITION_FIXES = [
    # Main subject edge positions → center
    (r"\bat the left edge\b", "at center"),
    (r"\bat the right edge\b", "at center"),
    (r"\bframing the left edge\b", "on either side"),
    (r"\bframing the right edge\b", "on either side"),
    # Secondary element corner positions → distributed
    (r"\bin the lower left\b", "scattered across the foreground"),
    (r"\bin the upper left\b", "above"),
    (r"\bin the lower right\b", "across the foreground"),
    (r"\bin the upper right\b", "above"),
    (r"\bat the upper left\b", "above"),
    (r"\bat the upper right\b", "above"),
    (r"\bat the lower left\b", "in the foreground"),
    (r"\bat the lower right\b", "in the foreground"),
    # Edge-spanning positions → distributed
    (r"\balong the bottom edge\b", "across the ground"),
    (r"\balong the bottom\b", "across the ground"),
    (r"\balong the top\b", "overhead"),
    (r"\bacross the lower edge\b", "across the foreground"),
    # Simple edge positions → neutral
    (r"\bat the bottom\b", "in the foreground"),
    (r"\bat the top\b", "above"),
    (r"\bat the left\b", "nearby"),
    (r"\bat the right\b", "nearby"),
]


def fix_positions(text: str, log: list) -> str:
    out = text
    for pattern, replacement in POSITION_FIXES:
        if re.search(pattern, out, re.IGNORECASE):
            count = len(re.findall(pattern, out, re.IGNORECASE))
            out = re.sub(pattern, replacement, out, flags=re.IGNORECASE)
            log.append(f"    pos-fix ({count}x): {pattern} -> {replacement}")
    # De-duplicate doubled words caused by replacement (e.g. "scattered scattered")
    dedup = re.sub(r"\b(\w+)\s+\1\b", r"\1", out, flags=re.IGNORECASE)
    if dedup != out:
        log.append(f"    dedup: removed doubled word(s)")
        out = dedup
    return out


# --- D) 20-category visual anchors -----------------------------------------
# Source: temp/comfyuizimage/提示词注意事项.txt (user supplied, cross-checked).
#
# IMPORTANT DEVIATION FROM THE SOURCE TABLE, verified by dry-run:
# the source lists concrete OBJECTS ("sea turtle shell patterns", "porcelain
# vase", "candy house icing roof"). Sampling those across every subject of a
# tag forces them into scenes where they do not belong -- "water surface
# reflections" landed on the elephant and the tiger, "sea turtle shell
# patterns" on the lobster trap. That is exactly the "conflicting elements"
# failure the user complained about in v2.0.
#
# So each anchor is rewritten as a SURFACE / COMPOSITION property that remains
# true for every subject in its tag. It still gives the puzzle distinct
# landmarks (colour transitions, texture, contrasting objects) without
# injecting an object that fights the scene.
VISUAL_ANCHORS = {
    "Animals": [
        "high-contrast markings and fine fur detail",
        "varied foliage texture filling the background",
        "leaf litter and twigs in the foreground",
        "dappled light patches across the ground",
    ],
    "Pets": [
        "colorful fabric and textile patterns",
        "small household objects filling the corners",
        "warm wood and woven textures",
        "varied colored props around the subject",
    ],
    "Nature": [
        "moss and lichen texture",
        "varied green tones with seasonal color accents",
        "leaf litter and twigs in the foreground",
        "water droplets on surfaces",
    ],
    "Landscapes": [
        "layered depth from foreground to the distant horizon",
        "distinct foreground rocks and wildflowers",
        "textured cloud formations in the sky",
        "still water reflections",
    ],
    "Flowers": [
        "multiple flower species in contrasting colors",
        "visible petal veins and stamen detail",
        "dew drops on the petals",
        "contrasting foliage and stem structure",
    ],
    "Ocean": [
        "brightly colored tropical fish",
        "varied blue and teal water tones",
        "rippled sand and gravel texture",
        "barnacles and encrusting texture on hard surfaces",
    ],
    "Birds": [
        "iridescent feather detail with sharp color transitions",
        "clusters of berries or seed heads on the branch",
        "wood grain and bark texture",
        "bright contrasting plumage patches",
    ],
    "Cities": [
        "neon signs and shopfront lettering",
        "striped awnings and hanging signage",
        "cobblestone or paved street texture",
        "warm lit windows across the facades",
    ],
    "Architecture": [
        "brick and stone joint detail across the walls",
        "carved ornament and ironwork detail",
        "contrasting roof tiles and slates",
        "planted flowerbeds and climbing greenery",
    ],
    "Food": [
        "contrasting colored ingredients and garnishes",
        "textured table linen or wooden board surface",
        "glazed and glossy surface highlights",
        "scattered crumbs herbs and spices",
    ],
    "Art": [
        "visible brushstrokes and paint texture",
        "contrasting color blocks and swirls",
        "ornamental border and corner detail",
        "aged paper or canvas texture",
    ],
    "Fantasy": [
        "glowing magical light sources",
        "metallic and gemstone highlights",
        "carved runes and ornate engravings",
        "layered mysterious depth in the background",
    ],
    "Space": [
        "bright nebula clouds in pink and blue",
        "lit control panels and indicator lights",
        "metallic hull plates and rivet detail",
        "a dense star field filling the dark areas",
    ],
    "Transportation": [
        "polished metal and brass fittings",
        "riveted plates and mechanical joints",
        "bold colored livery and paintwork",
        "detailed surroundings with signage and structures",
    ],
    "People": [
        "patterned clothing and textiles",
        "colorful market goods and produce",
        "handmade craft objects on display",
        "warm string lights and lanterns",
    ],
    "Sports": [
        "high-visibility fluorescent equipment colors",
        "textured ground surface with tracks and markings",
        "branded banners and signage",
        "equipment straps and buckle detail",
    ],
    "Seasons": [
        "seasonal produce and harvest objects",
        "strong seasonal foliage color",
        "textile decorations and wreaths",
        "weathered wood and wicker textures",
    ],
    "Holidays": [
        "ornaments and hanging decorations",
        "patterned gift wrap and ribbons",
        "warm candlelight and string lights",
        "festive garlands across the edges",
    ],
    "Abstract": [
        "strong dark outlines separating color fields",
        "jewel tone color blocks",
        "iridescent and metallic color shifts",
        "organic cells and marbled veining",
    ],
    "Cartoon": [
        "rounded chunky props with thick outlines",
        "a candy colored high saturation palette",
        "patterned cobbled or tiled ground",
        "decorative details packed into the corners",
    ],
    "Others": [
        "shelves filled with small labelled objects",
        "warm wood and patina surfaces",
        "arranged collections of varied small objects",
        "glass jars and bottles with colored contents",
    ],
}

# `extra` in v3.0 often restated what the subject phrase already said
# ("one adult elephant as the clear central subject" + "a single animal as the
# clear focal subject"). That spends text-encoder capacity for nothing, so the
# pure duplicates are dropped and the ones carrying real constraints are kept
# and shortened.
EXTRA_REWRITE = {
    "Animals": "",
    "Pets": "",
    "Birds": "",
    "Ocean": "dense reef and shore detail filling every corner",
    "Space": "dense star field and instrument detail filling all edges",
    "People": "a small group as the focal subject in a crowded detailed setting, faces not the focus",
    "Abstract": "one organic non-repeating texture with a clear focal area of highest density",
    "Cartoon": "one clear main subject with a fully rendered detailed background",
}

# --- A) per-tag style pool assignment --------------------------------------
# photo  : real-world subjects. Photographic styles only, and NO "cinematic"
#          (the word pulls the model toward shallow depth of field).
# illust : subjects that are not photographs by nature, so illustration is the
#          right look -- but every entry now demands depth/brushwork/texture so
#          the flat-colour failure mode is harder to reach.
STYLE_POOL = {
    "Animals": "photo",
    "Pets": "photo",
    "Nature": "photo",
    "Landscapes": "photo",
    "Flowers": "photo",
    "Ocean": "photo",
    "Birds": "photo",
    "Cities": "photo",
    "Architecture": "photo",
    "Food": "photo",
    "Seasons": "photo",
    "Transportation": "photo",
    "People": "photo",
    "Sports": "photo",
    "Others": "photo",
    "Art": "illust",
    "Cartoon": "illust",
    "Fantasy": "illust",
    "Holidays": "illust",
    "Space": "illust",
    "Abstract": "illust",
}

STYLE_POOLS = {
    # Photo pool: TECHNIQUE-ONLY phrasing, no subject matter.
    # A first draft used genre names ("wildlife photography", "architectural
    # photography"). Dry-run showed them landing on the wrong scenes -- a
    # starfish got "architectural photography" and a neon market stall got
    # "wildlife photography" -- which injects a conflicting subject into the
    # frame, the same failure mode as the anchor bug. Genre words are dropped;
    # the subject phrase already supplies the subject matter.
    # Also deliberately excluded: "cinematic" and "macro" (both pull the model
    # toward shallow depth of field, which fights the new sharpness suffix).
    "photo": [
        "photorealistic with crisp natural texture",
        "high resolution photography with fine detail",
        "sharp focus throughout with natural lighting",
        "lifelike realistic rendering with visible surface detail",
        "crisp detailed photography with high dynamic range",
        "realistic material rendering with accurate textures",
        "high detail photographic rendering with a clean finish",
        "documentary style photography with true to life color",
    ],
    # Illustration pool: every entry demands depth / brushwork / texture so the
    # flat-colour failure mode ("blurred background, too much flat colour") is
    # harder to reach. Used only by Art/Cartoon/Fantasy/Holidays/Space/Abstract.
    "illust": [
        "richly detailed painterly illustration with layered depth",
        "textured gouache illustration with visible brushstrokes",
        "polished 3D rendered illustration with rich surface detail",
        "classical oil painting with thick impasto brushwork",
        "detailed risograph print with layered textures",
        "intricate decorative illustration with dense ornamental detail",
    ],
}

# --- C) quality suffix ------------------------------------------------------
# v3.0's review found NO depth-of-field constraint at all, which is why so many
# images came back with defocused backgrounds and large flat colour areas.
# Everything is stated positively because CFG stays 1.1 (distilled turbo), where
# negative prompts are inert -- re-confirmed against four independent sources
# (official guidance_scale is fixed to 0).
#
# v4.1 sharpness wording corrected after reading
# temp/comfyuizimage/prompt-rec.txt. v4.0 said "razor sharp from the foreground
# to the background", i.e. hyper-sharp edge to edge. That reads as a heavy
# post-process and makes realistic output look artificial; worse, it also
# suppresses the natural atmospheric depth that a landscape needs. The source's
# distinction is the right one:
#   BAN   optical blur      (shallow DOF, bokeh, lens blur, soft focus)
#   ALLOW atmospheric depth (distance haze is how real landscape photos work)
# so sharpness is stated as "consistent" and depth is assigned to composition,
# scale, overlap and perspective instead of to the lens.
#
# Also added from that source:
#   - no excessive sky or water  (the single biggest source of dead puzzle zones
#                                 -- a frame half-filled with sky is a frame half
#                                 filled with identical blue pieces)
#   - no repetitive micro textures (I dropped this in the v4.0 trim; it belongs,
#                                 because it is what makes grass/sand/foliage
#                                 areas un-puzzleable)
#
# Length is a real constraint: official guidance gives a practical range of
# 80-250 words and warns "long and technical: good, long and literary: worse".
# The full base prompt in prompt-rec.txt is 200+ words on its own and would push
# the total to the ceiling while diluting the subject, so only its CONSTRAINTS
# are folded in here, not its prose.
QUALITY_SUFFIX = (
    "deep depth of field, consistent sharpness across the whole image, depth "
    "conveyed through scale, overlap and perspective rather than optical blur, "
    "clean uncluttered composition with clear visual hierarchy, medium-scale "
    "readable details, vibrant saturated colors, clear visual landmarks with "
    "meaningful differences in shape, color and scale between regions, rich "
    "texture variation continuing into all four corners, no large flat empty "
    "areas, no excessive sky or water, no repetitive micro textures, "
    "full-bleed artwork"
)

# --- E) lens / optics, per tag ----------------------------------------------
# Prompt-rec has no optics section, but the official Z-Image prompt structure
# lists "lens, DOF" as a first-class slot, so it is worth spending words on.
#
# Only tags whose scenes genuinely span a large volume get the wide-angle +
# small-aperture treatment. Forcing "wide angle" onto a macro subject is the
# same category of mistake as the anchor bug: it injects an instruction that
# fights the scene.
#
#   wide angle + small aperture -> scenes that need spatial depth
#   deep focus only             -> mid/long range subjects whose scale varies
#   (nothing)                   -> close-up / macro / non-photographic tags
OPTICS = {
    "Landscapes": [
        "wide-angle lens view with everything in focus",
        "small aperture f/11, deep focus from the foreground to the horizon",
        "small aperture f/8, deep focus from the foreground to the horizon",
        "panoramic wide-angle composition with a small aperture",
    ],
    "Cities": [
        "wide-angle street view with everything in focus",
        "small aperture f/11, deep focus along the whole street",
        "small aperture f/8, deep focus from the foreground to the far end",
    ],
    "Architecture": [
        "wide-angle architectural view, small aperture f/11, everything in focus",
        "small aperture f/8, the whole structure and its surroundings in focus",
        "wide-angle view showing the full building with its setting in focus",
    ],
    "Seasons": [
        "small aperture f/11, deep focus throughout",
        "small aperture f/8, deep focus throughout",
        "wide-angle seasonal landscape with everything in focus",
    ],
    "Transportation": [
        "medium shot with the vehicle prominent and filling most of the frame, deep focus",
        "small aperture f/8, deep focus across the whole scene",
    ],
    "Nature": [
        "small aperture f/8, deep focus from the foreground to the background",
        "everything in focus from the near foreground to the far distance",
    ],
    "Ocean": [
        "small aperture f/8, deep focus from the foreground to the background",
        "everything in focus from the near foreground to the far distance",
    ],
    "Animals": [
        "small aperture f/8, the animal prominent in the frame with deep focus",
        "deep focus with the animal and its habitat both sharp",
    ],
    "Birds": [
        "small aperture f/8, the bird prominent in the frame with deep focus",
        "deep focus with the bird and the background both sharp",
    ],
}

# v4.1: 1:1 only. Square is both the dominant puzzle aspect and the fastest
# to generate (1024x1024 = 1.05 MP vs 896x1344 = 1.20 MP, ~13% fewer pixels;
# measured 13.2s vs 15.2s on the 4070). The 2:3 / 3:2 dimension definitions stay
# in the library so a later run only has to flip this constant and re-run
# temp/build_v4_library.py -- nothing needs to be re-authored.
ACTIVE_RATIOS = ["1:1"]

# Lighting: one entry changed. "hazy soft light" is removed because haze both
# desaturates and flattens the background -- it is explicitly on prompt-rec's
# avoid list ("heavy atmospheric haze"). Soft overcast / diffused window light
# stay: they are the correct key light for flowers, food and interiors, and they
# lower contrast without erasing detail.
LIGHTING = [
    "golden hour light",
    "even overcast light",
    "dappled sunlight",
    "dramatic side light",
    "warm interior light",
    "cool morning light",
    "raking low sunlight",
    "diffused window light",
    "even ambient light",
    "crisp bright daylight",
]

# Atmosphere: one entry changed. "candy-bright pastel palette" is removed --
# pastel means LOW saturation, which directly contradicts the "colours not vivid
# enough" feedback from v2.0 and v3.0. The candy-bright intent (playful, punchy)
# is kept, the desaturating word is not.
ATMOSPHERE = [
    "rich saturated color grading",
    "warm golden sunlight palette",
    "vivid jewel-tone colors",
    "fresh bright daylight tones",
    "high contrast bold colors",
    "candy-bright multicolor palette",
    "earthy warm tones with vivid accents",
    "teal and warm amber contrast",
]

# viewpoint: v4.2 kept "close-up view with the background still fully sharp"
# but the diag2 run proved "close-up" is the single strongest bokeh trigger --
# the qualifying clause "background still fully sharp" is too weak to override
# it at CFG 1.1.  F3 replaces it with a phrase that contains no close-up word.
# "flat lay" is a great composition for food/still-life and a bad one for
# anything that needs spatial depth, so those tags deny it explicitly.
VIEWPOINT = [
    "eye-level view",
    "slightly elevated view",
    "detailed near view with full depth of field",
    "medium shot view",
    "three-quarter view",
    "low angle view",
    "high angle view",
    "flat lay overhead view",
]

VIEWPOINT_DENY = {
    # Overhead framings collapse the depth that these subjects depend on
    # (~25% of their images would otherwise be affected).
    "Landscapes": ["flat lay overhead view"],
    "Cities": ["flat lay overhead view"],
    "Architecture": ["flat lay overhead view"],
    "Transportation": ["flat lay overhead view"],
}


def main() -> int:
    lib = json.loads(SRC.read_text(encoding="utf-8"))
    log: list[str] = []

    lib["version"] = "4.3"
    lib["_comment"] = (
        "v4.3 on top of v4.2.  Diag2 run (3 tags x 8 x reseed 2 = 48 images) "
        "confirmed residual bokeh/blur in Nature:0000 and Cities:0000/0001/0003/0006. "
        "Root causes identified and fixed: "
        "(F3) 'close-up view with the background still fully sharp' replaced with "
        "'detailed near view with full depth of field' -- 'close-up' is the single "
        "strongest bokeh trigger and the qualifying clause was too weak at CFG 1.1; "
        "Landscapes had viewpoint_deny blocking it and was clear, proving causation. "
        "(F4) 'one clear focal point' in quality_suffix changed to 'clear visual "
        "hierarchy' -- 'focal point' implies subject isolation and triggers bokeh. "
        "(F7) 'shallow stream/water' in subjects -> 'rocky stream/clear water' -- "
        "the model reads 'shallow' as a DOF instruction; Nature:0006 had this and "
        "showed confirmed blur. "
        "(F8) 'soft overcast/ambient light' -> 'even overcast/ambient light'; "
        "'soft garden/forest/coral' in subjects -> stronger alternatives. "
        "(F9) OPTICS entries that started with 'wide-angle view, ' had that prefix "
        "dropped to avoid duplicate 'wide-angle view' when viewpoint also says it. "
        "(F10) Subject-level spatial rewrite: Nature:0000 and Cities:0000 had all "
        "elements stacked in the foreground plane ('in the lower left, in the upper "
        "right, along the bottom edge'), which the model reads as macro/close-up "
        "composition even without trigger words. Rewritten to wide-scene layout "
        "with distributed depth. "
        "Workflow defaults also changed: cfg 1.1->1.0, steps 9->8 (official values). "
        "v4.2 fixes (F1/F2/F6) inherited unchanged. "
    )
    lib["generated_by"] = "temp/build_v4_library.py (derived from v3.0)"
    if ACTIVE_RATIOS != ["1:1", "2:3", "3:2"]:
        lib["active_ratios"] = ACTIVE_RATIOS

    lib["quality_suffix"] = QUALITY_SUFFIX

    mods = lib["modifiers"]
    mods.pop("style", None)  # replaced by style_pools
    mods.pop("detail", None)  # unused in v3.0
    mods["viewpoint"] = VIEWPOINT
    mods["lighting"] = LIGHTING
    mods["atmosphere"] = ATMOSPHERE
    lib["style_pools"] = STYLE_POOLS

    for tag in lib["tags"]:
        tid = tag["id"]
        if tid not in VISUAL_ANCHORS:
            log.append(f"  !! no visual anchor for {tid}")
        if tid not in STYLE_POOL:
            log.append(f"  !! no style pool for {tid}")
        tag["style_pool"] = STYLE_POOL.get(tid, "photo")
        tag["visual_anchors"] = VISUAL_ANCHORS.get(tid, [])
        if tid in OPTICS:
            tag["optics"] = OPTICS[tid]

        # v4.1: 1:1 only. Ratio definitions stay in lib["ratios"], so widening
        # back to 2:3 / 3:2 is a one-constant change plus a re-run here.
        tag["ratios"] = [r for r in ACTIVE_RATIOS if r in tag["ratios"]] or list(
            ACTIVE_RATIOS
        )

        if tid in VIEWPOINT_DENY:
            tag["viewpoint_deny"] = VIEWPOINT_DENY[tid]

        if tid in EXTRA_REWRITE:
            old = tag.get("extra", "")
            tag["extra"] = EXTRA_REWRITE[tid]
            if old != tag["extra"]:
                log.append(f"    extra: {old[:55]!r} -> {tag['extra'][:55]!r}")
            # F1/F2 (v4.2): People/Cartoon carry "as the focal subject" in their
            # extra text too, so the same portrait-framing fix applies here.
            if tag.get("extra"):
                tag["extra"] = clean_composition(tag["extra"])
        log.append(
            f"  {tid}: pool={tag['style_pool']} anchors={len(tag['visual_anchors'])}"
        )

        fixed = []
        for i, s in enumerate(tag["subjects"]):
            # F10 (v4.3): rewrite subjects whose foreground-element stacking
            # causes shallow DOF even without trigger words.
            rewrite_key = f"{tid}:{i}"
            if rewrite_key in SUBJECT_REWRITE:
                new = SUBJECT_REWRITE[rewrite_key]
                if new != s:
                    log.append(f"    rewrite: {s[:60]}... -> {new[:60]}...")
            else:
                new = s
            new = fix_blur(new, log)
            for old, rep in HAZE_FIX:
                if old in new:
                    new = new.replace(old, rep)
                    log.append(f"    haze: {old} -> {rep}")
            # F7 (v4.3): "shallow stream/water" -> "rocky stream/clear water"
            # because the model reads "shallow" as a DOF instruction.
            for old, rep in SHALLOW_FIX:
                if old in new:
                    new = new.replace(old, rep)
                    log.append(f"    shallow: {old} -> {rep}")
            # F8 (v4.3): "soft" in subject text -> stronger alternatives.
            for old, rep in SOFT_SUBJECT_FIX:
                if old in new:
                    new = new.replace(old, rep)
                    log.append(f"    soft-fix: {old} -> {rep}")
            # F1/F2 (v4.2): drop portrait framing ("as the focal subject") and
            # "behind" -> "in the distance" so the model stops defocusing the
            # background. Applied before the macro fix so both run on the result.
            new = clean_composition(new)
            # F11 (v4.4): strip edge-pinning positions ("at the left edge",
            # "in the lower left", etc.) that cause off-center compositions
            # with large empty backgrounds. Run after clean_composition.
            new = fix_positions(new, log)
            # Abstract used "a macro of" -> extreme close-up (macro implies
            # shallow DOF, which fights the new sharpness suffix).
            new = re.sub(r"\ba macro of\b", "an extreme close-up of", new)
            if new != s:
                log.append(f"    fixed: {s[:70]} ->  {new[:70]}")
            fixed.append(new)
        tag["subjects"] = fixed

    # Override generation defaults to match workflow JSON (cfg 1.0, steps 8).
    # The source v3 library has cfg=1.1/steps=9; without this override the
    # generator would carry the old values forward every time it runs.
    if "generation" not in lib:
        lib["generation"] = {}
    lib["generation"]["steps"] = 8
    lib["generation"]["cfg"] = 1.0

    DST.write_text(
        json.dumps(lib, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    total_anchor = sum(len(t["visual_anchors"]) for t in lib["tags"])
    photo_tags = [t["id"] for t in lib["tags"] if t["style_pool"] == "photo"]
    illus_tags = [t["id"] for t in lib["tags"] if t["style_pool"] == "illust"]
    quota_photo = sum(
        int(t.get("quota", 0)) for t in lib["tags"] if t["style_pool"] == "photo"
    )
    quota_illus = sum(
        int(t.get("quota", 0)) for t in lib["tags"] if t["style_pool"] == "illust"
    )

    print(f"wrote {DST}")
    print(f"  tags={len(lib['tags'])}  anchors={total_anchor}")
    print(
        f"  photo pool : {len(photo_tags)} tags, quota {quota_photo} "
        f"({quota_photo / (quota_photo + quota_illus) * 100:.0f}% of output)"
    )
    print(
        f"  illust pool: {len(illus_tags)} tags, quota {quota_illus} "
        f"({quota_illus / (quota_photo + quota_illus) * 100:.0f}% of output)"
    )
    print()
    for line in log:
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
