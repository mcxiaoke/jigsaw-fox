#!/usr/bin/env python3
"""Build my_prompt_library_v5.json — pure catalog-driven, no premium pool.

Reads docs/jigsaw-tag-subject-catalog.md to extract subject keywords and
environment partners per tag, translates Chinese keywords to English,
assigns template_group, injects prompt_templates. Borrows shared
infrastructure (ratios, modifiers, style_pools, quality_suffix, generation,
viewpoint_deny, optics) from the v4 JSON but strips all premium-pool fields
(subjects, extra, visual_anchors, tier, quota).

Output: scripts/my_prompt_library_v5.json

Usage:
    python temp/build_v5_library.py
"""

import json
import os
import re
import sys

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
V4_JSON = os.path.join(PROJECT_ROOT, "scripts", "my_prompt_library_v4.json")
CATALOG_MD = os.path.join(PROJECT_ROOT, "docs", "jigsaw-tag-subject-catalog.md")
V5_JSON = os.path.join(PROJECT_ROOT, "scripts", "my_prompt_library_v5.json")

# ---------------------------------------------------------------------------
# Template group assignment per tag
#   animal  - single/clustered subjects in habitat (FG/MG/BG)
#   scene   - wide landscape with foreground anchor + midground + distance
#   object  - flat lay / dense arrangement / close-up
#   special - custom anti-dead-zone layout (fill every corner)
# ---------------------------------------------------------------------------
TAG_TEMPLATE_GROUP = {
    "Animals": "animal",
    # Pets moved animal -> object. The `animal` group forces an
    # "{env_bg} in the distance / on the horizon" slot, which produced
    # literally "colorful chew toys on the horizon" in JigsawTest2 (Pets scored
    # 47.4 avg with a 33% F-grade rate, worst of all 21 tags). Pet environments
    # are rooms/yards, not horizons — the `object` group has no distance slot.
    "Pets": "object",
    "Birds": "animal",
    "Nature": "scene",
    "Landscapes": "scene",
    "Cities": "scene",
    "Architecture": "scene",
    "Seasons": "scene",
    "Transportation": "scene",
    "Flowers": "object",
    "Food": "object",
    "Art": "special",
    "Others": "object",
    "Ocean": "special",
    "Space": "special",
    "Abstract": "special",
    "Holidays": "special",
    "Cartoon": "special",
    "Fantasy": "special",
    "Sports": "special",
    "People": "special",
}

# Tags that need viewpoint_deny "flat lay overhead view" added (not present in v4).
# v4 already has this for Landscapes, Cities, Architecture, Transportation.
EXTRA_VP_DENY_TAGS = {"Animals", "Pets", "Birds", "People", "Sports", "Seasons"}

# Tags that lack an optics field in v4 but need explicit deep-focus optics
# to counter the model's default shallow-DOF behavior for that subject category.
TAG_OPTICS = {
    "Food": [
        "medium shot with the food prominently filling most of the frame, deep focus",
        "small aperture f/8, deep focus across the entire table surface",
    ],
}

# ---------------------------------------------------------------------------
# Subject-scale fix (2026-09-02) — targeted at Pets / Animals / Birds.
#
# Evidence (JigsawV5_full, 6212 imgs): manual sampling shows the subject
# occupies only ~10-20% of the frame while env slots dominate:
#   - animal/object templates render the subject as a bare noun ("a single
#     {subject}") against THREE rich multi-word env slots -> env out-weighs
#     subject ~3:1 in tokens, model renders the environment as the hero.
#   - Pets had NO optics at all; Animals/Birds optics ("the animal prominent
#     in the frame") are too weak to counterbalance 3 env slots.
#   - "high angle view" / "slightly elevated view" further shrink the subject
#     (Pets_0001 was high angle, shiba ~15% of frame).
#   - Birds_0004: bokeh background despite "deep focus" — env "in the
#     distance" + bird-photography shallow-DOF prior beats one weak clause.
# Fix pattern is F12-proven (Transportation): explicit scale + medium shot +
# deep focus in optics. Wording avoids all known trigger words
# (close-up / macro / bokeh / shallow / soft).
SUBJECT_SCALE_OPTICS = {
    "Pets": [
        "medium shot with the pet large in the frame and filling most of it, deep focus",
        "small aperture f/8, the pet prominent and filling most of the frame, deep focus",
    ],
    "Animals": [
        "small aperture f/8, the animal large in the frame and filling much of the foreground, deep focus",
        "deep focus with the animal large in the foreground and its habitat both sharp",
    ],
    "Birds": [
        "small aperture f/8, the bird large in the frame and filling much of it, background fully sharp, deep focus",
        "deep focus with the bird large on its perch and the background both sharp",
    ],
}

# Viewpoints that compress subject scale in an environmental frame — denied
# for the three subject-scale tags (flat lay already denied via v4 inherit +
# EXTRA_VP_DENY_TAGS).
SUBJECT_SCALE_VP_DENY = {
    "Pets": ["high angle view", "slightly elevated view"],
    "Animals": ["high angle view", "slightly elevated view"],
    "Birds": ["high angle view", "slightly elevated view"],
}

# Round 2 (2026-09-02, after JigsawV5_scale_fix spot-check): optics-only fix
# was INSUFFICIENT for Pets/Animals — subject still ~10-20% of frame
# (jaguar unchanged, shiba 15%->20%). Root cause is structural: the shared
# animal/object templates lead with a bare subject noun then THREE rich env
# slots; a single optics clause cannot out-weigh ~3:1 env token dominance.
# Fix: per-tag template override (tag["prompt_templates"], consumed by
# my_comfyui_batch_gen_v5.py build_jobs) that leads with explicit subject
# scale and demotes env to background/edges. Birds did NOT need this —
# optics-only already yields ~35-40% subject (macaw/lorikeet spot-checks).
# Scope guard: object group is shared with Flowers/Food/Others and animal
# group with Birds, hence per-tag override instead of editing group pools.
SUBJECT_SCALE_TEMPLATES = {
    "Pets": [
        "one large {subject} filling most of the frame in the foreground, with {env_fg} in the background and {env_mid} at the sides, and {detail} throughout",
        "a single large {subject} dominating the frame, {env_fg} visible behind it, {env_mid} filling the edges, and {detail} throughout",
        "a large {subject} front and center taking up most of the image, surrounded by {env_fg} and {env_mid}, with {detail} throughout",
    ],
    "Animals": [
        "one large {subject} filling most of the frame in the foreground, {env_fg} and {env_mid} in the background, and {detail} throughout",
        "a single large {subject} dominating the foreground, with {env_fg} behind it and {env_mid} in the distance, and {detail} throughout",
        "a large {subject} taking up most of the picture, with {env_fg} and {env_mid} as its backdrop, and {detail} throughout",
    ],
    # Round 3 (2026-09-02): Birds joined the override. Evidence
    # (JigsawV5_scale_fix2): on the old animal-group template the hummingbird
    # stayed ~18% with bokeh background ("cherry blossom ... in the distance"
    # + strong bird-photography shallow-DOF prior beats one optics clause),
    # while macaw/lorikeet happened to draw fine. No template below uses
    # "in the distance".
    "Birds": [
        "one large {subject} perched prominently and filling most of the frame in the foreground, with {env_fg} in the background and {env_mid} at the sides, and {detail} throughout",
        "a single large {subject} dominating the frame on its perch, {env_fg} visible behind it, {env_mid} filling the edges, and {detail} throughout",
        "a large {subject} with detailed feathers taking up most of the picture, {env_fg} and {env_mid} as its backdrop, and {detail} throughout",
    ],
}

# Round 3 subject fixes (Birds) — semantic/multi-subject defects found by
# JigsawV5_scale_fix2 spot-checks:
#   - "bird of paradise" rendered as the FLOWER (Strelitzia), no bird at all
#     (Birds_0005). "plumage" + explicit bird wording forces the avian reading.
#   - "owl family" -> five scattered small owls, single-subject principle
#     violated (Birds_0009). Replaced with a concrete single-species owl.
#   - "flamingo flock" -> same multi-subject / small-subject failure mode.
SUBJECT_REWRITES_R3 = {
    "bird of paradise": "male bird-of-paradise with ornate iridescent plumage",
    "owl family": "great grey owl",
    "flamingo flock": "greater flamingo",
}

# ---------------------------------------------------------------------------
# Quality split (2026-09-02 14:45) — subject tags get a relaxed quality
# profile; scene/texture tags keep the global full-strength one.
#
# Rationale (JigsawV5_full QA + rounds 1-3): dead-zone median 0.00 / P90 0.00
# and Lap median 1118 vs threshold 300 show the anti-flat words are massively
# over-provisioned, while "corner-to-corner dense detail" / "busy composition"
# / "rich micro texture variation into all four corners" actively command the
# model to fill corners with environment detail — competing with the subject
# for frame share. Subject tags (subject fills the foreground after the
# subject-scale fix) draw their sharpness from the subject surface itself.
# Scene/texture tags keep the global profile unchanged — their frames ARE
# texture fields and their QA metrics are healthy.
#
# KEEP in the subject profile: deep DOF (anti-bokeh), visual hierarchy,
# shape/color/scale variety, medium-scale readable details, full-bleed.
# DROP: corner-to-corner dense detail, busy composition, four-corners texture.
#
# ROLLBACK guard: if the next QA batch shows subject-tag dead-zone > 2% or
# Lap median < 400, restore the global profile by removing the override
# below (single-constant revert, backups in temp/backups/*quality-split).
SUBJECT_QUALITY_TAGS = {
    # Round 4 had 7 tags; Round 7 (2026-09-02) narrowed to 3 after real
    # generation results: only Pets/Animals/Birds (the subject-scale-fix
    # trio) benefit from the relaxed profile. Food/Transportation/People/
    # Sports revert to the global full-strength quality words.
    "Animals",
    "Pets",
    "Birds",
}
SUBJECT_QUALITY_PREFIX = (
    "deep depth of field with consistent sharpness, clear visual hierarchy, "
    "varied shape color and scale between regions"
)
SUBJECT_QUALITY_TAIL = "medium-scale readable details, full-bleed artwork"

# Round 8 (2026-09-02): Sports subject->env affinity groups (same mechanism
# as ANIMALS_ENV_GROUPS). Each group has >=3 venues so build_jobs'
# rng.sample(env_pool, 3) never falls back to the unfiltered tag pool.
# Round 10 (2026-09-02): court group split into 6 homogeneous sub-groups.
# The old single "court" group mixed 4 mutually-exclusive sport surfaces
# (hardwood arena / stadium stands / grass pitch / tennis hall), so
# rng.sample(pool, 3) guaranteed 3 different venue types per image,
# burying the subject under incompatible environments.  Each new sub-group
# now contains >=3 visually-compatible variants of the SAME venue type.
SPORTS_ENV_GROUPS = {
    # Outdoor grass pitch: soccer, rugby, field hockey
    "grass_field": [
        "sunny grass pitch with white boundary lines and corner flags",
        "floodlit stadium grass field with crisp line markings",
        "dewy morning grass pitch under soft overcast sky",
    ],
    # Indoor hardwood arena: basketball, rhythmic gymnastics
    "hardwood_arena": [
        "indoor arena with polished hardwood floor and upper tier stands",
        "bright gymnasium with glossy maple hardwood and tiered bleachers",
        "spacious sports hall with wooden floor and overhead spotlights",
    ],
    # Indoor court complex: tennis, badminton, table tennis, fencing, snooker
    "indoor_court": [
        "indoor sports hall with painted court lines and net posts",
        "bright indoor court complex with overhead lighting",
        "clean indoor venue with marked floor lines and court partitions",
    ],
    # Outdoor open field: golf, baseball, archery, equestrian
    "outdoor_field": [
        "open grassy field under wide blue sky",
        "sunlit outdoor sports ground with distant tree line",
        "overcast outdoor field with soft diffused light",
    ],
    # Indoor gym / training studio: barbell, boxing, gold medal
    "gym_studio": [
        "training gym with weight racks and mirrored walls",
        "indoor fitness studio with equipment and bright lighting",
        "clean training room with padded mats and overhead lights",
    ],
    # Beach sand court: volleyball
    "beach_court": [
        "sandy beach court with net posts and ocean breeze",
        "sunlit beach volleyball court with soft sand",
        "breezy seaside sand court under clear sky",
    ],
    "track": [
        "red rubber running track with white lane lines",
        "velodrome with steep wooden banked track",
        "climbing wall with colorful holds",
        "urban skate park with concrete ramps and graffiti walls",
        "winding mountain road with guardrails",
        "muddy forest trail with roots and puddles",
        "misty mountain ridge trail",
        "golden dune sea rally track",
    ],
    "snow": [
        "sunlit ski resort with groomed slopes",
        "frozen lake rink ringed by snow banks",
        "alpine village with frosted pine trees",
        "groomed forest ski trail between snow-laden pines",
        "tall frozen blue ice waterfall",
        "glacier slope with deep blue crevasses",
    ],
    "water": [
        "calm turquoise lagoon with sandy shallows",
        "whitewater river with foaming rapids",
        "marina docks with rigging and ropes",
        "swimming pool with crystal blue lane ropes",
        "windy bay with whitecap waves",
        "mirror-calm river lined with autumn trees",
    ],
}
SPORTS_SUBJECT_ENV_GROUP = {
    # grass_field — outdoor grass pitch
    "soccer ball hitting the back of the goal net": "grass_field",
    "rugby ball on grass with goal posts": "grass_field",
    "field hockey stick and ball on turf": "grass_field",
    # hardwood_arena — indoor wooden floor
    "basketball on glossy hardwood court": "hardwood_arena",
    "rhythmic gymnastics ribbon curling mid-air": "hardwood_arena",
    # indoor_court — indoor marked courts
    "tennis racket and ball on red clay court": "indoor_court",
    "white badminton shuttlecock mid-flight over the net": "indoor_court",
    "table tennis paddle and ball over blue table": "indoor_court",
    "snooker table with racked balls and cue": "indoor_court",
    "fencing foil and mask on the piste": "indoor_court",
    # outdoor_field — open outdoor ground
    "golf ball on tee beside a sand bunker": "outdoor_field",
    "baseball glove and ball on infield dirt": "outdoor_field",
    "equestrian saddle and bridle at the paddock fence": "outdoor_field",
    "archery target bristling with arrows": "outdoor_field",
    # gym_studio — indoor training / fitness
    "barbell loaded with colorful weight plates": "gym_studio",
    "boxing glove striking the focus mitt": "gym_studio",
    "gold medal hanging on a ribbon": "gym_studio",
    # beach_court — sand court
    "volleyball at the net over sandy court": "beach_court",
    # track & street & vertical
    "mountain bike on a gravel forest trail": "track",
    "colorful climbing holds with chalk dust": "track",
    "skateboard mid-air over a concrete ramp": "track",
    "road bike leaning through a hairpin turn": "track",
    "paraglider wing over an alpine valley": "track",
    "colorful parachute canopy opening in the sky": "track",
    "formula race car cornering at speed": "track",
    "track spike shoe on a red running lane": "track",
    # snow & ice
    "ice hockey stick and puck on glossy ice": "snow",
    "alpine ski carving through fresh powder": "snow",
    "snowboard carving a groomed mountain slope": "snow",
    "figure skating spin": "snow",
    "granite curling stone sliding on pebbled ice": "snow",
    "bobsled speeding down an icy track": "snow",
    # water
    "paddleboard on calm turquoise water": "water",
    "surfboard inside a translucent barrel wave": "water",
    "whitewater kayak cutting through rapids": "water",
    "sailboat heeling with taut white sails": "water",
    "diving platform over crystal pool water": "water",
    "snorkel mask and fins on a boat deck": "water",
    "fishing rod and reel at a lakeside pier": "water",
    "yoga mat on a beach deck at sunrise": "water",
    # Round 9 (2026-09-02): 野趣户外特写（体育场之外）subjects
    # snow & ice — 越野/攀冰/冰钓/雪地摩托/冰川登山
    "cross-country skis on a snowy forest trail": "snow",
    "ice climbing tools on a frozen blue waterfall": "snow",
    "ice fishing rod at a drilled hole on a frozen lake": "snow",
    "snowmobile carving through deep powder": "snow",
    "ice axe and crampons gripping a glacier slope": "snow",
    # water — 风筝冲浪/帆板/赛艇/尾波滑水
    "kite surfing kite curving above breaking waves": "water",
    "windsurf board planing across a windy bay": "water",
    "racing shell with oars on a mirror-calm river": "water",
    "wakeboard carving a glassy wake": "water",
    # track & trail & dune — 越野跑/徒步/定向/飞盘高尔夫/沙漠摩托
    "trail running shoe on a muddy forest path": "track",
    "hiking backpack and trekking poles on a mountain ridge": "track",
    "bright orienteering flag marking a forest checkpoint": "track",
    "disc golf chain basket among shady trees": "track",
    "dirt bike launching off a desert dune": "track",
}

