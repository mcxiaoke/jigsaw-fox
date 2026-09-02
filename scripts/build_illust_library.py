#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Build my_prompt_library_illust_v5.json
全面整合 docs/jigsaw-tag-subject-catalog.md 的 20 大类标签，
并融合用户提供的插画场景/主体/互动/氛围全景清单，
构建纯插画、全景深、零摄影词的高品质拼图生图提示词库。
"""

import json
import os
import copy

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
V5_PHOTO_PATH = os.path.join(PROJECT_ROOT, "scripts", "my_prompt_library_v5.json")
OUTPUT_ILLUST_PATH = os.path.join(PROJECT_ROOT, "scripts", "my_prompt_library_illust_v5.json")

# 用户新增的高价值插画题材与互动主体补充
USER_ILLUST_SUBJECT_EXTENSIONS = {
    "Cartoon": [
        "charming red fox wearing green tweed vest and tiny spectacles reading antique leather book in cozy armchair",
        "whimsical mother bear in checkered apron baking strawberry blackberry fruit pies in rustic kitchen",
        "sweet rabbit siblings with colorful backpacks having an outdoor picnic tea party among giant wildflowers",
        "cozy calico cat in knitted sweater sipping steaming coffee inside a sunlit vintage bakery shop",
        "tiny hedgehog wearing a wool scarf holding miniature brass lantern wandering through glowing mushroom path",
        "fairy village built inside cluster of giant spotted mushrooms with glowing carved windows and pebble steps",
        "magical steampunk airship city floating above pastel sunset clouds with spinning brass propellers",
        "tiny woodland mice dwelling inside hollowed ancient tree trunk with miniature wooden furniture and curtained windows",
        "whimsical animal orchestra playing violins and flutes under a canopy of blooming cherry blossoms",
        "cozy badger carpenter shaping wooden toys at sunlit workbench surrounded by wood shavings"
    ],
    "Fantasy": [
        "majestic celestial whale covered in glowing bioluminescent patterns gliding through twilight cloud forest",
        "graceful white unicorn drinking from crystal fairy pool surrounded by glowing bluebells and weeping willows",
        "ancient iridescent emerald dragon resting on hoard of gold coins and glittering gemstones inside cavern",
        "floating island archipelago linked by flowering vine suspension bridges with waterfalls cascading into clouds",
        "enchanted tree of life with glowing roots and tiny fairy cottages nestled along massive mossy branches",
        "magnificent nine-tailed fox with glowing white tails sitting on ancient stone torii gate among lotus pond",
        "magical alchemist workshop crowded with bubbling colorful potion bottles star charts and brass astrolabes",
        "glowing crystal palace deep in enchanted cavern with luminous amethyst spires and underground lake",
        "phoenix with brilliant flame-colored plumage perching on ancient golden tree branch",
        "flying manta ray creature soaring through dreamy twilight aurora sky over illuminated fantasy castle"
    ],
    "Transportation": [
        "vintage green pickup truck overflowing with sunflowers orange pumpkins and wooden apple crates at farm gate",
        "classic pastel blue camper van parked on coastal wildflower cliff with surfboards on roof at golden sunset",
        "historic steam locomotive puffing white smoke crossing grand stone viaduct through vibrant autumn mountains",
        "vintage bicycle with woven wicker basket laden with colorful fresh flowers leaning against brick garden wall",
        "colorful hot air balloons floating gently over sunlit countryside valley and rolling vineyard hills",
        "charming wooden rowboat drifting on calm water lily lake reflecting weeping willows and flowering shrubs",
        "quaint red and white retro tram travelling down a cobblestone European old town street with flower balconies",
        "vintage Vespa scooter in mint green parked outside colorful French bakery shop with striped awning"
    ],
    "People": [
        "gentle elderly clockmaker with magnifying loupe assembling intricate brass watch gears in cozy workshop",
        "artisan ceramic pottery master shaping clay vase on turning wheel surrounded by colorful painted glazed pots",
        "family having a joyful summer picnic on lush lawn with checkered blanket wicker basket and fresh pastries",
        "botanical artist painting delicate watercolor flowers at sunlit wooden table surrounded by herb specimens",
        "quaint village baker dusting white flour over golden sourdough loaves and croissants in morning light",
        "cozy knitter surrounded by baskets of colorful wool yarn skeins and warm knitted blankets by fireplace",
        "traditional gondolier guiding polished wooden gondola along historic Venice canal with flower bridges"
    ],
    "Nature": [
        "microscopic enchanted wonderland with dew drops on clover leaves reflecting tiny wild forest mushrooms",
        "primeval rainforest interior with sunbeams piercing through mossy ancient tree trunks and lush ferns",
        "miniature succulent dish garden with colorful echeveria stonecrops and pebbles in clay pot",
        "enchanted woodland moss garden with glowing bioluminescent fungi and morning dew on spiderwebs",
        "crystal clear forest brook cascading over mossy river stones with wild iris and ferns along the bank"
    ],
    "Pets": [
        "corgi puppy curled up asleep in a cozy wicker basket filled with colorful knitting yarn balls",
        "ragdoll cat perching gracefully on sunlit windowsill surrounded by blooming potted geraniums and orchids",
        "fluffy golden retriever holding a wicker basket of fresh sunflowers on sunny garden porch",
        "playful kitten batting at falling autumn maple leaves on rustic wooden porch steps"
    ],
    "Others": [
        "vintage explorer wooden study desk flat lay with parchment treasure map brass compass quill and magnifying glass",
        "Victorian dollhouse interior cross section fully furnished with tiny wallpapered rooms and miniature furniture",
        "antique sewing box display overflowing with colorful wooden thread spools brass scissors and lace ribbons",
        "cluttered collector curio cabinet filled with glowing mineral crystals vintage pocket watches and seashells"
    ]
}

# 用户提供的环境细节元素，丰富到所有 env 池中
EXTRA_ILLUST_ENV_PARTNERS = [
    "floating dandelion seeds and drifting flower petals in the gentle breeze",
    "glowing fireflies and luminous spores illuminating the warm atmosphere",
    "sunlit Tyndall light beams streaming through lush green foliage",
    "cobblestone pathway with flower petal sprinkles and puddles reflecting sky",
    "rustic wooden workbenches and shelves crowded with colorful artisan handcrafted wares"
]

def build_illust_library():
    with open(V5_PHOTO_PATH, 'r', encoding='utf-8') as f:
        v5 = json.load(f)
        
    illust_lib = {
        "version": "5.1-illust-all-tags",
        "_comment": "Full 20-tag illustration-driven library for vintage cottage, storybook, and jigsaw puzzle art style (like Dominic Davison, Kim Jacobs, Beatrix Potter). Zero photo-optics words, positive prompting only, corner-to-corner dense hand-painted detail, wide establishing framing.",
        "model_hint": "z-image-turbo-fp8 (8 steps, CFG 1.0) or SDXL/RealCartoon-XL",
        "critical_note": "CFG is near 1.0 on distilled Turbo models, so NEGATIVE prompts barely work. All constraints are written positively. Never use 'jigsaw puzzle' or 'puzzle pieces' in prompts as models might paint physical cut lines. No 'clean finish' or 'clean' words as they introduce flat dead zones.",
        "generation": {
            "steps": 8,
            "cfg": 1.0,
            "sampler": "res_multistep",
            "scheduler": "simple"
        },
        "ratios": {
            "4:3": {
                "width": 1152,
                "height": 864
            },
            "1:1": {
                "width": 1024,
                "height": 1024
            },
            "3:2": {
                "width": 1344,
                "height": 896
            },
            "2:3": {
                "width": 896,
                "height": 1344
            }
        },
        "active_ratios": [
            "1:1"
        ],
        "quality_prefix": "wide establishing view, entire subject fully visible within frame with generous headroom, no cropped roof, dense hand-painted detail, vibrant colorful illustration, deep depth of field, rich busy composition, full-bleed artwork",
        "quality_tail": "corner-to-corner texture, clear color separation between regions, visible fine brushwork, full-bleed painterly artwork",
        "modifiers": {
            "lighting": [
                "dappled warm sunlight filtering through foliage",
                "bright sunny day lighting with colorful shadows",
                "warm golden afternoon sunlight",
                "soft warm ambient light with luminous highlights",
                "golden hour light casting warm glows",
                "sun-drenched morning light with crisp clarity",
                "warm interior light glowing through multi-paned windows",
                "dappled warm sunlight filtering through foliage",
                "bright sunny day lighting with colorful shadows",
                "warm golden afternoon sunlight"
            ],
            "viewpoint": [
                "wide-angle landscape view with full subject in frame",
                "wide establishing shot with expansive deep focus",
                "slightly elevated perspective showing full layout",
                "picturesque eye-level wide shot with generous framing",
                "three-quarter angled wide perspective",
                "wide panoramic landscape view with layered depth",
                "slightly elevated perspective showing full layout"
            ],
            "atmosphere": [
                "candy-bright multicolor palette with saturated jewel tones",
                "warm golden sunlight palette with vivid colorful accents",
                "vibrant high-contrast colorful harmony",
                "lively cheerful storybook color grading",
                "rich harmonious palette with bright reds yellows and blues",
                "warm nostalgic pastoral charm with saturated hues",
                "candy-bright multicolor palette with saturated jewel tones",
                "warm golden sunlight palette with vivid colorful accents"
            ]
        },
        "style_pools": {
            "illust": [
                "in the classic storybook illustration style of Dominic Davison and Kim Jacobs, rich textured gouache and watercolor painting with fine brushwork",
                "richly detailed European storybook gouache illustration with visible brushstrokes and vivid color depth",
                "detailed gouache and watercolor painting with intricate architectural and floral details",
                "classic storybook illustration with textured brushstrokes and warm nostalgic charm",
                "lively painterly acrylic and gouache artwork with thick visible brushwork and crisp outlines",
                "richly textured folk-art inspired painterly illustration with dense decorative detail",
                "in the classic storybook illustration style of Dominic Davison and Kim Jacobs, rich textured gouache and watercolor painting with fine brushwork",
                "richly detailed European storybook gouache illustration with visible brushstrokes and vivid color depth"
            ]
        },
        "prompt_templates": {
            "animal": [
                "a wide scenic view of a charming {subject}, prominently featured and fully visible in the midground, with {env_fg} in the foreground, {env_mid} across center, and {env_bg} in the background, {detail} throughout",
                "a picturesque landscape view featuring {subject} in the midground, with {env_fg} leading inward, {env_mid} framing the scene, and {env_bg} completing the depth",
                "a delightful storybook scene of {subject}, completely visible within the frame, surrounded by {env_fg} up close, with {env_mid} at center and {env_bg} in the distance"
            ],
            "scene": [
                "a wide scenic view of {subject}, the entire scene and all structures fully visible in the midground, with {env_fg} in foreground, {env_mid} filling middle, and {env_bg} across the horizon, {detail} throughout",
                "an expansive establishing view of {subject}, completely visible within the frame with generous headroom, with {env_fg} leading into scene, {env_mid} across center, and {env_bg} filling the sky",
                "a lively detailed wide view of {subject}, all architectural structures fully visible, with {env_fg} up close, {env_mid} stretching across center, and {env_bg} across the distance"
            ],
            "object": [
                "a richly detailed full view of {subject}, beautifully arranged and fully visible in the midground, with {env_fg} in foreground, {env_mid} displayed across center, and {env_bg} filling every corner, {detail} throughout",
                "an expansive picturesque arrangement of {subject}, completely in frame, surrounded by {env_fg}, with {env_mid} filling middle and {env_bg} across the walls",
                "a vibrant storybook composition featuring {subject}, with {env_fg} up close, {env_mid} at center, and {env_bg} completing the setting"
            ],
            "special": [
                "a wide establishing composition of {subject}, entire scene fully visible within frame, with {env_fg} in foreground, {env_mid} filling center, and {env_bg} extending to all edges, {detail} throughout",
                "a richly detailed full view of {subject}, completely in frame with generous framing, with {env_fg} throughout, {env_mid} at center, and {env_bg} filling every corner",
                "a vibrant storybook landscape view of {subject}, with {env_fg} in the foreground, {env_mid} at center, and {env_bg} in the background"
            ],
            "cottage": [
                "a wide scenic view of a charming {subject}, the entire cottage with complete roof and chimney fully visible in the midground, with {env_fg} in the foreground, {env_mid} framing the sides, and {env_bg} above, {detail} throughout",
                "an expansive picturesque {subject}, entire architecture fully visible in the midground, with {env_fg} leading inward, {env_mid} flanking the sides, and {env_bg} completing the scenic depth",
                "a full landscape view of a {subject}, completely visible within the frame, surrounded by {env_fg} in the foreground, with {env_mid} at center and {env_bg} filling the sky"
            ]
        },
        "tags": []
    }
    
    # 遍历原版 v5 的全部 20 个 tag，进行插画化转换
    for old_tag in v5["tags"]:
        tag = copy.deepcopy(old_tag)
        tag_id = tag["id"]
        
        # 1. 强制风格池切换为 illust
        tag["style_pool"] = "illust"
        
        # 2. 默认比例设为 1:1（适配游戏原生支持，避免 4:3 自动裁切）
        tag["ratios"] = ["1:1"]
        
        # 3. 彻底清除摄影词 optics
        if "optics" in tag:
            del tag["optics"]
            
        # 4. 清除 photo_subjects 特例（所有主体一律享受插画池）
        if "photo_subjects" in tag:
            del tag["photo_subjects"]
            
        # 5. 视角过滤（杜绝 flat lay 与低仰角）
        vp_deny = set(tag.get("viewpoint_deny", []))
        vp_deny.add("flat lay overhead view")
        if tag_id in {"Animals", "Pets", "Birds", "People", "Cities", "Architecture", "Transportation", "Landscapes"}:
            vp_deny.add("low angle view")
        tag["viewpoint_deny"] = list(vp_deny)
        
        # 6. 为建筑与田园庭院特别指定 cottage 模板
        if tag_id in {"Architecture", "Cottage_Gardens"}:
            tag["template_group"] = "cottage"
            
        # 7. 注入用户提供的新增主体与环境
        if tag_id in USER_ILLUST_SUBJECT_EXTENSIONS:
            existing_subs = set(tag.get("catalog_subjects", []))
            for new_sub in USER_ILLUST_SUBJECT_EXTENSIONS[tag_id]:
                if new_sub not in existing_subs:
                    tag.setdefault("catalog_subjects", []).insert(0, new_sub)
                    
        # 注入环境细节元素
        env_list = tag.get("catalog_env_partners", [])
        for extra_env in EXTRA_ILLUST_ENV_PARTNERS:
            if extra_env not in env_list and len(env_list) < 12:
                env_list.append(extra_env)
        tag["catalog_env_partners"] = env_list
        
        illust_lib["tags"].append(tag)
        
    # 保存输出
    with open(OUTPUT_ILLUST_PATH, 'w', encoding='utf-8') as f:
        json.dump(illust_lib, f, indent=2, ensure_ascii=False)
        
    print(f"Successfully generated {OUTPUT_ILLUST_PATH} with {len(illust_lib['tags'])} tags!")

if __name__ == "__main__":
    build_illust_library()