# Fallback env partners when a tag has fewer than 3 (templates need fg/mid/bg).
ENV_FALLBACK = [
    "detailed foreground texture",
    "atmospheric midground elements",
    "rich background depth",
]

# v4 lighting/style_pool fixes to apply post-copy.
LIGHTING_FIXES = {
    "even overcast light": "dramatic high-contrast lighting",
}
STYLE_POOL_FIXES = {
    "detailed risograph print with layered textures": "intricate layered digital illustration with dense ornamental detail",
}

# ---------------------------------------------------------------------------
# P0 modifier-pool fixes — derived from JigsawTest2 (364 images, 21 tags)
# empirical debiased attribution (Δ_adj = within-tag mean(with) - mean(without)).
#
# Selection rule: only touch words with n >= 24 and |Δ_adj| >= 3.4.
# Boost multiplier is capped at 2 (3 only for the single most reliable word)
# because measured honest gain decomposition is:
#     drop-only = +4.0   boost-only = +1.8   both = +4.6
# i.e. the gain comes from precise DROPS; boosting adds little and collapses
# pool diversity. Do not raise multipliers chasing the in-sample +6.6 —
# that number carries ~66% optimism (5-fold out-of-sample estimate is +4.0..+4.6).
#
# Deliberately NOT dropped (evidence insufficient, do not "fix" these):
#   - "intricate layered digital illustration with dense ornamental detail"
#     Δ_adj=-21.1 but n=14, and its near-twin "...decorative illustration..."
#     measures +10.1 at n=12 — the direction is contradictory, not a signal.
#   - "textured gouache illustration with visible brushstrokes" (-5.9, n=12)
#   - "realistic material rendering with accurate textures" (-3.5 here,
#     +13.0 in JigsawTest1 — sign flip means noise dominates)
#   - "crisp detailed photography with high dynamic range" (-1.9 / +3.2 flip)
#   - "low angle view" (-2.1, too small to justify the diversity loss)
# ---------------------------------------------------------------------------
MODIFIER_DROPS = {
    "lighting": [
        "golden hour light",  # Δ_adj -5.4  n=40
        "crisp bright daylight",  # Δ_adj -4.8  n=48
        "raking low sunlight",  # Δ_adj -3.9  n=48
    ],
    "atmosphere": [
        "fresh bright daylight tones",  # Δ_adj -9.0  n=38  (worst word overall)
    ],
}
MODIFIER_BOOSTS = {
    "lighting": {
        "dramatic high-contrast lighting": 2,  # +5.6  n=24
        "dappled sunlight": 2,  # +3.6  n=26
        "warm interior light": 2,  # +3.5  n=48
    },
    "atmosphere": {
        "candy-bright multicolor palette": 2,  # +4.4  n=68
        "high contrast bold colors": 2,  # +3.4  n=50
    },
}
STYLE_DROPS = {
    "photo": [
        "high detail photographic rendering with a clean finish",  # -5.5  n=32
    ],
}
STYLE_BOOSTS = {
    "photo": {
        "documentary style photography with true to life color": 3,  # +7.1  n=32
        "photorealistic with crisp natural texture": 2,  # +2.4  n=28
    },
    "illust": {
        "richly detailed painterly illustration with layered depth": 2,  # +9.6  n=20
    },
}

# Metadata string was wrong in every one of the 364 JigsawTest2 records
# (it claimed 9 steps / CFG 1.1 while generation actually used 8 / 1.0).
MODEL_HINT_FIX = "z-image-turbo-fp8 (Apache 2.0, 8 steps, CFG 1.0)"

# ---------------------------------------------------------------------------
# v5.1 catalog hygiene (2026-09-01, integrated review P0).
# Applied post-translate so a rebuild cannot regress the hand-edited JSON.
# -------------------------------------------------------------------------
# Trademark / IP dilution + portrait-risk rewrites. Generic replacements keep
# the visual concept without the brand name.
SUBJECT_REWRITES = {
    # animation studios / styles (Cartoon)
    "Studio Ghibli style landscape": "hand-drawn anime film landscape with vivid cumulus skies",
    "Pixar 3D style": "stylized 3D animated film look",
    "Disney 3D style": "stylized 3D animated film look",
    "Shinkai-style windmill railway crossing cherry petals blue sky cumulus": "vivid anime film style windmill railway crossing with cherry petals and towering cumulus",
    # trademarks (Transportation / Others)
    "LEGO medieval castle with minifigures": "colorful interlocking brick castle with tiny figures",
    "VW T1 camper van": "retro pastel camper van",
    "VW Beetle": "vintage rounded compact car",
    "Mini Cooper": "classic British compact car",
    "antique Rolls-Royce": "antique luxury limousine",
    "F1 racing car": "open-wheel race car",
    "F1 car cornering": "formula race car cornering at speed",
    "Harley-Davidson motorcycle": "classic American cruiser motorcycle",
    "Vespa scooter": "vintage Italian scooter",
    "Ford Mustang": "classic American muscle car",
    "Chevrolet Corvette": "classic American sports car",
    "Cadillac": "vintage American luxury car with tail fins",
    "Lamborghini": "sleek Italian supercar",
    "Ferrari": "red Italian sports car",
    "Land Rover": "classic rugged off-roader",
    "Glacier Express": "panoramic scenic mountain train",
    # identifiable portraits -> crowd scenes (People)
    "kimono girl walking under cherry blossoms": "kimono festival procession on a busy Japanese street",
    "Indian sari dancer": "colorful Indian wedding celebration crowd",
    "Venice carnival costumed nobility": "Venice carnival masked crowd scene",
    "child building sandcastle on beach": "family building sandcastle on beach",
    # dead-zone / bokeh trigger wording (Ocean / Others)
    "tropical lagoon shallows": "turquoise lagoon with coral heads",
    "aged hand-drawn parchment nautical map": "vintage hand-drawn nautical map with sea monsters and compass roses",
}

# Absolute deletions: painting IP, repetitive-pattern jigsaw killers, dead zones.
SUBJECT_BLOCKLIST = {
    "Mona Lisa",
    "The Last Supper",
    "kaleidoscope symmetric pattern",
    "Islamic mosaic tile pattern",
    "mandala concentric circle totem",
    "Mandelbrot and Julia set fractals",
    "mystical symbol decorative mandala",
    "alchemy symbol magic circle",
    "aged parchment background",
    "black hole accretion disk with gravitational lensing",
}

# Cross-tag duplicates: keep one side only.
TAG_SUBJECT_REMOVES = {
    "Pets": ["green iguana"],
    "Animals": ["dolphin", "humpback whale", "blue whale", "manatee"],
    "Ocean": ["coastal cliffs"],
    "Landscapes": [
        "coastal lighthouse",
        "covered bridge",
        "Dutch windmill fields",
        "open field hot air balloons",
    ],
    "Transportation": ["dragon boat"],
    # moved to Art (illustration subjects don't belong in the photo Flowers tag)
    "Flowers": [
        "vintage botanical hand-drawn illustration",
        "mushroom watercolor natural history painting",
        "hand-drawn insect butterfly specimen display painting",
    ],
}

# Subjects the catalog does not carry yet (market-data driven additions).
EXTRA_SUBJECTS = {
    "Art": [
        "vintage botanical hand-drawn illustration",
        "mushroom watercolor natural history painting",
        "hand-drawn insect butterfly specimen display painting",
    ],
    # Colorful flat-lay scenes: 10.1% handicraft + 19.6% multicolor demand in
    # the most-played stats vs 5 existing entries (docs/mostplayed-...md).
    "Others": [
        "craft table covered with rainbow yarn balls",
        "sewing desk with thread spools arranged in color rows",
        "glass jars filled with colorful marbles",
        "wooden tray of colored pencils arranged by spectrum",
        "craft wall of embroidery floss colors",
        "jewelry tray with beaded necklaces in jewel tones",
        "candy shop counter with jars in rainbow rows",
        "haberdashery shelf with ribbon spools in bright colors",
        "quilting table with stacks of folded fabric",
        "painter's desk with watercolor sets and scattered brushes",
        "cork board with enamel pin collection",
        "stationery drawer with washi tape rolls",
        "travel desk covered with postcards and vintage stamps",
        "seashell collection arranged by color",
        "herbarium sheets with pressed dried flowers",
        "spice shelf with jars in rainbow rows",
        "wool shop shelf with dyed yarn hanks in gradient colors",
    ],
}

# Abstract subjects that are real photographable textures -> photo style pool.
ABSTRACT_PHOTO_SUBJECTS = [
    "acrylic fluid pour painting",
    "natural marble cross-section",
    "high-speed water droplet impact colorful liquid crown",
    "multi-layer gold leaf crackle mosaic",
    "terrazzo chips glass granule collage",
    "mottled gold leaf oil painting texture",
    "stained glass shards composition",
    "tree bark wood grain",
    "water ripple pattern",
    "metal rust texture",
    "fabric weave",
    "stone slate cracks",
    "concrete texture",
    "ink diffusion wash and alcohol ink",
    "paint splatter and ink splash",
    "batik",
]

# Animals subject->climate affinity so a polar bear never lands on a volcano.
ANIMALS_ENV_GROUPS = {
    "arctic": [
        "snow-dusted scree cliff",
        "glacier ice field with blue crevasses",
        "arctic tundra with frost patterns",
        "northern spruce taiga in snow",
    ],
    "alpine": [
        "snow-dusted scree cliff",
        "rocky highland cliffs with lingering snow",
        "alpine meadow scattered with boulders",
        "windswept mountain ridge",
    ],
    "savanna": [
        "acacia savanna",
        "golden grassland with scattered trees",
        "dry riverbed with cracked earth",
        "baobab woodland",
    ],
    "tropical": [
        "tropical rainforest vines",
        "dappled sunlight bamboo forest",
        "jungle riverbank with dense foliage",
        "cloud forest dripping with epiphytes",
    ],
    "forest": [
        "mossy fallen logs",
        "birch and fern woodland",
        "misty pine forest",
        "autumn deciduous forest floor",
    ],
    "water": [
        "rocky shoreline with kelp beds",
        "shallow river with smooth stones",
        "coastal tide pools",
        "reedy lake shore",
    ],
    "desert": [
        "red sand dunes",
        "rocky desert with cacti",
        "sun-baked canyon rocks",
        "palm oasis edge",
    ],
    "prehistoric": [
        "prehistoric fern grove",
        "smoking active volcano",
        "primordial swamp with cycads",
        "rugged volcanic badlands",
    ],
}
ANIMALS_SUBJECT_ENV_GROUP = {
    "polar bear": "arctic",
    "arctic wolf": "arctic",
    "arctic fox": "arctic",
    "beluga whale": "arctic",
    "walrus": "arctic",
    "reindeer": "arctic",
    "arctic hare": "arctic",
    "snow leopard": "alpine",
    "argali": "alpine",
    "marmot": "alpine",
    "alpaca": "alpine",
    "golden snub-nosed monkey": "alpine",
    "lion": "savanna",
    "lioness with cubs": "savanna",
    "cheetah": "savanna",
    "giraffe": "savanna",
    "zebra": "savanna",
    "african elephant": "savanna",
    "white rhinoceros": "savanna",
    "black rhinoceros": "savanna",
    "hippopotamus": "savanna",
    "hyena": "savanna",
    "meerkat": "savanna",
    "african buffalo": "savanna",
    "impala": "savanna",
    "wildebeest": "savanna",
    "oryx": "savanna",
    "ostrich": "savanna",
    "tiger": "tropical",
    "white tiger": "tropical",
    "leopard": "tropical",
    "jaguar": "tropical",
    "black panther": "tropical",
    "orangutan": "tropical",
    "gorilla": "tropical",
    "ring-tailed lemur": "tropical",
    "chameleon": "tropical",
    "red-eyed tree frog": "tropical",
    "poison dart frog": "tropical",
    "emerald tree boa": "tropical",
    "proboscis monkey": "tropical",
    "squirrel monkey": "tropical",
    "malayan tapir": "tropical",
    "gray wolf": "forest",
    "red fox": "forest",
    "lynx": "forest",
    "raccoon": "forest",
    "brown bear": "forest",
    "black bear": "forest",
    "moose": "forest",
    "sika deer": "forest",
    "elk": "forest",
    "red squirrel": "forest",
    "gray squirrel": "forest",
    "wild rabbit": "forest",
    "giant panda": "forest",
    "red panda": "forest",
    "koala": "forest",
    "shark": "water",
    "seal": "water",
    "sea lion": "water",
    "sea otter": "water",
    "otter": "water",
    "beaver": "water",
    "platypus": "water",
    "capybara": "water",
    "gharial": "water",
    "crocodile": "water",
    "alligator": "water",
    "caiman": "water",
    "camel": "desert",
    "fennec fox": "desert",
    "gila monster": "desert",
    "rattlesnake": "desert",
    "tyrannosaurus rex": "prehistoric",
    "triceratops": "prehistoric",
    "brachiosaurus": "prehistoric",
    "stegosaurus": "prehistoric",
    "pterodactyl": "prehistoric",
    "mammoth": "prehistoric",
    "saber-toothed tiger": "prehistoric",
}

# Quality prefix sits right after the subject (Qwen weights early tokens
# higher); the tail keeps the texture/technical wording. Replaces the old
# 515-char tail-only suffix with its "no ..." negatives and "clean" poison.
QUALITY_PREFIX = (
    "corner-to-corner dense detail, deep depth of field with consistent "
    "sharpness, busy composition with clear visual hierarchy, varied shape "
    "color and scale between regions"
)
QUALITY_TAIL = (
    "rich micro texture variation into all four corners, medium-scale "
    "readable details, full-bleed artwork"
)
# Art override: monochrome media (charcoal/engraving) conflicts with
# color-variance wording; use tonal range instead.
ART_QUALITY_PREFIX = (
    "corner-to-corner dense detail, rich tonal range and contrast, busy "
    "composition with clear visual hierarchy, varied shapes and scales "
    "between regions"
)

# Build-time assertion: none of these may survive into the output JSON.
RISK_WORD_RE = re.compile(
    r"LEGO|Ghibli|Pixar|Shinkai|Disney|Mona Lisa|Last Supper|kaleidoscope|"
    r"mandala|Mandelbrot|parchment|accretion|Harley|Vespa|Rolls-Royce|"
    r"Mustang|Lamborghini|Ferrari|Land Rover|Corvette|Cadillac|F1 racing",
    re.IGNORECASE,
)


def apply_pool_ops(items: list, drops: list, boosts: dict) -> list:
    """Drop negative words, then express weighting by repeating entries.

    The v5 generator draws modifiers with a plain uniform `rng.choice(pool)`,
    so repeating a word k times is exactly a k-x weight — no generator change
    needed. Keeps the abstraction thin.
    """
    out = [x for x in items if x not in set(drops)]
    for word, mult in boosts.items():
        if word not in out:
            out.append(word)
        out.extend([word] * (int(mult) - 1))
    return out


# ---------------------------------------------------------------------------
# Prompt templates per group.
# Placeholders: {subject} {env_fg} {env_mid} {env_bg} {detail}
# ---------------------------------------------------------------------------
PROMPT_TEMPLATES = {
    # animal: Animals, Pets, Birds
    # T1: "scattered across" -> "in" (F10 stacking risk; env_fg noun phrases
    #   like "acacia savanna" can't be "scattered").
    # T2: "a lone...resting" -> "a single...framed by" (no hardcoded state;
    #   "lone" conflicts with plural subjects like "lioness with cubs",
    #   "wild horse herd", "ant colony"; "resting" wrong for flying birds etc).
    # T3: "one...in motion through" -> "a single...set against" (no hardcoded
    #   state; "in motion" wrong for sleeping panda, perched owl, etc).
    "animal": [
        "a single {subject} with {env_fg} in the foreground, {env_mid} at center, {env_bg} in the distance, and {detail} throughout",
        "a single {subject} framed by {env_fg} in the foreground, with {env_mid} nearby and {env_bg} beyond",
        "a single {subject} set against {env_fg}, with {env_mid} filling the middle ground and {env_bg} on the horizon",
    ],
    # scene: Nature, Landscapes, Cities, Architecture, Seasons, Transportation
    # T1: "across the foreground" -> "in the foreground" (cleaner).
    # T2: "vista" -> "setting" (vista is landscape-specific, awkward for
    #   Transportation/Cities); "leading the eye" -> "leading into the scene".
    # T3: "panoramic...landscape" -> "full...view" ("landscape" wrong for
    #   Cities/Architecture/Transportation; "panoramic" may conflict with
    #   ratio system when generating 1:1 or 2:3).
    "scene": [
        "a wide {subject} scene with {env_fg} in the foreground, {env_mid} filling the middle, and {env_bg} in the distance",
        "an expansive {subject} setting with {env_fg} leading into the scene, {env_mid} at center, and {env_bg} on the horizon",
        "a full {subject} view with {env_fg} in the foreground, {env_mid} stretching across the middle, and {env_bg} filling the far distance",
    ],
    # object: Flowers, Food, Art, Others
    # T1: remove "on a surface" + "scattered around" -> "in the foreground"
    #   (Art paintings and flower fields don't sit on a surface; "scattered"
    #   can't apply to noun phrases like "sunlit glass greenhouse").
    # T2: remove "across the surface" (same surface issue).
    # T3: "a close-up of a single" -> "a detailed" (F3 CRITICAL: "close-up" is
    #   the single strongest bokeh trigger, explicitly fixed in v4.3 F3 but
    #   reintroduced in v5).
    "object": [
        "a single {subject} with {env_fg} in the foreground, {env_mid} nearby, and {detail} throughout",
        "one {subject} surrounded by {env_fg}, with {env_mid} at center and {env_bg} filling the edges",
        "a detailed {subject} with {env_fg} in the foreground, {env_mid} nearby, and {env_bg} in the background",
    ],
    # special: Ocean, Space, Abstract, Holidays, Cartoon, Fantasy, Sports, People
    # T1: remove "composition" (too generic, awkward for People/Sports: "a
    #   single family picnic composition" is unnatural).
    # T2: "an intricate single...scene" -> "a richly detailed..." (intricate
    #   doesn't fit People/Sports; "richly detailed" is a quality descriptor
    #   valid for all subjects); "scattered throughout" -> "throughout" (F10).
    # T3: remove "vibrant" (doesn't fit People/Abstract/Sports portraits);
    #   add "framed by" for neutral spatial framing.
    "special": [
        "a single {subject} with {env_fg} in the foreground, {env_mid} filling the middle, and {env_bg} extending into all corners",
        "a richly detailed {subject} with {env_fg} throughout, {env_mid} at center, and {env_bg} filling every edge",
        "a single {subject} framed by {env_fg} in the foreground, with {env_mid} at center and {env_bg} filling the background",
    ],
}

# ---------------------------------------------------------------------------
# Chinese -> English translation dictionary
# ---------------------------------------------------------------------------
CN_TO_EN = {
    # === Tag 01: Animals ===
    # -- big cats --
    "狮子": "lion",
    "母狮与幼崽": "lioness with cubs",
    "老虎": "tiger",
    "白虎": "white tiger",
    "花豹": "leopard",
    "美洲豹": "jaguar",
    "黑豹": "black panther",
    "猎豹": "cheetah",
    "雪豹": "snow leopard",
    "美洲狮": "cougar",
    "猞猁": "lynx",
    "薮猫": "serval",
    "狞猫": "caracal",
    # -- canids & carnivores --
    "灰狼": "gray wolf",
    "北极狼": "arctic wolf",
    "赤狐": "red fox",
    "北极狐": "arctic fox",
    "耳廓狐": "fennec fox",
    "鬣狗": "hyena",
    "水獭": "otter",
    "海獭": "sea otter",
    "河狸": "beaver",
    "浣熊": "raccoon",
    # -- bears --
    "大熊猫": "giant panda",
    "小熊猫": "red panda",
    "北极熊": "polar bear",
    "棕熊": "brown bear",
    "黑熊": "black bear",
    # -- large herbivores --
    "非洲象": "african elephant",
    "亚洲象": "asian elephant",
    "长颈鹿": "giraffe",
    "斑马": "zebra",
    "美洲野牛": "american bison",
    "非洲水牛": "african buffalo",
    "白犀牛": "white rhinoceros",
    "黑犀牛": "black rhinoceros",
    "河马": "hippopotamus",
    "驼鹿": "moose",
    "驯鹿": "reindeer",
    "梅花鹿": "sika deer",
    "马鹿": "elk",
    "剑羚": "oryx",
    "黑斑羚": "impala",
    "角马": "wildebeest",
    "盘羊": "argali",
    "羊驼": "alpaca",
    "野马群": "wild horse herd",
    "骆驼": "camel",
    "鸵鸟": "ostrich",
    "鸸鹋": "emu",
    # -- primates --
    "大猩猩": "gorilla",
    "红毛猩猩": "orangutan",
    "环尾狐猴": "ring-tailed lemur",
    "金丝猴": "golden snub-nosed monkey",
    "山魈": "mandrill",
    "黑猩猩": "chimpanzee",
    "松鼠猴": "squirrel monkey",
    "猕猴": "macaque",
    "眼镜猴": "tarsier",
    "长鼻猴": "proboscis monkey",
    # -- reptiles & amphibians --
    "变色龙": "chameleon",
    "红眼树蛙": "red-eyed tree frog",
    "箭毒蛙": "poison dart frog",
    "象龟": "giant tortoise",
    "辐射陆龟": "radiated tortoise",
    "科莫多巨蜥": "komodo dragon",
    "绿鬣蜥": "green iguana",
    "翡翠树蚺": "emerald tree boa",
    "鳄鱼": "crocodile",
    "短吻鳄": "alligator",
    "凯门鳄": "caiman",
    "蟒蛇": "python",
    "眼镜蛇": "cobra",
    "响尾蛇": "rattlesnake",
    "蓝舌石龙子": "blue-tongued skink",
    "毒蜥": "gila monster",
    "褶边蜥蜴": "frilled lizard",
    "恒河鳄": "gharial",
    "蝾螈": "salamander",
    "雨蛙": "tree frog",
    "牛蛙": "bullfrog",
    # -- special species --
    "袋鼠": "kangaroo",
    "考拉": "koala",
    "袋熊": "wombat",
    "鸭嘴兽": "platypus",
    "针鼹": "echidna",
    "袋獾": "tasmanian devil",
    "狐獴": "meerkat",
    "树懒": "sloth",
    "穿山甲": "pangolin",
    "犰狳": "armadillo",
    "红松鼠": "red squirrel",
    "灰松鼠": "gray squirrel",
    "野兔": "wild rabbit",
    "雪兔": "arctic hare",
    "水豚": "capybara",
    "土拨鼠": "marmot",
    "蜜獾": "honey badger",
    "马来貘": "malayan tapir",
    # -- insects --
    "蝴蝶": "butterfly",
    "蜻蜓": "dragonfly",
    "蜜蜂": "honeybee",
    "瓢虫": "ladybug",
    "螳螂": "praying mantis",
    "锹甲": "stag beetle",
    "竹节虫": "stick insect",
    "蜘蛛": "spider",
    "蝎子": "scorpion",
    "蜗牛": "snail",
    "蜈蚣": "centipede",
    "蚂蚁群": "ant colony",
    # -- marine mammals --
    "海豚": "dolphin",
    "座头鲸": "humpback whale",
    "蓝鲸": "blue whale",
    "白鲸": "beluga whale",
    "鲨鱼": "shark",
    "海豹": "seal",
    "海狮": "sea lion",
    "海象": "walrus",
    "海牛": "manatee",
    # -- farm --
    "牛": "cow",
    "水牛": "water buffalo",
    "牦牛": "yak",
    "马": "horse",
    "驴": "donkey",
    "绵羊": "sheep",
    "山羊": "goat",
    "猪": "pig",
    "鸡": "chicken",
    "鸭": "duck",
    "鹅": "goose",
    # -- prehistoric --
    "霸王龙": "tyrannosaurus rex",
    "三角龙": "triceratops",
    "腕龙": "brachiosaurus",
    "剑龙": "stegosaurus",
    "翼龙": "pterodactyl",
    "猛犸象": "mammoth",
    "剑齿虎": "saber-toothed tiger",
    # === Tag 02: Pets ===
    # -- dogs --
    "柯基": "corgi",
    "柴犬": "shiba inu",
    "法国斗牛犬": "french bulldog",
    "博美": "pomeranian",
    "雪纳瑞": "schnauzer",
    "比熊": "bichon frise",
    "贵宾": "poodle",
    "吉娃娃": "chihuahua",
    "巴哥": "pug",
    "金毛": "golden retriever",
    "拉布拉多": "labrador retriever",
    "边牧": "border collie",
    "萨摩耶": "samoyed",
    "哈士奇": "siberian husky",
    "阿拉斯加": "alaskan malamute",
    "德牧": "german shepherd",
    "罗威纳": "rottweiler",
    "大丹": "great dane",
    "秋田": "akita",
    "杜宾": "doberman",
    "大麦町": "dalmatian",
    "灵缇": "greyhound",
    "约克夏": "yorkshire terrier",
    "马尔济斯": "maltese",
    "巴吉度": "basset hound",
    "比格犬": "beagle",
    "腊肠犬": "dachshund",
    # -- cats --
    "英国短毛猫": "british shorthair",
    "美国短毛猫": "american shorthair",
    "布偶猫": "ragdoll cat",
    "暹罗猫": "siamese cat",
    "波斯猫": "persian cat",
    "缅因猫": "maine coon",
    "斯芬克斯无毛猫": "sphynx cat",
    "苏格兰折耳猫": "scottish fold",
    "孟加拉豹猫": "bengal cat",
    "阿比西尼亚猫": "abyssinian cat",
    "挪威森林猫": "norwegian forest cat",
    "俄罗斯蓝猫": "russian blue",
    "伯曼猫": "birman",
    "异国短毛猫": "exotic shorthair",
    "橘猫": "orange tabby cat",
    "狸花猫": "dragon li cat",
    "三花猫": "calico cat",
    "奶牛猫": "tuxedo cat",
    # -- small mammals --
    "荷兰猪": "guinea pig",
    "豚鼠": "guinea pig",
    "侏儒兔": "dwarf rabbit",
    "垂耳兔": "lop-eared rabbit",
    "狮子兔": "lionhead rabbit",
    "安哥拉兔": "angora rabbit",
    "仓鼠": "hamster",
    "金丝熊": "syrian hamster",
    "龙猫": "chinchilla",
    "毛丝鼠": "chinchilla",
    "刺猬": "hedgehog",
    "蜜袋鼯": "sugar glider",
    "松鼠": "squirrel",
    "花栗鼠": "chipmunk",
    "迷你猪": "mini pig",
    "雪貂": "ferret",
    # -- birds --
    "柯尔鸭": "call duck",
    "虎皮鹦鹉": "budgerigar",
    "玄凤鹦鹉": "cockatiel",
    "牡丹鹦鹉": "lovebird",
    "金刚鹦鹉": "macaw",
    "金丝雀": "canary",
    "文鸟": "java sparrow",
    "八哥": "myna",
    "鹌鹑": "quail",
    "芦丁鸡": "silkie chicken",
    # -- fish --
    "斗鱼": "betta fish",
    "兰寿金鱼": "ranchu goldfish",
    "水泡金鱼": "bubble-eye goldfish",
    "锦鲤": "koi",
    "热带鱼群": "tropical fish school",
    "孔雀鱼": "guppy",
    "红绿灯鱼": "neon tetra",
    "宝莲灯灯科鱼": "cardinal tetra",
    "乌龟": "turtle",
    "巴西龟": "red-eared slider turtle",
    # -- reptile pets --
    "豹纹守宫": "leopard gecko",
    "睫角守宫": "crested gecko",
    "玉米蛇": "corn snake",
    "角蛙": "pacman frog",
    "苏卡达陆龟": "sulcata tortoise",
    # === Tag 03: Nature ===
    "千年红杉": "ancient redwood",
    "银杏古树": "ancient ginkgo tree",
    "大榕树气生根": "banyan tree with aerial roots",
    "翠绿竹林": "emerald bamboo grove",
    "白桦林": "birch forest",
    "蓝花楹树": "jacaranda tree",
    "参天古树": "towering ancient tree",
    "盘根错节": "intertwined tree roots",
    "苔藓": "moss",
    "鸟巢蕨": "bird's nest fern",
    "地衣": "lichen",
    "卷柏": "spikemoss",
    "积水凤梨": "tank bromeliad",
    "多肉微型花园": "miniature succulent garden",
    "石莲花": "echeveria",
    "生石花": "lithops",
    "玉露": "haworthia",
    "仙人掌群落": "cactus cluster",
    "金琥": "golden barrel cactus",
    "巨柱": "saguaro cactus",
    "食虫植物": "carnivorous plants",
    "捕蝇草": "venus flytrap",
    "猪笼草": "pitcher plant",
    "盆景": "bonsai",
    "荧光蘑菇": "bioluminescent mushrooms",
    "红伞白斑毒蝇伞": "fly agaric mushroom",
    "羊肚菌": "morel mushroom",
    "鸡油菌": "chanterelle",
    "灵芝": "lingzhi mushroom",
    "晨露叶脉水珠": "morning dew on leaf veins with water droplets",
    "溪流跳石": "stream with stepping stones",
    "苔藓瀑布": "mossy waterfall",
    "红树林呼吸根": "mangrove pneumatophores",
    "喀斯特溶洞钟乳石": "karst cave stalactites",
    "蓝冰微洞": "blue ice cave",
    "霜花冰晶": "frost flowers and ice crystals",
    "松果橡子散落": "scattered pinecones and acorns",
    "野生浆果丛": "wild berry bushes",
    "覆盆子": "raspberry",
    "蓝莓": "blueberry",
    "黑莓": "blackberry",
    "层叠落叶地表": "layered fallen leaves ground",
    "热带雨林内部": "tropical rainforest interior",
    "雾林": "cloud forest",
    "沼泽湿地": "marsh wetland",
    "草原": "grassland",
    "沙漠绿洲": "desert oasis",
    "峡谷内部": "canyon interior",
    "天坑": "giant sinkhole",
    "红叶树林": "autumn maple forest",
    "槭树林": "maple forest",
    "树皮纹理": "tree bark texture",
    "叶脉": "leaf veins",
    "岩石表面": "rock surface",
    "河床": "riverbed",
    "沙地纹理": "sand texture pattern",
    "冰晶": "ice crystals",
    "露珠": "dewdrops",
    # === Tag 04: Landscapes ===
    "日照金山": "golden sunrise on snow peak",
    "马特洪峰": "Matterhorn peak",
    "喜马拉雅群峰": "Himalayan peaks",
    "富士山与五湖红叶": "Mount Fuji with five lakes autumn foliage",
    "挪威峡湾冰川舌": "Norwegian fjord glacier tongue",
    "大提顿山": "Grand Teton mountain",
    "科罗拉多大峡谷": "Grand Canyon",
    "羚羊峡谷波浪光柱": "Antelope Canyon light beams",
    "张家界砂岩柱峰林": "Zhangjiajie sandstone pillars",
    "桂林漓江峰丛倒影": "Guilin Li River karst peaks reflection",
    "张掖七彩丹霞": "Zhangye rainbow danxia landform",
    "波浪谷砂岩纹路": "Wave Canyon sandstone patterns",
    "巨人之路玄武岩石柱": "Giant's Causeway basalt columns",
    "艾尔斯巨岩": "Uluru Ayers Rock",
    "乌鲁鲁": "Uluru",
    "伊瓜苏瀑布群": "Iguazu Falls",
    "尼亚加拉瀑布": "Niagara Falls",
    "维多利亚瀑布": "Victoria Falls",
    "九寨沟五彩池": "Jiuzhaigou Five-Color Pond",
    "班夫露易丝湖": "Banff Lake Louise",
    "梦莲湖": "Moraine Lake",
    "高山冰川湖": "alpine glacial lake",
    "峡湾": "fjord",
    "河谷": "river valley",
    "U形谷": "U-shaped valley",
    "贝加尔湖蓝冰": "Lake Baikal blue ice",
    "元阳梯田": "Yuanyang rice terraces",
    "龙脊梯田": "Longji rice terraces",
    "普罗旺斯薰衣草田": "Provence lavender fields",
    "荷兰郁金香花田": "Dutch tulip fields",
    "托斯卡纳麦田山丘": "Tuscany wheat field hills",
    "喀纳斯月亮湾彩林": "Kanas Moon Bay autumn forest",
    "茶园": "tea plantation",
    "葡萄园": "vineyard",
    "稻田": "rice paddies",
    "牧场": "pasture",
    "撒哈拉沙丘与骆驼队": "Sahara dunes with camel caravan",
    "冰岛黑沙滩钻石冰块": "Iceland black sand beach diamond ice",
    "北极光映雪原": "aurora borealis over snow field",
    "沙漠沙丘": "desert dunes",
    "活火山与熔岩流": "active volcano with lava flow",
    "黄石间歇泉与大棱镜温泉": "Yellowstone geyser and Grand Prismatic Spring",
    "棉花堡钙化池": "Pamukkale travertine terraces",
    "雷暴闪电风暴云": "thunderstorm lightning storm clouds",
    "彩虹与双彩虹": "rainbow and double rainbow",
    "日出日落全景": "sunrise sunset panorama",
    "黄金时刻山脉": "golden hour mountain range",
    "星空银河地景": "starry Milky Way landscape",
    "极光全景与湖泊倒影": "aurora panorama with lake reflection",
    "云海雾海": "sea of clouds and fog",
    "朝霞晚霞": "morning glow and sunset glow",
    "海岸悬崖": "coastal cliffs",
    "海湾": "bay",
    "热带岛屿鸟瞰": "tropical island aerial view",
    "海岸灯塔": "coastal lighthouse",
    "国家公园标志景观": "national park landmark landscape",
    "优胜美地半穹顶": "Yosemite Half Dome",
    "黄石": "Yellowstone",
    "大峡谷": "Grand Canyon",
    "孤树地平线": "lone tree on horizon",
    "非洲金合欢孤树": "African acacia lone tree",
    "苏格兰孤树": "Scottish lone tree",
    "荷兰风车田野": "Dutch windmill fields",
    "覆盖桥": "covered bridge",
    "新英格兰风格": "New England style",
    "开阔田野热气球群": "open field hot air balloons",
    # === Tag 05: Flowers ===
    "玫瑰": "rose",
    "月季": "china rose",
    "牡丹": "peony",
    "芍药": "herbaceous peony",
    "郁金香": "tulip",
    "百合": "lily",
    "向日葵": "sunflower",
    "绣球花": "hydrangea",
    "康乃馨": "carnation",
    "雏菊": "daisy",
    "洋甘菊": "chamomile",
    "罂粟花": "poppy",
    "薰衣草": "lavender",
    "茶花": "camellia",
    "水仙": "daffodil",
    "鸢尾花": "iris",
    "紫罗兰": "violet",
    "大丽花": "dahlia",
    "帝王花": "king protea",
    "樱花": "cherry blossom",
    "桃花": "peach blossom",
    "梅花": "plum blossom",
    "梨花": "pear blossom",
    "海棠": "crabapple blossom",
    "紫藤花廊": "wisteria pergola",
    "白玉兰": "white magnolia",
    "紫玉兰": "purple magnolia",
    "虞美人": "corn poppy",
    "冰岛罂粟": "Iceland poppy",
    "波斯菊": "cosmos",
    "铃兰": "lily of the valley",
    "风信子": "hyacinth",
    "三色堇": "pansy",
    "角堇": "viola",
    "荷花": "lotus",
    "睡莲": "water lily",
    "蝴蝶兰": "phalaenopsis orchid",
    "文心兰": "dancing lady orchid",
    "天堂鸟": "bird of paradise",
    "朱顶红": "amaryllis",
    "扶桑花": "hibiscus",
    "鸡蛋花": "plumeria",
    "马蹄莲": "calla lily",
    "蓝花楹": "jacaranda",
    "三角梅": "bougainvillea",
    "满天星": "baby's breath",
    "勿忘我": "forget-me-not",
    "野花草甸": "wildflower meadow",
    "多肉开花": "flowering succulents",
    "桂花": "osmanthus",
    "栀子花": "gardenia",
    "茉莉花": "jasmine",
    "非洲菊": "gerbera daisy",
    "石斛兰": "dendrobium orchid",
    "国兰": "chinese cymbidium orchid",
    "洋桔梗": "lisianthus",
    "插花静物": "floral arrangement still life",
    "陶罐": "ceramic pot",
    "瓷瓶": "porcelain vase",
    "水晶瓶": "crystal vase",
    "花店场景与花市货架高密度陈列": "flower shop scene with dense shelf display",
    "压花标本平铺": "pressed flower specimens flat lay",
    "花束": "flower bouquet",
    "新娘手捧花": "bridal bouquet",
    "花篮": "flower basket",
    "花墙花拱门": "flower wall and arch",
    "薰衣草田": "lavender field",
    "油菜花田": "rapeseed flower field",
    "郁金香花田": "tulip field",
    "向日葵田": "sunflower field",
    "樱花道": "cherry blossom avenue",
    "波斯菊花海": "cosmos flower sea",
    "罂粟花田": "poppy field",
    "桃花林": "peach blossom grove",
    "复古植物学手绘插画": "vintage botanical hand-drawn illustration",
    "蘑菇水彩博物画": "mushroom watercolor natural history painting",
    "手绘昆虫蝴蝶标本陈列画": "hand-drawn insect butterfly specimen display painting",
    "泛黄羊皮纸底色": "aged parchment background",
    # === Tag 06: Ocean ===
    "座头鲸": "humpback whale",
    "蓝鲸": "blue whale",
    "虎鲸群": "orca pod",
    "抹香鲸": "sperm whale",
    "海豚群": "dolphin pod",
    "鲸鲨": "whale shark",
    "蝠鲼": "manta ray",
    "鬼蝠魟": "giant oceanic manta ray",
    "海牛": "manatee",
    "儒艮": "dugong",
    "独角鲸": "narwhal",
    "小丑鱼": "clownfish",
    "蓝唐王鱼": "blue tang fish",
    "黄金吊": "yellow tang",
    "狮子鱼": "lionfish",
    "海马": "seahorse",
    "叶海龙": "leafy seadragon",
    "蝴蝶鱼群": "butterflyfish school",
    "神仙鱼": "angelfish",
    "沙丁鱼风暴": "sardine bait ball",
    "海龟": "sea turtle",
    "绿海龟": "green sea turtle",
    "玳瑁": "hawksbill turtle",
    "鳐鱼": "ray fish",
    "黄貂鱼群": "stingray school",
    "发光水母群": "bioluminescent jellyfish swarm",
    "海月水母": "moon jellyfish",
    "章鱼": "octopus",
    "大王乌贼": "giant squid",
    "海蛞蝓": "nudibranch",
    "海兔": "sea hare",
    "鹦鹉螺": "nautilus",
    "海星": "starfish",
    "海胆": "sea urchin",
    "寄居蟹": "hermit crab",
    "帝王蟹": "king crab",
    "椰子蟹": "coconut crab",
    "巨蚌": "giant clam",
    "活体珊瑚礁群": "living coral reef colony",
    "脑珊瑚": "brain coral",
    "鹿角珊瑚": "staghorn coral",
    "紫色海扇": "purple sea fan",
    "海绵": "sea sponge",
    "沉船残骸": "shipwreck wreck",
    "巨浪管涌": "giant barrel wave",
    "热带泻湖浅滩": "tropical lagoon shallows",
    "海浪拍灯塔崖壁": "waves crashing lighthouse cliff",
    "海滩沙滩": "beach sand",
    "礁石海岸": "rocky shore",
    "潮汐池": "tide pool",
    "冰山漂浮": "floating icebergs",
    "北极冰海": "arctic ice sea",
    "南极海域": "antarctic waters",
    "浮冰": "drifting ice",
    # === Tag 07: Birds ===
    "五彩金刚鹦鹉": "scarlet macaw",
    "托哥巨嘴鸟": "toco toucan",
    "彩虹吸蜜鹦鹉": "rainbow lorikeet",
    "凤头鹦鹉": "cockatoo",
    "葵花": "sulphur-crested cockatoo",
    "摩鹿加": "salmon-crested cockatoo",
    "蜂鸟": "hummingbird",
    "极乐鸟": "bird of paradise",
    "天堂鸟": "bird of paradise",
    "犀鸟": "hornbill",
    "白头海雕": "bald eagle",
    "金雕": "golden eagle",
    "猫头鹰家族": "owl family",
    "雪鸮": "snowy owl",
    "仓鸮": "barn owl",
    "雕鸮": "eurasian eagle-owl",
    "长耳鸮": "long-eared owl",
    "游隼": "peregrine falcon",
    "秃鹫": "vulture",
    "信天翁": "albatross",
    "天鹅": "swan",
    "黑天鹅": "black swan",
    "丹顶鹤": "red-crowned crane",
    "白鹭": "great white egret",
    "苍鹭": "grey heron",
    "翠鸟": "kingfisher",
    "鸳鸯": "mandarin duck",
    "鹈鹕": "pelican",
    "海鸥": "seagull",
    "黑鹳": "black stork",
    "白鹳": "white stork",
    "朱鹮": "crested ibis",
    "鸬鹚": "cormorant",
    "蓝孔雀": "blue peacock",
    "白孔雀": "white peacock",
    "绿孔雀": "green peacock",
    "红胸知更鸟": "robin",
    "银喉长尾山雀": "long-tailed tit",
    "红腹锦鸡": "golden pheasant",
    "蓝松鸦": "blue jay",
    "戴胜": "hoopoe",
    "啄木鸟": "woodpecker",
    "金翅雀": "goldfinch",
    "画眉": "hwamei",
    "黄鹂": "oriole",
    "白头鹎": "chinese bulbul",
    "火烈鸟群": "flamingo flock",
    "帝企鹅": "emperor penguin",
    "王企鹅": "king penguin",
    "阿德利企鹅": "adélie penguin",
    "跳岩企鹅": "rockhopper penguin",
    "北极海鹦": "puffin",
    "鸽子": "pigeon",
    "斑鸠": "dove",
    "麻雀": "sparrow",
    "乌鸦": "crow",
    "渡鸦": "raven",
    "喜鹊": "magpie",
    "燕子": "swallow",
    "火鸡": "turkey",
    # === Tag 08: Cities ===
    "鹅卵石小巷": "cobblestone alley",
    "外摆咖啡馆": "outdoor cafe",
    "阿姆斯特丹运河街景": "Amsterdam canal street",
    "威尼斯大运河": "Venice Grand Canal",
    "旧金山九曲花街": "San Francisco Lombard Street",
    "里斯本有轨电车老街": "Lisbon tram old street",
    "纽约曼哈顿": "New York Manhattan",
    "东京涩谷十字路口": "Tokyo Shibuya crossing",
    "香港维多利亚港": "Hong Kong Victoria Harbour",
    "上海外滩": "Shanghai Bund",
    "巴黎屋顶与埃菲尔铁塔": "Paris rooftops with Eiffel Tower",
    "迪拜天际线": "Dubai skyline",
    "芝加哥天际线": "Chicago skyline",
    "新加坡滨海湾": "Singapore Marina Bay",
    "台北101": "Taipei 101",
    "首尔N首尔塔": "Seoul N Seoul Tower",
    "曼谷大皇宫": "Bangkok Grand Palace",
    "好莱坞标志": "Hollywood Sign",
    "广州塔": "Canton Tower",
    "莫斯科天际线": "Moscow skyline",
    "伊斯坦布尔博斯普鲁斯海峡": "Istanbul Bosphorus Strait",
    "赛博朋克霓虹小吃街": "cyberpunk neon food street",
    "地中海白色小镇街巷": "Mediterranean white town alley",
    "摩洛哥麦地那老城": "Morocco medina old city",
    "重庆夜景山城": "Chongqing night cityscape",
    "布拉格老城广场与天文钟": "Prague Old Town Square with astronomical clock",
    "夜市街": "night market street",
    "城市公园": "city park",
    "地铁轨道交通": "subway rail transit",
    "屋顶花园": "rooftop garden",
    "街头艺人": "street performer",
    "1950年代美式复古餐厅内部": "1950s American retro diner interior",
    "黑白格子地板与点唱机": "checkerboard floor with jukebox",
    "老式乡村杂货店内部": "vintage country general store interior",
    "罐头糖果罐货架": "canned goods and candy jar shelves",
    "红色农仓": "red barn",
    "谷仓": "barn",
    "风向标与碎花被子": "weather vane and floral quilt",
    "乡村汽车影院夜景": "rural drive-in theater night scene",
    "威尼斯水城街道": "Venice water city street",
    "欧洲圣诞集市街道": "European Christmas market street",
    "雨中城市街道": "rainy city street",
    "城市霓虹夜景": "city neon night scene",
    "无人机俯瞰": "drone aerial view",
    "蓝调时刻": "blue hour",
    # === Tag 09: Architecture ===
    "埃菲尔铁塔": "Eiffel Tower",
    "凯旋门": "Arc de Triomphe",
    "泰姬陵": "Taj Mahal",
    "长城": "Great Wall of China",
    "故宫太和殿与角楼": "Forbidden City Hall of Supreme Harmony with corner tower",
    "罗马斗兽场": "Roman Colosseum",
    "万神殿": "Pantheon",
    "比萨斜塔": "Leaning Tower of Pisa",
    "圣瓦西里大教堂": "St. Basil's Cathedral",
    "吉萨金字塔": "Giza Pyramids",
    "狮身人面像": "Great Sphinx",
    "悉尼歌剧院": "Sydney Opera House",
    "雅典卫城": "Acropolis of Athens",
    "圣家堂": "Sagrada Familia",
    "吴哥窟": "Angkor Wat",
    "圣彼得大教堂": "St. Peter's Basilica",
    "马丘比丘": "Machu Picchu",
    "佩特拉古城": "Petra",
    "圣米歇尔山": "Mont Saint-Michel",
    "自由女神像": "Statue of Liberty",
    "大本钟": "Big Ben",
    "勃兰登堡门": "Brandenburg Gate",
    "里约救世基督像": "Christ the Redeemer",
    "圣索菲亚大教堂": "Hagia Sophia",
    "蓝色清真寺": "Blue Mosque",
    "克里姆林宫与红场": "Kremlin and Red Square",
    "卢浮宫玻璃金字塔": "Louvre Glass Pyramid",
    "白金汉宫": "Buckingham Palace",
    "巴黎圣母院": "Notre-Dame Cathedral",
    "巨石阵": "Stonehenge",
    "复活节岛摩艾石像": "Easter Island Moai statues",
    "奇琴伊察金字塔": "Chichen Itza pyramid",
    "天坛祈年殿": "Temple of Heaven Hall of Prayer for Good Harvests",
    "黄鹤楼": "Yellow Crane Tower",
    "西安大雁塔与钟楼": "Xi'an Giant Wild Goose Pagoda and Bell Tower",
    "南京中山陵": "Nanjing Sun Yat-sen Mausoleum",
    "浅草寺五重塔": "Senso-ji Five-story Pagoda",
    "新天鹅堡": "Neuschwanstein Castle",
    "温莎城堡": "Windsor Castle",
    "霍华德庄园": "Castle Howard",
    "香波堡": "Château de Chambord",
    "姬路城天守阁": "Himeji Castle main keep",
    "阿尔罕布拉宫": "Alhambra",
    "爱丁堡城堡": "Edinburgh Castle",
    "凡尔赛宫": "Palace of Versailles",
    "布达拉宫": "Potala Palace",
    "布拉格城堡": "Prague Castle",
    "金门大桥": "Golden Gate Bridge",
    "伦敦塔桥": "Tower Bridge of London",
    "布鲁克林大桥": "Brooklyn Bridge",
    "威尼斯里亚托桥": "Venice Rialto Bridge",
    "叹息桥": "Bridge of Sighs",
    "加尔桥古罗马水渠": "Pont du Gard Roman aqueduct",
    "赵州桥": "Zhaozhou Bridge",
    "现代斜拉桥": "modern cable-stayed bridge",
    "圣托里尼蓝顶白墙": "Santorini blue-domed white walls",
    "五渔村彩色房屋": "Cinque Terre colorful houses",
    "挪威红色水上木屋": "Norwegian red waterfront cabin",
    "科茨沃尔德茅草顶农舍": "Cotswolds thatched roof cottage",
    "徽派马头墙水乡": "Hui-style horse-head wall water village",
    "中国古镇水乡": "Chinese ancient water town",
    "乌镇": "Wuzhen",
    "周庄风格": "Zhouzhuang style",
    "日式町屋": "Japanese machiya townhouse",
    "合掌屋": "gassho-zukuri farmhouse",
    "中国四合院": "Chinese siheyuan courtyard",
    "土楼": "tulou earth building",
    "北欧木屋": "Nordic wooden cabin",
    "印度阶梯井": "Indian stepwell",
    "海岸灯塔": "coastal lighthouse",
    "经典红白条纹灯塔": "classic red-and-white striped lighthouse",
    "传统风车与水车": "traditional windmill and waterwheel",
    "荷兰风车村": "Dutch windmill village",
    "温室花房": "greenhouse conservatory",
    "日式枯山水庭园": "Japanese zen dry landscape garden",
    "哥特式大教堂": "gothic cathedral",
    "巴洛克教堂": "baroque church",
    "清真寺": "mosque",
    "寺庙佛塔": "temple pagoda",
    "神社鸟居": "shrine torii gate",
    "修道院": "monastery",
    "摩天大楼": "skyscraper",
    "螺旋建筑": "spiral building",
    "未来主义建筑": "futuristic building",
    "博物馆建筑": "museum building",
    "音乐厅": "concert hall",
    "机场航站楼": "airport terminal",
    "巴洛克图书馆通天书架": "baroque library with floor-to-ceiling bookshelves",
    "哥特教堂彩窗花窗": "gothic church stained glass windows",
    "巴黎歌剧院大理石阶梯": "Paris Opera House marble staircase",
    "维多利亚铸铁温室花房": "Victorian cast-iron conservatory",
    "宫殿大厅镜厅": "palace hall of mirrors",
    "旋转楼梯": "spiral staircase",
    "酒店大堂": "hotel lobby",
    "园艺工具房": "potting shed with terracotta pots and seed bags",
    "老木工车间": "old woodworking shop with shavings and chisels",
    "温馨缝纫室": "cozy sewing room with piled fabrics",
    "壁炉书房阅读角": "fireplace study reading nook with cat and dog on rug",
    "欧洲乡村厨房": "European country kitchen with pots and herb bundles",
    # === Tag 10: Food ===
    "三层下午茶点心架": "three-tier afternoon tea stand",
    "草莓奶油蛋糕": "strawberry cream cake",
    "黑森林蛋糕": "black forest cake",
    "可颂": "croissant",
    "美式松饼塔": "American pancake tower",
    "冰淇淋华夫甜筒": "ice cream waffle cone",
    "马卡龙": "macarons",
    "可丽露": "canelés",
    "闪电泡芙": "éclair",
    "柠檬挞": "lemon tart",
    "芝士蛋糕": "cheesecake",
    "甜甜圈": "donuts",
    "纸杯蛋糕": "cupcakes",
    "提拉米苏": "tiramisu",
    "舒芙蕾": "soufflé",
    "熔岩蛋糕": "molten lava cake",
    "泡芙": "cream puffs",
    "布丁": "pudding",
    "法式焦糖烤布蕾": "crème brûlée",
    "窑烤披萨": "wood-fired pizza",
    "牛肉汉堡": "beef burger",
    "薯条洋葱圈": "fries and onion rings",
    "寿司刺身拼盘": "sushi sashimi platter",
    "日式拉面": "Japanese ramen",
    "中式蒸笼点心": "Chinese steamer dim sum",
    "虾饺": "shrimp dumplings",
    "小笼汤包": "soup dumplings",
    "烧麦": "shumai",
    "千层面": "lasagna",
    "墨鱼意面": "squid ink pasta",
    "咖喱饭": "curry rice",
    "火锅": "hot pot",
    "烤鸭": "roast duck",
    "麻婆豆腐": "mapo tofu",
    "天妇罗": "tempura",
    "章鱼烧": "takoyaki",
    "石锅拌饭": "stone pot bibimbap",
    "炒饭炒面": "fried rice and noodles",
    "饺子锅贴": "dumplings and potstickers",
    "墨西哥塔可": "Mexican tacos",
    "卷饼": "wraps",
    "惠灵顿牛排": "beef wellington",
    "越南河粉": "Vietnamese pho",
    "泰式冬阴功汤": "Thai tom yum soup",
    "土耳其烤肉卷": "Turkish kebab wrap",
    "麻辣小龙虾": "spicy crawfish",
    "冰镇海鲜拼盘": "chilled seafood platter",
    "龙虾": "lobster",
    "帝王蟹腿": "king crab legs",
    "生蚝": "oysters",
    "青口贝": "mussels",
    "烟熏烤肋排": "smoked BBQ ribs",
    "西班牙海鲜饭": "Spanish paella",
    "熟食奶酪拼盘": "charcuterie cheese board",
    "火腿卷": "prosciutto rolls",
    "芝士": "cheese",
    "核桃": "walnuts",
    "无花果": "figs",
    "葡萄": "grapes",
    "热带水果拼盘": "tropical fruit platter",
    "切开的水果静物": "sliced fruit still life",
    "西瓜": "watermelon",
    "草莓": "strawberries",
    "苹果": "apples",
    "蔬菜平铺与农贸市场": "vegetable flat lay and farmers market",
    "法式吐司": "French toast",
    "可丽饼": "crêpes",
    "沙拉碗": "salad bowl",
    "酸奶碗": "yogurt bowl",
    "班尼迪克蛋": "eggs benedict",
    "三明治": "sandwich",
    "全套早餐": "full breakfast with eggs bacon toast",
    "拿铁拉花咖啡": "latte art coffee",
    "英式茶具": "English tea set",
    "夏日鸡尾酒": "summer cocktail",
    "莫吉托": "mojito",
    "红酒香槟": "red wine and champagne",
    "威士忌": "whiskey",
    "抹茶拿铁": "matcha latte",
    "奶茶珍珠奶茶": "milk tea with boba",
    "果汁冰沙": "smoothie and fruit juice",
    "热巧克力": "hot chocolate",
    "月饼": "mooncakes",
    "粽子": "zongzi",
    "汤圆": "tangyuan",
    "烧卖虾饺": "shumai and shrimp dumplings",
    "肠粉": "rice noodle rolls",
    "蛋挞": "egg tarts",
    "老婆饼": "sweetheart cake",
    "糖葫芦": "candied hawthorn sticks",
    "八宝饭": "eight-treasure rice",
    "春卷": "spring rolls",
    "巧克力": "chocolates",
    "糖果": "candies",
    "薯片": "potato chips",
    "爆米花": "popcorn",
    "马卡龙塔": "macaron tower",
    "异域香料市场": "exotic spice market with colorful powder piles",
    "复古扭蛋机与糖果罐": "vintage gacha machine with candy jars",
    # === Tag 11: Art ===
    "莫奈睡莲池与日本桥": "Monet water lily pond with Japanese bridge",
    "梵高星空与向日葵": "Van Gogh starry night and sunflowers",
    "雷诺阿煎饼磨坊舞会": "Renoauir Moulin de la Galette dance",
    "穆夏风格花卉女神": "Mucha style floral goddess",
    "克里姆特金箔装饰画": "Klimt gold leaf decorative painting",
    "荷兰黄金时代静物画": "Dutch Golden Age still life painting",
    "维米尔光影室内": "Vermeer light and shadow interior",
    "达利融化钟表": "Dali melting clocks",
    "马格利特礼帽苹果": "Magritte bowler hat and apple",
    "伦勃朗光影": "Rembrandt dramatic lighting",
    "透纳浪漫主义风景": "Turner romantic landscape",
    "葛饰北斋神奈川冲浪里": "Hokusai Great Wave off Kanagawa",
    "歌川广重江户名所": "Hiroshige Edo famous places",
    "千里江山青绿山水": "Wang Ximeng blue-green landscape",
    "宋代工笔重彩花鸟": "Song dynasty gongbi bird-and-flower painting",
    "敦煌壁画飞天": "Dunhuang mural flying apsaras",
    "中国写意水墨": "Chinese xieyi ink wash painting",
    "油画": "oil painting",
    "水彩画": "watercolor painting",
    "丙烯画": "acrylic painting",
    "粉彩画": "pastel painting",
    "炭笔素描": "charcoal sketch",
    "版画": "printmaking",
    "铜版画": "copperplate engraving",
    "木版画": "woodblock print",
    "蛋彩画": "tempera painting",
    "蒙娜丽莎": "Mona Lisa",
    "最后的晚餐": "The Last Supper",
    "米开朗基罗创世纪": "Michelangelo Sistine Chapel Creation",
    "大碗岛的星期天": "A Sunday on La Grande Jatte",
    "点彩": "pointillism",
    "抽象表现主义": "abstract expressionism",
    "波洛克": "Pollock",
    "波普艺术": "pop art",
    "沃霍尔": "Warhol",
    "表现主义": "expressionism",
    "蒙克": "Munch",
    "立体主义": "cubism",
    "毕加索": "Picasso",
    "埃及壁画与象形文字": "Egyptian murals and hieroglyphs",
    "复古旅行海报风": "vintage travel poster style",
    "堆满颜料管画架调色板的阁楼画室": "cluttered attic studio with paint tubes easel and palette",
    "陶艺工坊转盘": "pottery workshop with wheel",
    "大理石雕塑半身像": "marble sculpture bust",
    "威尼斯吹制玻璃工坊": "Venetian glassblowing workshop",
    "街头涂鸦壁画": "graffiti mural",
    "Graffiti Mural": "graffiti mural",
    "拼布绗缝": "patchwork quilting",
    "Patchwork": "patchwork quilting",
    "明清青花瓷": "Ming-Qing blue and white porcelain",
    "波斯羊毛挂毯": "Persian wool tapestry",
    "土耳其马赛克拼贴灯": "Turkish mosaic lamp",
    # === Tag 12: Fantasy ===
    "西方喷火巨龙": "western fire-breathing dragon",
    "红龙": "red dragon",
    "翡翠绿龙": "emerald green dragon",
    "冰霜巨龙": "frost dragon",
    "东方龙": "eastern dragon",
    "中国龙": "Chinese dragon",
    "独角兽": "unicorn",
    "狮鹫": "griffin",
    "火凤凰": "phoenix",
    "飞马": "pegasus",
    "九尾狐": "nine-tailed fox",
    "美人鱼": "mermaid",
    "塞壬": "siren",
    "海妖": "kraken",
    "克拉肯": "kraken",
    "蝎尾狮": "manticore",
    "奇美拉": "chimera",
    "利维坦": "leviathan",
    "比希摩斯": "behemoth",
    "独眼巨人": "cyclops",
    "米诺陶洛斯": "minotaur",
    "塞伯鲁斯": "cerberus",
    "三头犬": "cerberus",
    "海德拉": "hydra",
    "九头蛇": "hydra",
    "蛇怪": "basilisk",
    "巴西利斯克": "basilisk",
    "巨魔": "troll",
    "食人魔": "ogre",
    "石像鬼": "gargoyle",
    "天使": "angel",
    "堕天使": "fallen angel",
    "恶魔": "demon",
    "白胡子魔法师": "white-bearded wizard",
    "尖顶帽小魔女": "pointed-hat little witch",
    "森林精灵弓箭手": "forest elf archer",
    "矮人战士": "dwarf warrior",
    "骑士": "knight",
    "圣骑士": "paladin",
    "女巫": "witch",
    "哥布林": "goblin",
    "半人马": "centaur",
    "巨人": "giant",
    "龙人": "dragonborn",
    "龙裔": "dragonborn",
    "游侠": "ranger",
    "兽人": "orc",
    "亡灵骷髅": "undead skeleton",
    "巫妖": "lich",
    "花仙子": "flower fairy",
    "森林小树人": "forest entling",
    "独眼小怪兽": "cyclops little monster",
    "浮空岛屿群与藤桥瀑布": "floating islands with vine bridges and waterfalls",
    "发光水晶洞穴": "glowing crystal cave",
    "精灵树屋王国": "elf treehouse kingdom",
    "魔法塔": "magic tower",
    "奇幻城堡": "fantasy castle",
    "龙巢龙穴": "dragon lair",
    "地下城遗迹": "dungeon ruins",
    "传送门": "portal",
    "星空魔法阵": "starlight magic circle",
    "云端黄金天宫": "cloud-top golden palace",
    "魔法图书馆": "magic library",
    "发光魔法阵": "glowing magic circle",
    "藏宝箱": "treasure chest",
    "金币宝石王冠卷轴": "gold coins gems crown and scrolls",
    "石中圣剑": "sword in stone",
    "魔法书咒语书": "magic spellbook",
    "发光魔杖": "glowing magic wand",
    "药水瓶炼金瓶": "potion bottles and alchemy flasks",
    "水晶球": "crystal ball",
    "龙蛋": "dragon egg",
    "符文石": "rune stones",
    "仙山蓬莱": "fairy mountain Penglai",
    "修仙洞府": "cultivation cave dwelling",
    "麒麟": "qilin",
    "貔貅": "pixiu",
    "白泽": "baize mythical beast",
    "仙宫天宫": "celestial palace",
    # === Tag 13: Space ===
    "带光环的土星与冰卫星": "ringed Saturn with ice moons",
    "木星大红斑与气体涡流": "Jupiter Great Red Spot and gas vortices",
    "火星红色地貌与极冠": "Mars red landscape with polar cap",
    "地球": "Earth",
    "月球表面与地出": "lunar surface and Earthrise",
    "双星系统": "binary star system",
    "日珥": "solar prominence",
    "八大行星全家福": "eight planets family portrait",
    "创生之柱": "Pillars of Creation",
    "蝴蝶星云": "Butterfly Nebula",
    "猎户座大星云": "Orion Nebula",
    "蟹状星云": "Crab Nebula",
    "玫瑰星云": "Rosette Nebula",
    "马头星云": "Horsehead Nebula",
    "黑洞吸积盘与引力透镜": "black hole accretion disk with gravitational lensing",
    "螺旋银河系中心": "spiral galaxy core",
    "银河拱桥": "Milky Way arch",
    "仙女座星系": "Andromeda Galaxy",
    "旋涡星系": "spiral galaxy",
    "超新星遗迹": "supernova remnant",
    "流星雨": "meteor shower",
    "彗星": "comet",
    "舱外行走宇航员": "EVA astronaut spacewalk",
    "阿波罗登月舱与月球车": "Apollo lunar module and rover",
    "火星殖民基地穹顶": "Mars colony base dome",
    "火箭发射": "rocket launch",
    "环形旋转空间站": "rotating ring space station",
    "星际探险母舰": "interstellar exploration mothership",
    "韦伯": "Webb telescope",
    "哈勃太空望远镜": "Hubble Space Telescope",
    "卫星": "satellite",
    "双月外星峡谷": "alien canyon with two moons",
    "发光外星地衣晶体矿脉": "glowing alien lichen and crystal veins",
    "外星海洋悬浮岩石": "alien ocean with floating rocks",
    "古董天文望远镜": "antique astronomical telescope",
    "深空射电望远镜阵列": "deep space radio telescope array",
    "UFO飞碟": "UFO flying saucer",
    "外星人": "alien",
    "灰人": "grey alien",
    "小绿人": "little green man",
    "太空站内部走廊": "space station interior corridor",
    "戴森球": "Dyson sphere",
    "小行星带采矿": "asteroid belt mining",
    "空间殖民穹顶": "space colony dome",
    # === Tag 14: Transportation ===
    "1950年代美式敞篷车": "1950s American convertible",
    "福特野马": "Ford Mustang",
    "克尔维特": "Chevrolet Corvette",
    "凯迪拉克": "Cadillac",
    "大众T1露营面包车": "VW T1 camper van",
    "大众甲壳虫": "VW Beetle",
    "Mini Cooper": "Mini Cooper",
    "古董劳斯莱斯": "antique Rolls-Royce",
    "复古跑车": "vintage sports car",
    "F1赛车": "F1 racing car",
    "越野车": "off-road vehicle",
    "路虎": "Land Rover",
    "皮卡": "pickup truck",
    "房车": "RV motorhome",
    "双层巴士": "double-decker bus",
    "出租车": "taxi",
    "警车": "police car",
    "消防车": "fire truck",
    "救护车": "ambulance",
    "跑车": "sports car",
    "兰博基尼": "Lamborghini",
    "法拉利": "Ferrari",
    "农用拖拉机": "farm tractor",
    "东南亚嘟嘟车": "Southeast Asian tuk-tuk",
    "蒸汽机车": "steam locomotive",
    "瑞士齿轨观光火车": "Swiss cogwheel scenic train",
    "冰川快车": "Glacier Express",
    "新干线": "Shinkansen",
    "高铁": "high-speed train",
    "城市有轨电车": "city tram",
    "地铁轻轨": "subway light rail",
    "单轨磁悬浮": "maglev monorail",
    "绿皮火车": "green-skin slow train",
    "1930年代双翼螺旋桨飞机": "1930s biplane propeller aircraft",
    "水上浮筒飞机": "floatplane",
    "卡帕多奇亚热气球群": "Cappadocia hot air balloon group",
    "宽体民航客机": "wide-body airliner",
    "战斗机": "fighter jet",
    "直升机": "helicopter",
    "滑翔机": "glider",
    "飞艇": "airship",
    "摩天轮": "Ferris wheel with night lights",
    "旋转木马": "carousel",
    "缆车": "cable car",
    "索道": "ropeway",
    "山地观光齿轮火车": "mountain cogwheel tourist train",
    "多桅木质大帆船": "multi-masted wooden galleon",
    "豪华远洋邮轮": "luxury ocean liner",
    "威尼斯贡多拉": "Venetian gondola",
    "木皮划艇独木舟": "wooden kayak canoe",
    "游艇": "yacht",
    "渔船": "fishing boat",
    "龙舟": "dragon boat",
    "气垫船": "hovercraft",
    "军舰航母": "naval warship aircraft carrier",
    "海盗船": "pirate ship",
    "Vespa踏板车": "Vespa scooter",
    "哈雷重型机车": "Harley-Davidson motorcycle",
    "英伦复古自行车": "British retro bicycle",
    "山地车": "mountain bike",
    "公路赛车": "road racing bike",
    "滑板长板": "skateboard longboard",
    "独轮车": "unicycle",
    "三轮车人力车": "tricycle rickshaw",
    "平衡车": "balance scooter",
    # === Tag 15: People ===
    "和服少女漫步樱花下": "kimono girl walking under cherry blossoms",
    "印度纱丽舞者": "Indian sari dancer",
    "威尼斯狂欢节盛装贵族": "Venice carnival costumed nobility",
    "苏格兰格子裙风笛手": "Scottish kilt bagpiper",
    "墨西哥亡灵节盛装巡游": "Mexican Day of the Dead costume parade",
    "陶艺师傅转盘造型": "potter shaping clay on wheel",
    "钟表匠组装齿轮": "watchmaker assembling gears",
    "甜点师揉面点缀浆果": "pastry chef kneading dough with berries",
    "画家普罗旺斯花园写生": "painter sketching in Provence garden",
    "园丁维多利亚温室修剪": "gardener pruning in Victorian greenhouse",
    "家庭草坪野餐": "family lawn picnic",
    "青年黑胶唱片店翻找": "youngster browsing vinyl record shop",
    "老人街角咖啡馆下棋": "elderly men playing chess at corner cafe",
    "孩子海滩堆沙堡": "child building sandcastle on beach",
    "欧洲圣诞集市人群": "European Christmas market crowd",
    "东南亚水上市场船娘": "Southeast Asian floating market boat vendor",
    "街头四重奏乐队广场演奏": "street quartet performing in square",
    "黄昏湖畔散步": "lakeside stroll at dusk",
    "窗边阅读时光": "reading by the window",
    "咖啡馆品咖啡": "enjoying coffee at a cafe",
    "街头音乐家演奏": "street musician performing",
    "户外写生画家": "outdoor sketching painter",
    "厨房烹饪场景": "kitchen cooking scene",
    "花园修剪园艺": "garden pruning and gardening",
    "旅行街拍摄影": "travel street photography",
    "湖畔垂钓": "lakeside fishing",
    "钓鱼": "fishing",
    "医生护士": "doctor and nurse",
    "教师": "teacher",
    "厨师": "chef",
    "农民渔夫": "farmer and fisherman",
    "舞者芭蕾": "ballet dancer",
    "音乐家街头艺人": "musician street performer",
    "手艺人匠人": "artisan craftsman",
    "科学家": "scientist",
    "街头人群": "street crowd",
    "市场集市": "market bazaar",
    "节日人群": "festival crowd",
    "火车站": "train station",
    "机场候机厅": "airport departure lounge",
    # === Tag 16: Sports ===
    "足球": "soccer",
    "凌空抽射": "volley shot",
    "扑救": "diving save",
    "篮球": "basketball",
    "战斧劈扣": "tomahawk dunk",
    "网球": "tennis",
    "红土滑步正手": "clay court sliding forehand",
    "高尔夫": "golf",
    "果岭沙坑救球": "bunker save shot",
    "斯诺克台球开球": "snooker break-off shot",
    "棒球": "baseball",
    "排球": "volleyball",
    "橄榄球": "rugby",
    "乒乓球": "table tennis",
    "羽毛球": "badminton",
    "板球": "cricket",
    "曲棍球": "field hockey",
    "冲浪": "surfing",
    "巨浪管涌": "massive barrel wave",
    "帆船赛": "sailing race",
    "滑雪": "skiing",
    "阿尔卑斯深粉雪": "Alpine deep powder snow",
    "花样滑冰旋转": "figure skating spin",
    "冰球争夺": "ice hockey face-off",
    "单板滑雪": "snowboarding",
    "滑冰冰舞": "ice skating ice dance",
    "雪橇": "toboggan",
    "跳台滑雪": "ski jumping",
    "冰壶": "curling",
    "潜水浮潜": "diving and snorkeling",
    "公路自行车": "road cycling",
    "环法发卡弯": "Tour de France hairpin turn",
    "徒手攀岩": "free climbing",
    "红色砂岩峭壁": "red sandstone cliff",
    "高空跳伞": "skydiving",
    "翼装飞行": "wingsuit flying",
    "激流皮划艇": "whitewater kayaking",
    "F1赛车过弯": "F1 car cornering",
    "跑酷": "parkour",
    "滑板": "skateboarding",
    "滑翔伞": "paragliding",
    "徒步登山背包客": "hiking backpacker",
    "马术障碍赛": "equestrian show jumping",
    "海边日出瑜伽剪影": "sunrise yoga silhouette on beach",
    "射箭": "archery",
    "击剑": "fencing",
    "举重": "weightlifting",
    "跑步马拉松": "running marathon",
    "拳击MMA": "boxing and MMA",
    "武术空手道柔道跆拳道泰拳": "martial arts karate judo taekwondo muay thai",
    "体操艺术体操": "gymnastics and rhythmic gymnastics",
    # === Tag 17: Seasons ===
    "樱花盛开与樱花隧道": "cherry blossom tunnel in full bloom",
    "油菜花海": "rapeseed flower sea",
    "新绿嫩芽": "fresh green sprouts",
    "融雪溪流": "snowmelt stream",
    "春雨后茶园水珠": "spring rain dewdrops on tea garden",
    "草地野花": "meadow wildflowers",
    "黄金沙滩遮阳伞椰子树": "golden beach with umbrellas and palm trees",
    "向日葵田与积雨云": "sunflower field with cumulonimbus clouds",
    "冰镇西瓜柠檬汽水": "chilled watermelon and lemon soda",
    "萤火虫稻田": "fireflies over rice paddies",
    "湖畔露营篝火帐篷": "lakeside camping with campfire and tent",
    "薰衣草田": "lavender field",
    "漫山红枫": "mountainside red maple",
    "金黄银杏大道": "golden ginkgo avenue",
    "南瓜堆玉米苹果丰收": "pumpkin pile corn and apple harvest",
    "苹果园": "apple orchard",
    "松鼠捡橡果": "squirrel gathering acorns",
    "落叶小径古木桥": "fallen leaves path with old wooden bridge",
    "秋日葡萄园": "autumn vineyard",
    "秋色森林": "autumn forest",
    "积雪童话木屋炊烟": "snow-covered fairytale cabin with smoking chimney",
    "雾凇针叶林": "rime-ice coniferous forest",
    "雪人围巾胡萝卜鼻": "snowman with scarf and carrot nose",
    "冰封湖面映雪山晚霞": "frozen lake reflecting snowy mountain sunset glow",
    "窗上冰花霜花": "window frost and ice flowers",
    "雪后白桦林": "birch forest after snow",
    "极地冰原冰川": "polar ice field glacier",
    "冰雪覆盖灯塔与风车": "snow-covered lighthouse and windmill",
    # === Tag 18: Holidays ===
    "华丽圣诞树": "gorgeous Christmas tree",
    "彩球松果缎带串灯": "ornaments pinecones ribbons and string lights",
    "壁炉挂袜冬青蜡烛": "fireplace with stockings holly and candles",
    "圣诞老人驯鹿雪橇": "Santa Claus reindeer sleigh",
    "姜饼屋姜饼人": "gingerbread house and gingerbread man",
    "丝带礼物盒堆": "ribbon gift box stack",
    "圣诞彩灯灯串": "Christmas light string",
    "欧洲圣诞集市": "European Christmas market",
    "杰克南瓜灯组": "jack-o-lantern group",
    "万圣糖果盘": "Halloween candy tray",
    "幽灵软糖巧克力眼球蝙蝠棒棒糖": "ghost gummies chocolate eyeballs and bat lollipops",
    "女巫坩埚荧光泡": "witch cauldron with glowing potion",
    "蛛网幽灵骷髅黑猫门前": "cobwebs ghosts skeletons and black cat at door",
    "女巫帽扫帚": "witch hat and broom",
    "大红灯笼中国结": "red lanterns and Chinese knot",
    "舞龙舞狮": "dragon and lion dance",
    "春联福字门神": "spring couplets Fu character and door gods",
    "年夜饭": "New Year's Eve dinner",
    "饺子红烧鱼铜火锅年糕": "dumplings braised fish copper hotpot and rice cakes",
    "除夕烟花": "New Year's Eve fireworks",
    "手绘彩蛋柳条篮": "hand-painted Easter eggs in wicker basket",
    "复活节小兔": "Easter bunny",
    "小鸡玩偶巧克力蛋": "chick toy and chocolate eggs",
    "烤火鸡配迷迭香": "roast turkey with rosemary",
    "丰收羊角": "cornucopia harvest",
    "南瓜玉米葡萄坚果": "pumpkins corn grapes and nuts",
    "南瓜派蔓越莓酱": "pumpkin pie with cranberry sauce",
    "红玫瑰花束": "red rose bouquet",
    "心形巧克力礼盒": "heart-shaped chocolate gift box",
    "烛光晚餐": "candlelight dinner",
    "爱心气球": "heart-shaped balloons",
    "中秋节月饼满月赏月": "Mid-Autumn mooncakes full moon moon gazing",
    "端午节龙舟粽子艾草": "Dragon Boat Festival dragon boat zongzi and mugwort",
    "母亲节康乃馨花束": "Mother's Day carnation bouquet",
    "独立日烟花国旗": "Independence Day fireworks and flag",
    "狂欢节": "Mardi Gras carnival",
    "Mardi Gras": "Mardi Gras carnival",
    "排灯节": "Diwali",
    "Diwali": "Diwali",
    "发光陶灯与花瓣地画": "glowing clay lamps and flower petal rangoli",
    "圣帕特里克节": "St. Patrick's Day",
    "绿色装饰": "green decorations",
    "生日派对": "birthday party",
    "蛋糕蜡烛彩带": "cake candles and ribbons",
    # === Tag 19: Abstract ===
    "丙烯流体浇注画": "acrylic fluid pour painting",
    "宝蓝金箔翠绿紫粉漩涡细胞状网孔": "sapphire blue gold leaf emerald magenta vortex cellular patterns",
    "天然大理石切面": "natural marble cross-section",
    "金色裂纹与墨水晕染": "golden cracks and ink bleeding",
    "高速水滴水面撞击彩色液体王冠": "high-speed water droplet impact colorful liquid crown",
    "万花筒对称图案": "kaleidoscope symmetric pattern",
    "伊斯兰马赛克拼贴花纹": "Islamic mosaic tile pattern",
    "曼陀罗同心圆图腾": "mandala concentric circle totem",
    "曼德博集合与朱利亚集合分形": "Mandelbrot and Julia set fractals",
    "不对称碎裂几何拼贴": "asymmetrical fractured geometric collage",
    "爆炸式碎片飞溅彩色几何": "explosive fragment splash colorful geometry",
    "多层叠加金箔裂纹马赛克": "multi-layer gold leaf crackle mosaic",
    "黄金螺旋": "golden spiral",
    "立体木块金属立方体交错悬浮": "suspended interlocking wood and metal cubes",
    "三棱镜色散光波": "prism dispersion light waves",
    "发光霓虹管立体几何光轨": "glowing neon tube 3D geometric light trails",
    "水磨石碎石玻璃颗粒拼贴": "terrazzo chips glass granule collage",
    "斑驳金箔油画肌理": "mottled gold leaf oil painting texture",
    "教堂彩绘玻璃碎块组合": "stained glass shards composition",
    "树皮木纹": "tree bark wood grain",
    "水波纹": "water ripple pattern",
    "金属锈蚀": "metal rust texture",
    "布料编织": "fabric weave",
    "石板裂纹": "stone slate cracks",
    "混凝土": "concrete texture",
    "墨水扩散水墨晕染酒精墨水": "ink diffusion wash and alcohol ink",
    "颜料泼洒泼墨": "paint splatter and ink splash",
    "蜡染": "batik",
    "渐变色块彩虹渐变": "gradient color blocks rainbow gradient",
    "丁达尔光效": "Tyndall light effect",
    "霓虹蒸汽波": "neon vaporwave",
    "极光色带": "aurora color bands",
    "全息镭射": "holographic laser",
    "数字艺术抽象": "digital art abstract",
    "液态金属扭曲反光抽象": "liquid metal twisted reflection abstract",
    "粒子星尘抽象": "particle stardust abstract",
    "low poly 几何": "low poly geometric",
    "全息彩虹棱镜光栅抽象": "holographic rainbow prism grating abstract",
    "发光线框 3D 渲染": "glowing wireframe 3D render",
    "故障艺术": "glitch art",
    "glitch art": "glitch art",
    "神秘符号装饰曼陀罗": "mystical symbol decorative mandala",
    "炼金术符号法阵": "alchemy symbol magic circle",
    "发光月相球体群": "glowing lunar phase sphere group",
    "复古黄铜浑仪": "vintage brass armillary sphere",
    # === Tag 20: Cartoon ===
    "戴红围巾贝雷帽森林写生的小狐狸": "little fox wearing red scarf and beret painting in forest",
    "系围裙烤草莓蛋糕的熊妈妈小熊": "mother bear in apron baking strawberry cake",
    "打小黄伞雨中踩水坑的小猫小狗": "kitten and puppy with yellow umbrella splashing in puddles",
    "兔子家族蘑菇草地下午茶": "rabbit family mushroom meadow tea party",
    "红白毒蝇伞上微型精灵小镇": "miniature fairy town on fly agaric mushroom",
    "糖果王国": "candy kingdom",
    "甜甜圈棉花糖冰淇淋巧克力瀑布": "donuts marshmallows ice cream and chocolate waterfall",
    "蒸汽朋克飞艇天空城": "steampunk airship sky city",
    "老橡树树洞微缩仓鼠公寓": "miniature hamster apartment in old oak tree hole",
    "蘑菇屋": "mushroom house",
    "彩虹桥场景": "rainbow bridge scene",
    "深夜小居酒屋拉面馆": "late night izakaya ramen shop",
    "阳光阁楼画室": "sunny attic studio with books plants cat and easel",
    "女孩倚靠毛茸茸巨兽看星空": "girl leaning against fluffy giant beast stargazing",
    "新海诚风电车铁道口樱花瓣蓝天积雨云": "Shinkai-style windmill railway crossing cherry petals blue sky cumulus",
    "夏日祭典街头": "summer festival street with yukata goldfish scooping candy apples and fireworks",
    "浴衣少年少女捞金鱼苹果糖烟花": "yukata boys and girls scooping goldfish candy apples and fireworks",
    "魔法学院通天图书馆": "magic academy towering library",
    "吉卜力风格风景": "Studio Ghibli style landscape",
    "Pixar": "Pixar style",
    "Disney 3D风": "Disney 3D style",
    "浓彩厚涂绘本插画风格": "richly colored thick-paint storybook illustration style",
    "水彩卡通风": "watercolor cartoon style",
    "精细浓彩手绘动画风格": "detailed richly colored hand-drawn animation style",
    "赛博朋克卡通风": "cyberpunk cartoon style",
    "复古浓彩动画角色群像": "retro richly colored animation character ensemble",
    "繁复装饰花卉绘本风格": "intricately decorated floral storybook style",
    "满涂彩色绘本插画风格": "fully colored storybook illustration style",
    "满构图卡通角色大集合场景": "full-frame cartoon character ensemble scene",
    "童话故事插图绘本风": "fairy tale illustration picture book style",
    "儿童故事场景": "children story scene",
    "可爱角色合集动物朋友": "cute character collection animal friends",
    "卡通节日主题": "cartoon holiday theme",
    "卡通职业角色": "cartoon occupation characters",
    "涂鸦 doodle": "doodle art",
    "doodle": "doodle art",
    "拟人化动物角色": "anthropomorphic animal characters",
    "猫狗熊兔": "cat dog bear rabbit",
    "Q版人物 Chibi": "chibi characters",
    "Chibi": "chibi characters",
    "拟人化食物水果蔬菜": "anthropomorphic food fruits and vegetables",
    "卡通怪兽萌系怪物": "cartoon monster cute creatures",
    "卡通机器人": "cartoon robot",
    "卡通恐龙": "cartoon dinosaur",
    "拟人化交通工具": "anthropomorphic vehicles",
    "工程车": "construction vehicles",
    "拟人化工程车": "anthropomorphic construction vehicles",
    "卡通城市": "cartoon city",
    "卡通森林童话森林": "cartoon fairytale forest",
    "卡通城堡": "cartoon castle",
    "卡通海底世界": "cartoon underwater world",
    "卡通太空冒险": "cartoon space adventure",
    "卡通农场": "cartoon farm",
    "卡通海盗船": "cartoon pirate ship",
    "挤满成百上千小人物的疯狂海滩": "crowded beach with hundreds of tiny characters",
    "混乱体育馆": "chaotic stadium",
    "迷宫超级工厂": "maze mega factory",
    "高密度幽默小人物、隐藏彩蛋与搞怪小动作": "high-density humorous characters with hidden easter eggs and silly antics",
    # === Tag 21: Others ===
    "老式机械打字机": "vintage mechanical typewriter",
    "黑胶留声机与唱片封套": "vinyl gramophone with record sleeves",
    "拆解黄铜怀表": "disassembled brass pocket watch",
    "精密齿轮游丝发条": "precision gears mainspring and balance wheel",
    "双反胶片相机": "twin-lens reflex film camera",
    "老式皮腔折叠相机与胶卷": "vintage bellows folding camera with film rolls",
    "古董钟表座钟": "antique grandfather clock",
    "大提琴小提琴与木质乐谱架": "cello violin with wooden music stand",
    "三角钢琴黑白琴键与五线谱": "grand piano with black and white keys and sheet music",
    "萨克斯风": "saxophone",
    "复古原木吉他": "vintage acoustic guitar",
    "编织篮毛线球棒针": "woven basket yarn balls and knitting needles",
    "复古手摇缝纫机与线轴架": "vintage hand-crank sewing machine with thread spool rack",
    "铜顶针碎花布料": "brass thimble and floral fabric",
    "彩绘玻璃制作台": "stained glass crafting table",
    "彩色玻璃碎块焊枪铅条": "colored glass shards with soldering iron and lead strips",
    "德国胡桃夹子士兵玩偶": "German nutcracker soldier doll",
    "维多利亚微缩娃娃屋": "Victorian miniature dollhouse",
    "乐高中世纪城堡与人偶": "LEGO medieval castle with minifigures",
    "铁皮发条机器人与发条小火车": "tin wind-up robot and clockwork train",
    "泰迪熊堆": "teddy bear pile",
    "泛黄手绘羊皮纸航海地图": "aged hand-drawn parchment nautical map",
    "黄铜罗盘指南针": "brass compass",
    "复古单筒望远镜": "vintage monocular telescope",
    "羽毛笔墨水瓶": "quill pen and inkwell",
    "火漆印章封蜡": "wax seal stamp and sealing wax",
    "地球仪": "globe",
    "古董地球仪与天文仪": "antique globe and astronomical instrument",
    "复古黄铜六分仪": "vintage brass sextant",
    "宝石矿物原石陈列": "gemstone mineral raw specimen display",
    "化石恐龙骨架考古": "fossil dinosaur skeleton archaeology",
    "显微镜下微观世界": "microscopic world under microscope",
    "邮票钱币古币收藏": "stamp coin and antique currency collection",
    "旧书古籍书架截面": "old books and ancient texts shelf cross-section",
    "棋盘国际象棋围棋盘": "chess board international chess and go board",
    "魔术师道具水晶球与魔杖": "magician props crystal ball and wand",
    "天文望远镜观测台": "astronomical telescope observatory",
    "蒸汽朋克齿轮组": "steampunk gear assembly",
    "玻璃弹珠": "glass marbles",
    "彩色纽扣": "colorful buttons",
    "复古糖果包装纸大集合": "vintage candy wrapper collection",
    "老式麦片盒拼贴": "vintage cereal box collage",
    "复古汽水瓶盖": "vintage soda bottle caps",
    "啤酒盖平铺": "beer cap flat lay",
    "复古旅行徽章和纪念章收藏": "vintage travel badge and medallion collection",
    "复古电影院门厅": "vintage cinema lobby",
    "旅行车票票根拼贴": "travel ticket stub collage",
    "火柴盒大集合": "matchbox collection",
    "塞满魔法古籍的书架正视图": "bookshelf front view packed with magical tomes",
    "书本间隐藏微缩遗迹房屋": "miniature ruin houses hidden between books",
    "魔法药水瓶": "magic potion bottles",
    "发光微型水晶": "glowing miniature crystals",
    "偷看的小怪兽": "peeking little monster",
    # === Environment partner phrases (补充) ===
    "斑驳阳光竹林": "dappled sunlight bamboo forest",
    "金合欢稀树草原": "acacia savanna",
    "苔藓倒木": "mossy fallen logs",
    "积雪碎石悬崖": "snow-dusted scree cliff",
    "热带雨林藤蔓": "tropical rainforest vines",
    "史前蕨类植物丛": "prehistoric fern grove",
    "冒烟活火山": "smoking active volcano",
    "热带沼泽泥潭": "tropical swamp",
    # Pets env — replaced 2026-09-01. Table-top props (yarn balls, cat bed,
    # chew toys, cushion, fireplace floor) were too small to fill a 1:1 frame
    # and were being pushed into the "{env_bg} in the distance" slot.
    # Now spatial-scale rooms/yards that can carry fg + mid + bg.
    "摆满靠垫与书架的温馨客厅": "cozy living room with patterned cushions and bookshelves",
    "开满花卉的庭院小径与石阶": "flowering cottage garden with stone path and borders",
    "堆满毛巾与护理用品的宠物美容店": "pet grooming salon with shelves of towels and bottles",
    "干草堆与工具的乡村谷仓": "rustic barn interior with hay bales and hanging tools",
    "有敏捷障碍与其他狗的宠物公园": "bustling dog park with agility ramps and other dogs",
    "瓷砖地面与敞开橱柜的温暖厨房": "warm kitchen with tiled floor and open cupboards",
    "藤编家具与棕榈盆栽的阳光房": "sunlit conservatory with wicker furniture and potted palms",
    "摆满盆栽与编织篮的木质门廊": "wooden porch with potted plants and woven baskets",
    "成排毯子与玩具的动物收容所": "animal shelter with rows of blankets and toys",
    "林间丁达尔光束": "forest Tyndall light beams",
    "溪流飞溅水珠": "stream splashing water droplets",
    "深色朽木与鲜亮苔藓明暗对比": "dark dead wood with bright moss contrast",
    "前景野花花丛": "foreground wildflower cluster",
    "风化岩石缝": "weathered rock crevices",
    "木质围栏": "wooden fence",
    "倒影水洼": "reflection puddle",
    "枯木倒影": "fallen log reflection in water",
    "花瓣露珠": "petal dewdrops",
    "花粉颗粒": "pollen particles",
    "复古剪刀麻绳": "vintage scissors and jute twine",
    "园艺笔记": "gardening notebook",
    "阳光玻璃花房": "sunlit glass greenhouse",
    "水下焦散光斑": "underwater caustic light patterns",
    "气泡流": "bubble streams",
    "阳光射入深海光柱": "sunlight beams into deep ocean",
    "珊瑚间隙海葵海星": "coral gap anemones and starfish",
    "红浆果落雪树枝": "red berries on snow-dusted branch",
    "樱花木棉树梢": "cherry blossom kapok treetop",
    "地衣古栎树干": "lichen-covered old oak trunk",
    "晨雾芦苇湿地": "morning mist reed marsh",
    "雨夜湿地面霓虹倒影": "rainy night wet pavement neon reflections",
    "沿街花箱": "street flower boxes",
    "暖光橱窗": "warm-lit shop windows",
    "黄色出租车": "yellow taxi",
    "前景花坛喷泉": "foreground flower beds and fountains",
    "石栏杆藤蔓": "stone railing with vines",
    "水面倒影": "water surface reflection",
    "风化石砖与浮雕雕花": "weathered brick with carved reliefs",
    "斑驳实木餐桌": "mottled wooden dining table",
    "复古银质刀叉": "vintage silver cutlery",
    "铸铁锅": "cast iron pot",
    "复古陶瓷碗": "vintage ceramic bowl",
    "麻布餐巾": "linen napkin",
    "画布麻布纹": "canvas burlap texture",
    "龟裂油画裂纹": "cracked oil painting craquelure",
    "金箔反光": "gold leaf reflection",
    "调色刀堆砌厚度": "palette knife impasto thickness",
    "漂浮发光光斑粒子": "floating glowing speck particles",
    "发光蘑菇丛": "glowing mushroom cluster",
    "符文雕刻石柱": "rune-carved stone pillar",
    "星空与紫粉极光交织": "starry sky with purple-pink aurora interweaving",
    "密集小行星碎石带": "dense asteroid debris belt",
    "飞船表面机械刻线": "spaceship surface mechanical panel lines",
    "星光折射星芒": "starlight refraction flare",
    "镜头光晕": "lens flare",
    "沿海悬崖公路": "coastal cliff highway",
    "秋日山间公路": "autumn mountain road",
    "沥青路面落叶": "asphalt road with fallen leaves",
    "老式红砖加油站": "vintage red brick gas station",
    "港口码头": "harbor dock",
    "高速定格水花碎冰红土粉尘": "frozen water spray ice shards red clay dust",
    "阳光透过水雾微彩虹": "sunlight through water mist micro rainbow",
    "体育场观众席密集灯光与彩色旗帜": "stadium spectator stands with dense lights and colorful flags",
    # Round 5 (2026-09-02): Sports rainbow fix — the two water/mist env entries
    # above rendered a literal rainbow in 168/168 Sports images
    # (JigsawV5_full). Sports now uses these clean spatial venues instead.
    "室内球馆抛光木地板与顶层看台": "indoor arena with polished hardwood floor and upper tier stands",
    "红色塑胶跑道白色分道线": "red rubber running track with white lane lines",
    "自行车馆木质倾斜赛道": "velodrome with steep wooden banked track",
    "攀岩墙彩色岩点": "climbing wall with colorful holds",
    # Round 6 (2026-09-02): Sports subject redesign — bare sport nouns
    # ("soccer", "tennis") read as broken grammar in the special templates
    # ("a single soccer"); replaced with 40 single-subject equipment/action
    # close-ups compatible with "a single {subject}" phrasing.
    "足球贴网入球瞬间": "soccer ball hitting the back of the goal net",
    "篮球与抛光木地板": "basketball on glossy hardwood court",
    "网球拍与红土场": "tennis racket and ball on red clay court",
    "羽毛球过网瞬间": "white badminton shuttlecock mid-flight over the net",
    "乒乓球拍与蓝色球台": "table tennis paddle and ball over blue table",
    "高尔夫球座与沙坑": "golf ball on tee beside a sand bunker",
    "棒球手套与内场红土": "baseball glove and ball on infield dirt",
    "排球与沙地球场": "volleyball at the net over sandy court",
    "橄榄球与球门柱草坪": "rugby ball on grass with goal posts",
    "斯诺克球台开球布局": "snooker table with racked balls and cue",
    "冰球杆与冰球": "ice hockey stick and puck on glossy ice",
    "曲棍球杆与草地球": "field hockey stick and ball on turf",
    "双板滑雪切粉雪": "alpine ski carving through fresh powder",
    "单板滑雪刻滑雪道": "snowboard carving a groomed mountain slope",
    "冰壶滑行": "granite curling stone sliding on pebbled ice",
    "有舵雪橇冰道": "bobsled speeding down an icy track",
    "浆板平湖": "paddleboard on calm turquoise water",
    "冲浪管浪": "surfboard inside a translucent barrel wave",
    "白水皮划艇": "whitewater kayak cutting through rapids",
    "帆船紧绷帆": "sailboat heeling with taut white sails",
    "跳台跳水": "diving platform over crystal pool water",
    "浮潜面镜脚蹼": "snorkel mask and fins on a boat deck",
    "山地车砾石林道": "mountain bike on a gravel forest trail",
    "攀岩墙岩点镁粉": "colorful climbing holds with chalk dust",
    "滑板坡道腾空": "skateboard mid-air over a concrete ramp",
    "公路车发卡弯": "road bike leaning through a hairpin turn",
    "滑翔伞山谷": "paraglider wing over an alpine valley",
    "跳伞伞衣": "colorful parachute canopy opening in the sky",
    "射箭靶心": "archery target bristling with arrows",
    "击剑剑与面罩": "fencing foil and mask on the piste",
    "举重杠铃片": "barbell loaded with colorful weight plates",
    "拳击手靶": "boxing glove striking the focus mitt",
    "跑道钉鞋": "track spike shoe on a red running lane",
    "马术鞍具": "equestrian saddle and bridle at the paddock fence",
    "艺术体操彩带": "rhythmic gymnastics ribbon curling mid-air",
    "钓鱼竿轮": "fishing rod and reel at a lakeside pier",
    "清晨海边瑜伽垫": "yoga mat on a beach deck at sunrise",
    "金牌与绶带": "gold medal hanging on a ribbon",
    # Round 8 (2026-09-02): Sports env affinity — JigsawV5_sports showed every
    # non-ball subject mismatched (ski + running track, paddleboard + indoor
    # arena, snorkel + velodrome) because the tag pool had no snow/water
    # venues. 11 new venue keywords expand the pool; the four affinity groups
    # below route each subject to a plausible venue family.
    "阳光草坪球场白色边线": "sunny grass pitch with white boundary lines",
    "室内网球馆绿蓝场地": "indoor tennis hall with green and blue courts",
    "城市滑板场水泥坡道涂鸦墙": "urban skate park with concrete ramps and graffiti walls",
    "蜿蜒山路护栏": "winding mountain road with guardrails",
    "阳光滑雪场压雪道": "sunlit ski resort with groomed slopes",
    "雪岸环抱冰封湖面": "frozen lake rink ringed by snow banks",
    "高山雪松雪村": "alpine village with frosted pine trees",
    "碧绿浅滩沙嘴": "calm turquoise lagoon with sandy shallows",
    "泡沫激流河谷": "whitewater river with foaming rapids",
    "游艇码头缆绳": "marina docks with rigging and ropes",
    "湛蓝泳池泳道线": "swimming pool with crystal blue lane ropes",
    # Round 9 (2026-09-02): Sports outdoor expansion — 14 non-stadium subjects
    # (mountain/forest/river/sea/desert) + 8 matching venues. Candidates
    # dropped by cross-tag dedup: dragon boat (Holidays owns it), longboard
    # (Transportation owns "skateboard longboard").
    "林间越野雪道": "groomed forest ski trail between snow-laden pines",
    "蓝色冰瀑": "tall frozen blue ice waterfall",
    "冰川裂缝坡": "glacier slope with deep blue crevasses",
    "白浪风湾": "windy bay with whitecap waves",
    "金秋静水河道": "mirror-calm river lined with autumn trees",
    "泥泞林道": "muddy forest trail with roots and puddles",
    "多雾山脊步道": "misty mountain ridge trail",
    "金色沙丘拉力赛道": "golden dune sea rally track",
    "越野滑雪森林雪道": "cross-country skis on a snowy forest trail",
    "攀冰冰瀑冰镐": "ice climbing tools on a frozen blue waterfall",
    "冰钓冰洞钓竿": "ice fishing rod at a drilled hole on a frozen lake",
    "雪地摩托深粉雪": "snowmobile carving through deep powder",
    "登山冰镐冰爪冰川": "ice axe and crampons gripping a glacier slope",
    "风筝冲浪浪湾": "kite surfing kite curving above breaking waves",
    "帆板顺风滑行": "windsurf board planing across a windy bay",
    "赛艇双桨静水": "racing shell with oars on a mirror-calm river",
    "尾波滑水玻璃浪": "wakeboard carving a glassy wake",
    "越野跑泥泞林道": "trail running shoe on a muddy forest path",
    "徒步山脊登山杖": "hiking backpack and trekking poles on a mountain ridge",
    "定向越野检查点旗": "bright orienteering flag marking a forest checkpoint",
    "飞盘高尔夫铁链篮": "disc golf chain basket among shady trees",
    "沙漠越野摩托沙丘": "dirt bike launching off a desert dune",
    # Round 10 (2026-09-02): court split — 6 homogeneous sub-groups replacing
    # the old single "court" pool.  Each sub-group has 3 visually-compatible
    # variants of the SAME venue type so rng.sample(pool, 3) no longer mixes
    # incompatible surfaces (grass + tennis + hardwood) in one image.
    # grass_field
    "阳光草坪白线角旗": "sunny grass pitch with white boundary lines and corner flags",
    "泛光灯草地球场清晰标线": "floodlit stadium grass field with crisp line markings",
    "晨露草坪球场柔和阴天": "dewy morning grass pitch under soft overcast sky",
    # hardwood_arena
    "明亮体育馆枫木地板阶梯看台": "bright gymnasium with glossy maple hardwood and tiered bleachers",
    "宽敞运动馆木地板顶部聚光灯": "spacious sports hall with wooden floor and overhead spotlights",
    # indoor_court
    "室内运动馆标线球场网柱": "indoor sports hall with painted court lines and net posts",
    "明亮室内球场馆顶部照明": "bright indoor court complex with overhead lighting",
    "洁净室内场地地面标线分区": "clean indoor venue with marked floor lines and court partitions",
    # outdoor_field
    "开阔草地球场蓝天": "open grassy field under wide blue sky",
    "阳光户外运动场远处树线": "sunlit outdoor sports ground with distant tree line",
    "阴天户外球场柔和漫射光": "overcast outdoor field with soft diffused light",
    # gym_studio
    "训练健身房器械架镜面墙": "training gym with weight racks and mirrored walls",
    "室内健身工作室器材明亮灯光": "indoor fitness studio with equipment and bright lighting",
    "洁净训练室软垫地面顶部灯光": "clean training room with padded mats and overhead lights",
    # beach_court
    "沙滩球场网柱海风": "sandy beach court with net posts and ocean breeze",
    "阳光沙滩排球场细沙": "sunlit beach volleyball court with soft sand",
    "海风海滨沙地球场晴空": "breezy seaside sand court under clear sky",
    "季节性花海前景层": "seasonal flower sea foreground layer",
    "时令树木色彩渐变中景": "seasonal tree color gradient midground",
    "满构图季节性地表纹理远景": "full-frame seasonal ground texture background",
    "冬日冷暖交织": "cool-warm interplay winter light",
    "闪烁暖光串灯": "twinkling warm string lights",
    "烛光摇曳": "flickering candlelight",
    "彩带金粉微粒": "ribbon and gold dust particles",
    "高反差边缘线": "high contrast edge lines",
    "金箔勾边": "gold leaf outlines",
    "层叠金箔碎片拼贴前景": "layered gold leaf fragment collage foreground",
    "高饱和色相环覆盖": "high saturation color wheel overlay",
    "水彩晕染边缘": "watercolor bleeding edges",
    "彩色铅笔颗粒排线": "colored pencil hatching strokes",
    "手绘杂色点缀": "hand-drawn speckled accents",
    "丰富生活小物件": "abundant small life objects",
    "斑驳实木工作台面": "weathered solid wood workbench surface",
    "黄铜台灯暖光环境": "brass desk lamp warm light environment",
    "皮革与粗麻布铺底纹理": "leather and burlap base texture",
    "细密服饰布料纹理": "detailed fabric weave texture",
    "针织": "knitting",
    "蕾丝": "lace",
    "刺绣": "embroidery",
    "手工艺台面工具散落": "scattered tools on craft workbench",
    "热闹街景建筑背景": "bustling street scene with architecture",
    "夜景灯火": "night scene lights",
    "橱窗": "shop windows",
    "车流填满画面": "traffic filling the frame",
    "雕花石构": "carved stone structure",
    "复杂穹顶与木质结构": "complex domes and wooden structures",
    "密集星团": "dense star clusters",
    "行星光环": "planetary rings",
    "飞船高光填满全画幅": "spaceship highlights filling the frame",
    "加油站": "gas station",
    "火车站台": "train platform",
    "码头": "pier dock",
    "画布颗粒": "canvas grain",
    "裂纹肌理或手工艺实物感": "crack texture or craft tactile feel",
    "生物荧光": "bioluminescence",
    "发光水晶照亮暗部": "glowing crystals illuminating shadows",
    "精细线稿": "fine line art",
    "丰富场景细节": "abundant scene details",
    "手工艺台面或微缩世界": "craft workbench or miniature world",
    "玩具": "toys",
    "家具": "furniture",
    "庭院": "courtyard",
    "果实": "fruits",
    "花枝": "flowering branch",
    "水面互动与羽毛丝状细节": "water interaction and feather filament detail",
    "传统服饰或热闹群像": "traditional costume or bustling crowd",
    "故事感的生活场景": "story-filled life scene",
    "泥土": "dirt",
    "雪尘": "snow dust",
    "插花静物或密集花海": "floral still life or dense flower sea",
    "丰盛盛宴": "lavish feast",
    "下午茶多层塔或高密度食材平铺": "afternoon tea tier or dense ingredient flat lay",
    "油画厚涂堆叠": "thick oil paint impasto",
    "复杂纹理裂纹": "complex texture cracks",
    "丰富配色": "rich color palette",
    "完全扁平无笔触矢量图": "flat vector art without brushstrokes",
    "手绘水彩纹理": "hand-drawn watercolor texture",
    "单调工业零件": "plain industrial parts",
    "高密度复古物件集合": "high-density vintage object collection",
    "大面积平涂单色或简单双色渐变": "large flat monochrome or simple two-color gradient",
    "高频几何碎块": "high-frequency geometric fragments",
    "大片死黑背景": "large dead black background",
    "五彩星云": "colorful nebula",
    "大面积单调黑夜": "large monotonous night",
    "大面积单调柏油路或空旷广场": "large monotonous asphalt or empty plaza",
    "单人大头肖像": "single head portrait",
    "单一运动员孤立在纯绿草皮或纯白冰面": "single athlete isolated on pure green turf or white ice",
    "动态张力与环境粒子": "dynamic tension with environmental particles",
    "单一盘子孤立在白桌布上": "single plate isolated on white tablecloth",
    "单朵花孤立在虚化单色背景": "single flower isolated on blurred monochrome background",
    "单只鸟飞在纯蓝天": "single bird flying in pure blue sky",
    "单只宠物呆立在无纹理地板或纯白墙前": "single pet standing on textureless floor or white wall",
    "单一现代玻璃幕墙": "single modern glass curtain wall",
    "单辆车停在空旷平地": "single car parked on empty ground",
    "大面积单一色块树冠或空旷平原": "large single-color tree canopy or empty plain",
    "单调色块": "monotonous color blocks",
    "大面积深蓝死黑无细节海水": "large deep blue dead water without detail",
    "大面积平涂单色": "large flat monochrome",
    "简单双色渐变": "simple two-color gradient",
    "大面积死黑": "large dead black area",
    "纯色死区": "solid color dead zone",
    "大半张画布纯蓝天或空荡水面": "half canvas pure blue sky or empty water",
    "现代扁平矢量图": "modern flat vector art",
    "整块纯色灾难": "solid color block disaster",
    "单调工业零件": "plain industrial parts",
    # === Compound subject keywords (补充) ===
    "复古手摇缝纫机与线轴架铜顶针碎花布料": "vintage hand-crank sewing machine with thread spool rack brass thimble and floral fabric",
    "塞满魔法古籍的书架正视图，书本间隐藏微缩遗迹房屋": "bookshelf front view packed with magical tomes with miniature ruin houses hidden between books",
    "高空跳伞翼装飞行": "skydiving and wingsuit flying",
    "迷宫超级工厂": "maze mega factory",
    "高密度幽默小人物、隐藏彩蛋与搞怪小动作": "high-density humorous characters with hidden easter eggs and silly antics",
    "狂欢节 Mardi Gras": "Mardi Gras carnival",
    "排灯节 Diwali": "Diwali festival of lights",
    "故障艺术 glitch art": "glitch art",
    "low poly 几何": "low poly geometric",
    "涂鸦 doodle": "doodle art",
    "Q版人物 Chibi": "chibi characters",
    "Pixar": "Pixar 3D style",
    "月球表面与地出 Earthrise": "lunar surface with Earthrise",
}


def clean_keyword(kw: str) -> str:
    """Remove parentheticals, take first part of slash, strip whitespace."""
    kw = re.sub(r"（.*?）", "", kw)
    kw = re.sub(r"\(.*?\)", "", kw)
    if "/" in kw:
        kw = kw.split("/")[0]
    kw = kw.strip()
    return kw


def translate(kw: str, warnings: list) -> str:
    """Translate a Chinese keyword to English. Log warnings for misses."""
    cleaned = clean_keyword(kw)
    if cleaned in CN_TO_EN:
        return CN_TO_EN[cleaned]
    if kw in CN_TO_EN:
        return CN_TO_EN[kw]
    # already English or mixed
    if re.match(r"^[a-zA-Z0-9\s\-]+$", cleaned):
        return cleaned
    # fallback: keep Chinese
    warnings.append(f"  MISS: '{kw}' -> '{cleaned}'")
    return cleaned


def split_respecting_parens(s: str) -> list:
    """Split by 、 but not inside （）or ()."""
    parts = []
    depth = 0
    current = []
    for ch in s:
        if ch in "（(":
            depth += 1
            current.append(ch)
        elif ch in "）)":
            depth = max(0, depth - 1)
            current.append(ch)
        elif ch == "、" and depth == 0:
            part = "".join(current).strip()
            if part:
                parts.append(part)
            current = []
        else:
            current.append(ch)
    part = "".join(current).strip()
    if part:
        parts.append(part)
    return parts


# Labels that are NOT subject element lines
SKIP_LABELS = {"适玩", "核心规避", "Prompt", "prompt"}


def parse_catalog(md_path: str):
    """Parse catalog markdown, return {tag_id: {subjects: [...], env: [...]}}."""
    with open(md_path, encoding="utf-8") as f:
        lines = f.readlines()

    result = {}
    current_tag = None

    for line in lines:
        line = line.rstrip("\n")

        # Tag header: ### Tag 01: Animals（野生动物）
        m = re.match(r"### Tag \d+: (\w+)", line)
        if m:
            current_tag = m.group(1)
            result[current_tag] = {"subjects": [], "env": []}
            continue

        if current_tag is None:
            continue

        # Skip non-subject lines: 适玩, 核心规避, Prompt
        # These start with "- **适玩**" etc.
        if line.startswith("- **"):
            label_m = re.match(r"- \*\*(.+?)\*\*", line)
            if label_m and label_m.group(1) in SKIP_LABELS:
                continue
            # Subject element line: - **子类名**：keyword1、keyword2
            if "：" in line:
                colon_idx = line.index("：")
                items_str = line[colon_idx + 1 :]
                keywords = split_respecting_parens(items_str)
                result[current_tag]["subjects"].extend(keywords)
                continue

        # Environment partner line: **环境搭档**：...
        # Split by 、 and ， (env lines may use commas to separate distinct phrases)
        if line.startswith("**环境搭档**") or line.startswith("**环境搭档："):
            colon_idx = line.index("：") if "：" in line else line.index(":")
            items_str = line[colon_idx + 1 :].rstrip("。").strip()
            # Also split by Chinese comma for multi-phrase env partners
            items_str = items_str.replace("，", "、")
            keywords = split_respecting_parens(items_str)
            result[current_tag]["env"] = keywords
            continue

    return result


def main():
    # 1. Load v4 JSON for shared infrastructure only
    with open(V4_JSON, encoding="utf-8") as f:
        v4_lib = json.load(f)

    # 2. Parse catalog markdown
    catalog = parse_catalog(CATALOG_MD)

    # 3. Build v5 library — pure catalog, no premium pool
    all_warnings = []

    # Copy shared infrastructure (not per-tag premium fields)
    lib = {
        "version": "5.0",
        "_comment": (
            "v5.0 pure catalog-driven library. No premium pool (subjects/extra/"
            "visual_anchors removed). Each tag has catalog_subjects + "
            "catalog_env_partners + template_group. Default image count = "
            "len(catalog_subjects) x --cards-per-subject."
        ),
        "model_hint": MODEL_HINT_FIX or v4_lib.get("model_hint", "unknown"),
        "critical_note": v4_lib.get("critical_note", ""),
        "generation": v4_lib.get("generation", {}),
        "ratios": v4_lib.get("ratios", {}),
        "quality_prefix": QUALITY_PREFIX,
        "quality_tail": QUALITY_TAIL,
        "modifiers": v4_lib.get("modifiers", {}),
        "style_pools": v4_lib.get("style_pools", {}),
        "active_ratios": v4_lib.get("active_ratios", []),
        "prompt_templates": PROMPT_TEMPLATES,
        "tags": [],
    }

    # 3a. Apply post-copy fixes to lighting and style_pools
    lighting = lib.get("modifiers", {}).get("lighting", [])
    if lighting:
        lib["modifiers"]["lighting"] = [
            LIGHTING_FIXES.get(item, item) for item in lighting
        ]
    for pool_name, pool_items in lib.get("style_pools", {}).items():
        if isinstance(pool_items, list):
            lib["style_pools"][pool_name] = [
                STYLE_POOL_FIXES.get(item, item) for item in pool_items
            ]

    # 3b. Apply P0 drops/boosts (see MODIFIER_DROPS comment for the evidence
    # and for the words that were deliberately left alone).
    for pool_name, drops in MODIFIER_DROPS.items():
        items = lib.get("modifiers", {}).get(pool_name)
        if isinstance(items, list):
            lib["modifiers"][pool_name] = apply_pool_ops(
                items, drops, MODIFIER_BOOSTS.get(pool_name, {})
            )
    for pool_name, pool_items in lib.get("style_pools", {}).items():
        if isinstance(pool_items, list) and (
            pool_name in STYLE_DROPS or pool_name in STYLE_BOOSTS
        ):
            lib["style_pools"][pool_name] = apply_pool_ops(
                pool_items,
                STYLE_DROPS.get(pool_name, []),
                STYLE_BOOSTS.get(pool_name, {}),
            )

    # Per-tag: keep infrastructure fields, strip premium-pool fields,
    # inject catalog data.
    STRIP_FIELDS = {"subjects", "extra", "visual_anchors", "tier", "quota"}

    for v4_tag in v4_lib.get("tags", []):
        tag_id = v4_tag["id"]
        if tag_id not in catalog:
            print(f"WARNING: tag {tag_id} not found in catalog")
            continue

        # Start from v4 tag, strip premium-pool fields
        tag = {k: v for k, v in v4_tag.items() if k not in STRIP_FIELDS}

        # Translate subject keywords
        cat_subjects = []
        for kw in catalog[tag_id]["subjects"]:
            en = translate(kw, all_warnings)
            if en and en not in cat_subjects:
                cat_subjects.append(en)
        # v5.1 hygiene pass: rewrites -> blocklist -> per-tag removes ->
        # market-data extras -> dedupe. Mirrors the hand-edited JSON.
        cat_subjects = [SUBJECT_REWRITES.get(s, s) for s in cat_subjects]
        cat_subjects = [SUBJECT_REWRITES_R3.get(s, s) for s in cat_subjects]
        removes = set(TAG_SUBJECT_REMOVES.get(tag_id, []))
        cat_subjects = [
            s for s in cat_subjects if s not in SUBJECT_BLOCKLIST and s not in removes
        ]
        cat_subjects.extend(EXTRA_SUBJECTS.get(tag_id, []))
        seen = set()
        cat_subjects = [s for s in cat_subjects if not (s in seen or seen.add(s))]
        tag["catalog_subjects"] = cat_subjects

        # Translate environment partners
        cat_env = []
        for kw in catalog[tag_id]["env"]:
            en = translate(kw, all_warnings)
            if en and en not in cat_env:
                cat_env.append(en)
        # Fallback: templates need at least 3 env slots (fg/mid/bg)
        idx = 0
        while len(cat_env) < 3 and idx < len(ENV_FALLBACK):
            fb = ENV_FALLBACK[idx]
            if fb not in cat_env:
                cat_env.append(fb)
            idx += 1
        tag["catalog_env_partners"] = cat_env

        # Assign template group
        tag["template_group"] = TAG_TEMPLATE_GROUP.get(tag_id, "special")

        # v5.1 per-tag extras
        if tag_id == "Animals":
            tag["env_groups"] = ANIMALS_ENV_GROUPS
            tag["subject_env_group"] = ANIMALS_SUBJECT_ENV_GROUP
        if tag_id == "Sports":
            tag["env_groups"] = SPORTS_ENV_GROUPS
            tag["subject_env_group"] = SPORTS_SUBJECT_ENV_GROUP
        if tag_id == "Abstract":
            tag["photo_subjects"] = ABSTRACT_PHOTO_SUBJECTS
        if tag_id == "Art":
            tag["quality_prefix"] = ART_QUALITY_PREFIX

        # Quality split: subject tags get the relaxed profile (overrides global)
        if tag_id in SUBJECT_QUALITY_TAGS:
            tag["quality_prefix"] = SUBJECT_QUALITY_PREFIX
            tag["quality_tail"] = SUBJECT_QUALITY_TAIL

        # Inject viewpoint_deny for tags that lack it
        if "viewpoint_deny" not in tag or not tag.get("viewpoint_deny"):
            if tag_id in EXTRA_VP_DENY_TAGS:
                tag["viewpoint_deny"] = ["flat lay overhead view"]

        # Subject-scale fix: per-tag template override (round 2)
        if tag_id in SUBJECT_SCALE_TEMPLATES:
            tag["prompt_templates"] = SUBJECT_SCALE_TEMPLATES[tag_id]

        # Subject-scale fix: deny scale-shrinking viewpoints (merge, no dup)
        if tag_id in SUBJECT_SCALE_VP_DENY:
            vd = tag.setdefault("viewpoint_deny", [])
            vd.extend(w for w in SUBJECT_SCALE_VP_DENY[tag_id] if w not in vd)

        # Subject-scale fix: override optics with explicit scale clauses
        # (must run AFTER the missing-optics injection so the override wins).
        if tag_id in SUBJECT_SCALE_OPTICS:
            tag["optics"] = SUBJECT_SCALE_OPTICS[tag_id]
        elif not tag.get("optics") and tag_id in TAG_OPTICS:
            tag["optics"] = TAG_OPTICS[tag_id]

        lib["tags"].append(tag)

    # 4. Update version
    lib["version"] = "5.0"

    # 4a. Build-time assertion: no risk word may survive the hygiene pass.
    # Runs BEFORE the write so a regression never lands on disk.
    risk_hits = []
    for t in lib["tags"]:
        for s in t.get("catalog_subjects", []):
            if RISK_WORD_RE.search(s):
                risk_hits.append(f"{t['id']}: {s}")
    if risk_hits:
        print(f"\n[FATAL] {len(risk_hits)} risk word(s) survived the hygiene pass:")
        for h in risk_hits:
            print(f"  {h}")
        sys.exit(1)

    # 5. Write output
    with open(V5_JSON, "w", encoding="utf-8") as f:
        json.dump(lib, f, ensure_ascii=False, indent=2)
        f.write("\n")

    # 6. Report stats
    print(f"\n=== v5 Library Build Complete (pure catalog) ===")
    print(f"Output: {V5_JSON}")
    total_cat = 0
    total_env = 0
    for tag in lib["tags"]:
        n_sub = len(tag.get("catalog_subjects", []))
        n_env = len(tag.get("catalog_env_partners", []))
        total_cat += n_sub
        total_env += n_env
        print(
            f"  {tag['id']:16s} catalog={n_sub:3d}  env={n_env:2d}  "
            f"group={tag.get('template_group', '?')}"
        )
    print(f"  {'TOTAL':16s} catalog={total_cat:3d}  env={total_env:2d}")

    if all_warnings:
        print(f"\n--- {len(all_warnings)} untranslated keywords ---")
        for w in all_warnings:
            print(w)
    else:
        print("\nAll keywords translated successfully!")


if __name__ == "__main__":
    main()
