#!/usr/bin/env python3
"""
organize_images_by_tag.py — 通用图片素材按标签分类整理脚本

功能与特点：
1. 通用化与参数标准化：
   - 必须通过 -i/--input 传入源素材目录，-o/--output 传入目标输出目录（缺省自动命名为 <input>_by_tag）；
   - 支持多素材库迁移，绝对不硬编码任何具体路径。
2. 零外部依赖与多级元数据探测：
   - 内置完整的 31 个标准新标签体系与高精度主体词库规则，脱离外部 JSON 亦可独立运行；
   - 支持自动探测 _metadata/*.jsonl、tags.json；
   - 支持通过 PIL 自动提取 PNG 内部潜伏的 ComfyUI / WebUI 提示词（节点图 CLIPTextEncode / parameters）；
   - 缺乏 Prompt 时自动退化为目录名与文件名模式识别。
3. 严格遵循保留原目录规则：
   - 凡是命中 31 个新标签（如 Cats, Dogs, Sweets, Castles, Mountains, Forests, SeaLife 等）的图片，归整至新标签子目录；
   - 凡是没有对应新标签或非目标细分的图片（如 Space, Sports, People, Transportation 以及正餐 Food, 小宠 Pets 等），
     严格保持其源目录名称，不混入 Others，极大方便人工独立二次筛选。
4. 多种文件操作模式：
   - --action link （Windows NTFS 硬链接，0 磁盘开销，瞬间完成，强烈推荐）；
   - --action copy （安全复制，保留原文件）；
   - --action move （物理移动）。
5. 自动对接打包工具：
   - 整理后在目标目录自动生成 tags.json 与 _reorganize_report.txt，
     可直接由 scripts/packaging/server.py 打开审查、筛选与打包。

使用示例：
    # 预览分类分布（Dry Run，不改动文件）
    python scripts/organize_images_by_tag.py -i "D:\\puzzles\\raw_set1" --dry-run

    # NTFS 硬链接整理（瞬间完成，0 额外磁盘占用）
    python scripts/organize_images_by_tag.py -i "C:\\Home\\Temp\\JigsawV5_full" -o "C:\\Home\\Temp\\JigsawV5_by_tag" --action link

    # 安全拷贝模式
    python scripts/organize_images_by_tag.py -i "D:\\images\\batch_01" -o "D:\\images\\batch_01_sorted" --action copy
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import time
from collections import defaultdict
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(__file__).resolve().parent.parent

# Fix Windows console UTF-8 output
if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

try:
    from PIL import Image
    HAS_PIL = True
except ImportError:
    HAS_PIL = False

IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tiff"}

# ---------------------------------------------------------------------------
# 31 Specific Tags -> Catalogs 映射表（依据 v2.1 规范）
# ---------------------------------------------------------------------------
TAG_TO_CATALOGS: dict[str, list[str]] = {
    # 动物萌宠 (5)
    "Cats": ["animals", "cozy"],
    "Dogs": ["animals"],
    "Birds": ["animals"],
    "Wildlife": ["animals", "nature"],
    "SeaLife": ["animals", "nature"],
    # 自然风光 (4)
    "Mountains": ["nature"],
    "Forests": ["nature"],
    "Ocean": ["nature", "travel"],
    "Sunsets": ["nature"],
    # 城市旅行 (3)
    "Landmarks": ["travel"],
    "Castles": ["travel", "fantasy"],
    "Villages": ["travel"],
    # 花卉园艺 (2)
    "Flowers": ["flowers"],
    "Botanical": ["flowers"],
    # 温馨生活 (4)
    "Cottages": ["cozy", "holiday"],
    "CozyHome": ["cozy"],
    "Vintage": ["cozy", "travel"],
    "Crafts": ["cozy", "colors"],
    # 美食甜品 (2)
    "Sweets": ["food", "colors"],
    "CoffeeTea": ["food", "cozy"],
    # 缤纷色彩 (3)
    "Colors": ["colors", "fantasy"],
    "FlatLay": ["colors", "food"],
    "Mandala": ["colors", "art"],
    # 唯美艺术 (3)
    "FineArt": ["art"],
    "Illustration": ["art"],
    "Oriental": ["art"],
    # 奇幻仙境 (2)
    "Mythical": ["fantasy", "animals"],
    "Zodiac": ["fantasy", "art"],
    # 节日时令 (3)
    "Christmas": ["holiday", "cozy"],
    "Halloween": ["holiday"],
    "Seasons": ["holiday", "nature", "flowers"],
    # 兜底 (1)
    "Others": ["others"],
    # 兼容历史大类作为目录时的默认归属
    "Animals": ["animals"],
    "Pets": ["animals", "cozy"],
    "Nature": ["nature"],
    "Landscapes": ["nature"],
    "Cities": ["travel"],
    "Architecture": ["travel"],
    "Food": ["food"],
    "Art": ["art"],
    "Cartoon": ["art"],
    "Fantasy": ["fantasy"],
    "Holidays": ["holiday"],
    "Abstract": ["colors"],
    "Transportation": ["others"],
    "Space": ["others"],
    "Sports": ["others"],
    "People": ["others"],
}

# ---------------------------------------------------------------------------
# 内置自包含的提示词/主体关键词规则（脱离外部文件也能 100% 准确运作）
# ---------------------------------------------------------------------------
DEFAULT_TAG_RULES: list[tuple[str, str]] = [
    # 1. 宠物
    ("Cats", r"\b(cat|cats|kitten|kittens|feline|ragdoll|tabby|siamese|persian|british shorthair|scottish fold|maine coon|sphynx|abyssinian|bengal)\b"),
    ("Dogs", r"\b(dog|dogs|puppy|puppies|corgi|shiba|retriever|poodle|bulldog|dachshund|terrier|husky|beagle|shepherd|samoyed|border collie|chihuahua|pomeranian|schnauzer|bichon|dalmatian|labrador)\b"),

    # 2. 动物
    ("Birds", r"\b(bird|birds|owl|owls|parrot|parrots|flamingo|flamingos|eagle|hummingbird|toucan|swan|peacock|sparrow|goldfinch|blue jay|cardinal|kingfisher|woodpecker|heron|pelican|puffin|robin|cockatoo|macaw|egret|penguin)\b"),
    ("SeaLife", r"\b(coral reef|tropical fish|sea turtle|dolphin|dolphins|whale|whales|jellyfish|seahorse|octopus|manta ray|shark|sharks|orca|sea otter|marine life|anemone|starfish|tang fish|sea lion|seal)\b"),
    ("Wildlife", r"\b(lion|lions|lioness|tiger|tigers|bear|bears|grizzly|polar bear|fox|foxes|deer|wolf|wolves|elephant|elephants|giraffe|giraffes|zebra|zebras|panda|pandas|monkey|cheetah|leopard|rhino|hippo|koala|kangaroo|red panda|jaguar|bison|moose|antelope|hyena|meerkat|lemur|lynx|wild horse|panther|cougar)\b"),

    # 3. 美食
    ("CoffeeTea", r"\b(coffee|tea|latte|espresso|cappuccino|teapot|teacup|coffee cup|pour-over|afternoon tea|english tea set|matcha|tea stand|tea party)\b"),
    ("Sweets", r"\b(dessert|desserts|cake|cakes|cupcake|cupcakes|macaron|macarons|pastry|pastries|bakery|donut|donuts|chocolate|candy|waffle|pancake|tart|pie|ice cream|cookies|croissant|churros|eclair|creme brulee|pudding|parfait|cheesecake|pavlova|cannoli|brownie|muffin|danish|canel|tiramisu)\b"),

    # 4. 建筑与旅行
    ("Castles", r"\b(castle|castles|palace|palaces|fortress|chateau|neuschwanstein|alcazar|alhambra|forbidden city|windsor|versailles)\b"),
    ("Villages", r"\b(village|villages|canal town|cottage town|fishing village|santorini|hallstatt|cotswolds|cinque terre|water town|old town alley|windmill village)\b"),
    ("Landmarks", r"\b(landmark|landmarks|monument|eiffel tower|arc de triomphe|colosseum|taj mahal|great wall|big ben|tower bridge|statue of liberty|notre dame|cathedral|pagoda|sun yat-sen|leaning tower|acropolis|pyramid|sydney opera|st\.? basil|pantheon|sagrada)\b"),

    # 5. 自然与风光
    ("Sunsets", r"\b(sunset|sunsets|sunrise|golden hour|dusk|twilight|dawn glow)\b"),
    ("Ocean", r"\b(ocean|beach|waves|coast|coastal|seashore|shoreline|sea cliff|tide pool|barrel wave|rolling waves|sea foam)\b"),
    ("Mountains", r"\b(mountain|mountains|peak|peaks|alpine|glacier|lake|lakes|canyon|rocky mountain|snow-capped|matterhorn|fuji|crater lake|snow peak|fjord)\b"),
    ("Forests", r"\b(forest|forests|woodland|pine trees|mossy trees|redwood|woods|rainforest|bamboo grove|birch grove|banyan tree)\b"),

    # 6. 花卉与绿植
    ("Botanical", r"\b(succulent|succulents|cactus|cacti|bonsai|fern|ferns|mushroom|mushrooms|houseplant|monstera|pothos|moss terrarium|terrarium|air plant|agaric)\b"),
    ("Flowers", r"\b(flower|flowers|rose|roses|tulip|tulips|sunflower|sunflowers|peony|peonies|wisteria|blossom|blossoms|floral|bouquet|hydrangea|magnolia|lotus|dahlia|camellia|daisy|orchid|lavender|plum blossom|cherry blossom)\b"),

    # 7. 温馨与手作
    ("Cottages", r"\b(cottage|cottages|cabin|cabins|wood cabin|log house|chalet|thatched cottage|stone cottage)\b"),
    ("CozyHome", r"\b(living room|kitchen|bedroom|bookshelf|fireplace|armchair|reading nook|cozy interior|tiled floor and open cupboards)\b"),
    ("Vintage", r"\b(vintage|retro|antique|nostalgic|typewriter|gramophone|pocket watch|classic car|old pickup|rotary phone|vintage radio|brass compass|flea market|antique shop|vintage cutlery|classic automobile|steam locomotive)\b"),
    ("Crafts", r"\b(knitting|yarn|sewing|embroidery|patchwork|quilting|crochet|colorful buttons|spools of thread|needlework|handicraft|quilt|sewing box)\b"),

    # 8. 图案与色彩
    ("Mandala", r"\b(mandala|kaleidoscope|kaleidoscopic|sacred geometry|ornate pattern|geometric tapestry|zen tangle)\b"),
    ("FlatLay", r"\b(flat lay|flatlay|knolling|overhead arrangement|top-down view|organized tools|stationery flat lay|terrazzo chips)\b"),
    ("Colors", r"\b(rainbow|spectral|spectrum|vibrant gradient|chromatic|prism|color spectrum|multicolor palette|neon tube|glowing neon)\b"),

    # 9. 艺术与国风插画
    ("Oriental", r"\b(oriental|chinese|gongbi|guochao|blue and white porcelain|ink wash|pagoda garden|hanfu|chinese garden|traditional asian|dragon dance|oriental fan)\b"),
    ("FineArt", r"\b(oil painting|fine art|masterpiece|impressionist|renaissance|baroque|monet|van gogh|mucha|vermeer|klimt|golden age|cezanne|rembrandt)\b"),
    ("Illustration", r"\b(illustration|storybook|whimsical illustration|cartoon illustration|storybook art|wimmelbilder|children story|hand-drawn|izakaya|watercolor cartoon)\b"),

    # 10. 奇幻与星象
    ("Mythical", r"\b(dragon|dragons|unicorn|unicorns|phoenix|fairy|fairies|pegasus|griffin|manticore|cyclops|magic potion|sword in stone|wizard|gargoyle|little monster)\b"),
    ("Zodiac", r"\b(zodiac|constellation|astrology|horoscope|celestial map|star chart)\b"),

    # 11. 节日
    ("Christmas", r"\b(christmas|xmas|santa|snow globe|reindeer|gingerbread|nutcracker|christmas tree|advent|holiday wreath|christmas market)\b"),
    ("Halloween", r"\b(halloween|jack-o-lantern|pumpkin|spooky|haunted|ghost|ghosts|skeleton|witch|cobwebs)\b"),
    ("Seasons", r"\b(autumn foliage|spring blossoms|winter snow|summer sunny|fall harvest|acorns|snowmelt|apple orchard|seasonal)\b"),
]


def extract_subject_from_prompt(prompt: str) -> str:
    """从生成式提示词中提取最核心的主体短语，剥除前置词与后续环境修饰。"""
    p = prompt.strip()
    p = re.sub(
        r"^(a|an|one)\s+(single|detailed|richly detailed|wide|full|expansive|large)?\s*",
        "",
        p,
        flags=re.IGNORECASE,
    )
    parts = re.split(
        r"\s+(?:with|in the foreground|in the midground|in the background|surrounded by|framed by|featuring|set in|setting|scene with|set against)\s+",
        p,
        flags=re.IGNORECASE,
    )
    return parts[0].strip() if parts else p


def extract_prompt_from_png(file_path: Path) -> str | None:
    """尝试从 PNG 文件内置的文本块（如 ComfyUI / Stable Diffusion）中提取提示词。"""
    if not HAS_PIL or file_path.suffix.lower() != ".png":
        return None
    try:
        with Image.open(file_path) as img:
            info = img.info or {}
            # 1. ComfyUI 流程图存储在 'prompt' 键中
            if "prompt" in info:
                raw = info["prompt"]
                try:
                    data = json.loads(raw)
                    if isinstance(data, dict):
                        for _, v in data.items():
                            if isinstance(v, dict):
                                ctype = v.get("class_type", "")
                                inputs = v.get("inputs", {})
                                if "text" in inputs and isinstance(inputs["text"], str):
                                    t = inputs["text"].strip()
                                    if len(t) > 15 and not t.startswith("bad_"):
                                        return t
                except Exception:
                    pass
            # 2. WebUI / A1111 格式存储在 'parameters' 中
            if "parameters" in info:
                raw = info["parameters"]
                # 取第一行作为正向提示词
                return raw.split("\n")[0].strip()
    except Exception:
        pass
    return None


def load_subjects_from_library(lib_path: Path | None) -> dict[str, list[str]]:
    """若指定或默认存在词库 JSON，载入 catalog_subjects。"""
    if not lib_path or not lib_path.exists():
        return {}
    try:
        data = json.loads(lib_path.read_text(encoding="utf-8"))
        res: dict[str, list[str]] = {}
        for t in data.get("tags", []):
            tid = t.get("id")
            if tid:
                subjs = sorted(t.get("catalog_subjects", []), key=len, reverse=True)
                res[tid] = subjs
        return res
    except Exception as e:
        print(f"[提示] 读取提示词库失败 ({e})，将依赖内置规则引擎运行。")
        return {}


def classify_image(
    filename: str,
    old_folder: str,
    prompt: str,
    tag_subjs: dict[str, list[str]],
) -> tuple[str, str]:
    """
    通用分类决策器：
    1. 优先使用主体短语进行关键词匹配；
    2. 针对特定旧目录定向裂变（如 Pets 裂变为 Cats/Dogs，Food 裂变为 Sweets/CoffeeTea）；
    3. 未命中新 Tag 时，严格保留原目录名（old_folder）。
    """
    pr = (prompt or "").lower()
    fn = filename.lower()
    subj = ""

    # 从外部词库精确查找主体
    for s in tag_subjs.get(old_folder, []):
        if s.lower() in pr:
            subj = s.lower()
            break

    # 若未找到词库主体，则进行文本切词提取
    if not subj and pr:
        subj = extract_subject_from_prompt(pr).lower()

    # 1. 宠物目录裂变：Pets -> Cats / Dogs / 保留原 Pets
    if old_folder in ("Pets", "pets"):
        cat_kws = ["cat", "kitten", "ragdoll", "tabby", "siamese", "persian", "british shorthair", "scottish fold", "maine coon", "sphynx", "abyssinian", "bengal"]
        dog_kws = ["dog", "puppy", "corgi", "shiba", "retriever", "poodle", "bulldog", "dachshund", "terrier", "husky", "beagle", "shepherd", "samoyed", "border collie", "chihuahua", "pomeranian", "schnauzer", "bichon", "dalmatian", "labrador"]
        if any(w in subj or w in fn or w in pr[:60] for w in cat_kws):
            return "Cats", f"从Pets裂变猫咪: {subj or 'cat'}"
        if any(w in subj or w in fn or w in pr[:60] for w in dog_kws):
            return "Dogs", f"从Pets裂变狗狗: {subj or 'dog'}"
        return old_folder, f"保留原目录{old_folder}(小宠免混入Others)"

    # 2. 动物目录裂变：Animals -> Birds / SeaLife / Wildlife / 保留原 Animals
    if old_folder in ("Animals", "animals"):
        bird_kws = ["bird", "owl", "parrot", "flamingo", "eagle", "toucan", "swan", "peacock", "penguin", "egret", "heron"]
        sea_kws = ["coral reef", "fish", "turtle", "dolphin", "whale", "jellyfish", "seahorse", "octopus", "manta ray", "shark", "orca", "marine", "otter", "seal", "sea lion", "anemone", "starfish"]
        wild_kws = ["lion", "tiger", "bear", "fox", "deer", "wolf", "elephant", "giraffe", "zebra", "panda", "monkey", "cheetah", "leopard", "rhino", "hippo", "koala", "kangaroo", "red panda", "jaguar", "bison", "moose", "antelope", "hyena", "meerkat", "lemur", "lynx", "wild horse", "panther", "cougar"]
        if any(w in subj or w in fn for w in bird_kws):
            return "Birds", f"从Animals细分飞禽: {subj or 'bird'}"
        if any(w in subj or w in fn for w in sea_kws):
            return "SeaLife", f"从Animals细分水族: {subj or 'marine'}"
        if any(w in subj or w in fn for w in wild_kws):
            return "Wildlife", f"从Animals细分陆生猛兽: {subj or 'wildlife'}"
        return old_folder, f"保留原目录{old_folder}"

    # 3. 鸟类
    if old_folder in ("Birds", "birds"):
        return "Birds", "原生分类飞禽鸟类"

    # 4. 美食目录裂变：Food -> Sweets / CoffeeTea / 保留原 Food (正餐料理)
    if old_folder in ("Food", "food"):
        tea_kws = ["tea", "coffee", "latte", "espresso", "cappuccino", "teapot", "matcha", "cafe", "pour-over", "tea set"]
        sweet_kws = ["cake", "dessert", "cupcake", "macaron", "pastry", "bakery", "donut", "chocolate", "candy", "waffle", "pancake", "tart", "pie", "ice cream", "cookies", "croissant", "eclair", "creme brulee", "pudding", "parfait", "cheesecake", "pavlova", "cannoli", "brownie", "muffin", "danish", "canel", "tiramisu"]
        if any(w in subj or w in fn for w in tea_kws):
            return "CoffeeTea", f"从Food细分咖啡茶饮: {subj or 'tea/coffee'}"
        if any(w in subj or w in fn for w in sweet_kws):
            return "Sweets", f"从Food细分甜点烘焙: {subj or 'sweet/cake'}"
        return old_folder, f"保留原目录{old_folder}(正餐料理)"

    # 5. 建筑与城市裂变：Architecture/Cities -> Castles / Villages / Landmarks / 保留原目录
    if old_folder in ("Architecture", "Cities", "architecture", "cities"):
        castle_kws = ["castle", "palace", "fortress", "chateau", "neuschwanstein", "alcazar", "alhambra", "forbidden city", "windsor", "versailles"]
        village_kws = ["village", "canal town", "cottage town", "fishing village", "santorini", "hallstatt", "cotswolds", "cinque terre", "water town", "windmill village", "old town alley"]
        landmark_kws = ["landmark", "eiffel", "arc de triomphe", "colosseum", "taj mahal", "great wall", "big ben", "tower bridge", "statue of liberty", "notre dame", "cathedral", "sun yat-sen", "leaning tower", "acropolis", "pyramid", "sydney opera", "st. basil", "pantheon", "sagrada", "pagoda", "monument"]
        if any(w in subj or w in fn for w in castle_kws):
            return "Castles", f"从{old_folder}细分古堡宫殿: {subj}"
        if any(w in subj or w in fn for w in village_kws):
            return "Villages", f"从{old_folder}细分街景小镇: {subj}"
        if any(w in subj or w in fn for w in landmark_kws):
            return "Landmarks", f"从{old_folder}细分名胜地标: {subj}"
        return old_folder, f"保留原目录{old_folder}"

    # 6. 风景与自然裂变：Landscapes/Nature -> Mountains / Forests / Sunsets / Ocean / 保留原目录
    if old_folder in ("Landscapes", "Nature", "landscapes", "nature"):
        sunset_kws = ["sunset", "sunrise", "golden hour", "dusk", "twilight"]
        mountain_kws = ["mountain", "peak", "glacier", "lake", "canyon", "snow-capped", "matterhorn", "fuji", "crater lake", "fjord", "rocky mountain"]
        forest_kws = ["forest", "woodland", "pine", "redwood", "woods", "rainforest", "bamboo grove", "birch", "tree", "trees", "grove", "banyan"]
        ocean_kws = ["ocean", "beach", "waves", "coast", "seashore", "cliff", "tide pool", "breaking waves", "surf"]
        if any(w in subj or w in fn for w in sunset_kws):
            return "Sunsets", f"从{old_folder}细分日落晚霞: {subj}"
        if any(w in subj or w in fn for w in mountain_kws):
            return "Mountains", f"从{old_folder}细分山峦湖泊: {subj}"
        if any(w in subj or w in fn for w in forest_kws):
            return "Forests", f"从{old_folder}细分森林自然: {subj}"
        if any(w in subj or w in fn for w in ocean_kws):
            return "Ocean", f"从{old_folder}细分海洋海岸: {subj}"
        return old_folder, f"保留原目录{old_folder}"

    # 7. 花卉目录裂变：Flowers -> Botanical / Flowers
    if old_folder in ("Flowers", "flowers"):
        botanical_kws = ["succulent", "cactus", "bonsai", "fern", "mushroom", "terrarium", "houseplant", "air plant", "plant"]
        if any(w in subj or w in fn for w in botanical_kws):
            return "Botanical", f"从Flowers细分绿植多肉: {subj}"
        return "Flowers", "花卉花园标准标签"

    # 8. 海洋目录裂变：Ocean -> SeaLife / Ocean
    if old_folder in ("Ocean", "ocean"):
        marine_kws = ["fish", "whale", "dolphin", "turtle", "shark", "coral", "jellyfish", "orca", "seahorse", "octopus", "marine", "tang"]
        if any(w in subj or w in fn for w in marine_kws):
            return "SeaLife", f"从Ocean细分海洋水族: {subj}"
        return "Ocean", "海洋海岸风光"

    # 9. 节庆目录裂变：Holidays -> Christmas / Halloween / Seasons / 保留原目录
    if old_folder in ("Holidays", "holidays"):
        xmas_kws = ["christmas", "xmas", "santa", "snow globe", "reindeer", "gingerbread", "nutcracker"]
        halloween_kws = ["halloween", "pumpkin", "ghost", "skeleton", "witch", "haunted", "jack-o-lantern"]
        if any(w in subj or w in fn for w in xmas_kws):
            return "Christmas", f"从Holidays细分圣诞冬日: {subj}"
        if any(w in subj or w in fn for w in halloween_kws):
            return "Halloween", f"从Holidays细分万圣节日: {subj}"
        return old_folder, f"保留原目录{old_folder}"

    # 10. 抽象目录裂变：Abstract -> Mandala / FlatLay / Colors / 保留原目录
    if old_folder in ("Abstract", "abstract"):
        mandala_kws = ["mandala", "kaleidoscope", "geometry", "pattern", "tapestry"]
        flatlay_kws = ["flat lay", "flatlay", "knolling", "chips", "arrangement", "terrazzo"]
        color_kws = ["rainbow", "neon", "spectrum", "gradient", "chromatic", "prism", "color"]
        if any(w in subj or w in fn for w in mandala_kws):
            return "Mandala", f"从Abstract细分曼陀罗: {subj}"
        if any(w in subj or w in fn for w in flatlay_kws):
            return "FlatLay", f"从Abstract细分俯拍平铺: {subj}"
        if any(w in subj or w in fn for w in color_kws):
            return "Colors", f"从Abstract细分彩虹色彩: {subj}"
        return old_folder, f"保留原目录{old_folder}"

    # 11. 艺术与插画裂变：Art / Cartoon -> Oriental / FineArt / Illustration / 保留原目录
    if old_folder in ("Art", "Cartoon", "art", "cartoon"):
        oriental_kws = ["oriental", "chinese", "gongbi", "guochao", "porcelain", "ink wash", "hanfu", "pagoda garden"]
        fineart_kws = ["oil painting", "fine art", "masterpiece", "impressionist", "monet", "van gogh", "mucha", "vermeer", "klimt", "golden age", "renaissance"]
        illust_kws = ["illustration", "storybook", "whimsical", "cartoon", "wimmelbilder", "izakaya", "story", "children"]
        if any(w in subj or w in fn for w in oriental_kws):
            return "Oriental", f"从{old_folder}细分国风东方: {subj}"
        if any(w in subj or w in fn for w in fineart_kws):
            return "FineArt", f"从{old_folder}细分经典名画: {subj}"
        if any(w in subj or w in fn for w in illust_kws):
            return "Illustration", f"从{old_folder}细分治愈插画: {subj}"
        return old_folder, f"保留原目录{old_folder}"

    # 12. 奇幻目录裂变：Fantasy -> Mythical / Zodiac / Castles / 保留原目录
    if old_folder in ("Fantasy", "fantasy"):
        myth_kws = ["dragon", "unicorn", "phoenix", "fairy", "pegasus", "griffin", "monster", "manticore", "cyclops", "creature", "hydra"]
        zodiac_kws = ["zodiac", "constellation", "astrology", "horoscope", "celestial", "star chart"]
        if any(w in subj or w in fn for w in myth_kws):
            return "Mythical", f"从Fantasy细分奇幻神兽: {subj}"
        if any(w in subj or w in fn for w in zodiac_kws):
            return "Zodiac", f"从Fantasy细分星座星象: {subj}"
        return old_folder, f"保留原目录{old_folder}"

    # 13. 其他目录分类：Others -> Vintage / Crafts / 保留原目录
    if old_folder in ("Others", "others"):
        vintage_kws = ["typewriter", "gramophone", "pocket watch", "vintage", "retro", "antique", "radio", "compass"]
        craft_kws = ["knitting", "yarn", "sewing", "buttons", "embroidery", "patchwork", "quilting", "craft"]
        if any(w in subj or w in fn for w in vintage_kws):
            return "Vintage", f"从Others细分复古珍奇: {subj}"
        if any(w in subj or w in fn for w in craft_kws):
            return "Crafts", f"从Others细分手作布艺: {subj}"
        return old_folder, f"保留原目录{old_folder}"

    # 14. 交通目录：Transportation -> Vintage / 保留原目录
    if old_folder in ("Transportation", "transportation"):
        if any(w in subj or w in fn for w in ["vintage", "classic car", "retro pickup", "steam locomotive", "antique"]):
            return "Vintage", f"从Transportation细分复古老车: {subj}"
        return old_folder, f"保留原目录{old_folder}"

    # 15. 太空目录：Space -> Zodiac / 保留原目录
    if old_folder in ("Space", "space"):
        if any(w in subj or w in fn for w in ["zodiac", "constellation", "astrology"]):
            return "Zodiac", f"从Space细分星座星象: {subj}"
        return old_folder, f"保留原目录{old_folder}"

    # 16. 四季直接对齐
    if old_folder in ("Seasons", "seasons"):
        return "Seasons", "保留四季节庆标签"

    # 17. 其它通用匹配兜底（若主体强匹配 31 标签词库规则）
    for tag_name, pat in DEFAULT_TAG_RULES:
        if re.search(pat, subj):
            return tag_name, f"规则强匹配主体: {subj}"

    # 18. 终极兜底：严格保留原目录名
    return old_folder, f"保留源目录名: {old_folder}"


def load_metadata_store(src_dir: Path, custom_meta: Path | None) -> dict[str, dict[str, Any]]:
    """在输入目录或指定路径自动载入元数据（_metadata/*.jsonl 或 tags.json）。"""
    records: dict[str, dict[str, Any]] = {}

    candidates: list[Path] = []
    if custom_meta:
        candidates.append(custom_meta)
    else:
        # 默认优先探测 _metadata 目录
        meta_dir = src_dir / "_metadata"
        if meta_dir.exists() and meta_dir.is_dir():
            candidates.append(meta_dir)
        # 探测 tags.json
        tags_json = src_dir / "tags.json"
        if tags_json.exists() and tags_json.is_file():
            candidates.append(tags_json)

    for cand in candidates:
        if cand.is_dir():
            for jf in sorted(cand.glob("*.jsonl")):
                try:
                    for line in jf.read_text(encoding="utf-8", errors="ignore").splitlines():
                        if not line.strip():
                            continue
                        d = json.loads(line)
                        fname = d.get("filename") or d.get("file")
                        if fname:
                            records[fname] = d
                except Exception as e:
                    print(f"[提示] 读取元数据 {jf.name} 异常: {e}")
        elif cand.is_file():
            if cand.suffix.lower() == ".jsonl":
                try:
                    for line in cand.read_text(encoding="utf-8", errors="ignore").splitlines():
                        if not line.strip():
                            continue
                        d = json.loads(line)
                        fname = d.get("filename") or d.get("file")
                        if fname:
                            records[fname] = d
                except Exception:
                    pass
            elif cand.suffix.lower() == ".json":
                try:
                    raw = json.loads(cand.read_text(encoding="utf-8"))
                    items = raw if isinstance(raw, list) else raw.get("records", [])
                    for item in items:
                        fname = item.get("file") or Path(item.get("path", "")).name
                        if fname:
                            records[fname] = item
                except Exception:
                    pass

    return records


def run_organize(
    input_dir: Path,
    output_dir: Path,
    action: str = "copy",
    custom_meta: Path | None = None,
    custom_lib: Path | None = None,
    clean: bool = False,
    dry_run: bool = False,
    verbose: bool = False,
) -> None:
    if not input_dir.exists() or not input_dir.is_dir():
        print(f"[错误] 输入目录不存在: {input_dir}")
        sys.exit(1)

    print("=====================================================================")
    print("           Jigsaw 图片素材多通道通用按标签分类整理工具                 ")
    print("=====================================================================")
    print(f"输入源目录 (Input):   {input_dir.resolve()}")
    print(f"输出目标目录 (Output): {output_dir.resolve()}")
    print(f"文件处理动作 (Action): {action.upper()} {'[预览模式 - 不改写文件]' if dry_run else ''}")
    print("---------------------------------------------------------------------")

    # 1. 探测词库与元数据
    tag_subjs = load_subjects_from_library(custom_lib)
    if tag_subjs:
        print(f"[元数据] 成功挂载提示词库，包含 {sum(len(v) for v in tag_subjs.values())} 个词库主体映射。")

    records = load_metadata_store(input_dir, custom_meta)
    if records:
        print(f"[元数据] 成功加载 {len(records)} 条图片历史描述记录。")
    else:
        print("[元数据] 未探测到独立元数据文件，将通过 PNG 内嵌文本块及目录/文件名进行识别。")

    # 2. 递归扫描图片文件
    image_files: list[Path] = []
    for p in input_dir.rglob("*"):
        if p.is_file() and p.suffix.lower() in IMAGE_EXTENSIONS:
            # 忽略 _metadata 或其它带下划线隐藏文件夹
            if any(part.startswith("_") for part in p.parts[:-1]):
                continue
            image_files.append(p)

    image_files.sort()
    if not image_files:
        print(f"[警告] 源目录未扫描到图片文件 (支持: {', '.join(IMAGE_EXTENSIONS)})")
        return

    print(f"[扫描] 共发现待整理图片: {len(image_files)} 张。\n")

    # 3. 逐图分析归类
    plan: list[dict[str, Any]] = []
    stats_old_to_new: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    stats_target_counts: dict[str, int] = defaultdict(int)

    png_prompt_extracted = 0
    for img_path in image_files:
        # 获取其直接所属文件夹名称
        old_folder = img_path.parent.name
        fname = img_path.name

        prompt = ""
        rec = records.get(fname)
        if rec and rec.get("prompt"):
            prompt = str(rec.get("prompt"))
        elif HAS_PIL and img_path.suffix.lower() == ".png":
            embedded = extract_prompt_from_png(img_path)
            if embedded:
                prompt = embedded
                png_prompt_extracted += 1

        target_tag, reason = classify_image(fname, old_folder, prompt, tag_subjs)
        catalogs = TAG_TO_CATALOGS.get(target_tag, ["others"])
        primary_cat = catalogs[0] if catalogs else "others"

        dest_file = output_dir / target_tag / fname
        plan.append({
            "src": img_path,
            "dest": dest_file,
            "filename": fname,
            "old_folder": old_folder,
            "target_tag": target_tag,
            "catalog": primary_cat,
            "catalogs": catalogs,
            "reason": reason,
            "prompt": prompt,
        })
        stats_old_to_new[old_folder][target_tag] += 1
        stats_target_counts[target_tag] += 1

    if png_prompt_extracted:
        print(f"[分析] 从 PNG 图片自身内嵌元数据成功提取了 {png_prompt_extracted} 条提示词！")

    # 4. 打印分类分布预览
    print("---------------------------------------------------------------------")
    print(f"{'原分类目录':<18} -> {'归整后目标目录与数量分布'}")
    print("---------------------------------------------------------------------")
    refined_count = 0
    kept_count = 0
    for old_dir in sorted(stats_old_to_new.keys()):
        sub = stats_old_to_new[old_dir]
        total_sub = sum(sub.values())
        line_parts = []
        for new_tag, cnt in sorted(sub.items(), key=lambda x: -x[1]):
            if new_tag != old_dir:
                refined_count += cnt
                line_parts.append(f"{new_tag}:{cnt} (新标)")
            else:
                kept_count += cnt
                line_parts.append(f"{new_tag}:{cnt} (保留)")
        print(f"【{old_dir:<14}】({total_sub:>4}张) -> {', '.join(line_parts)}")

    print("---------------------------------------------------------------------")
    print(f"总计处理图片:   {len(plan)} 张")
    print(f"精准裂变新标:   {refined_count} 张 ({refined_count/len(plan)*100:.1f}%)")
    print(f"保留源目录名:   {kept_count} 张 ({kept_count/len(plan)*100:.1f}%)")
    print(f"产生目标分类数: {len(stats_target_counts)} 个子目录")
    print("---------------------------------------------------------------------\n")

    if dry_run:
        print("[Dry Run] 预览结束。如确认上述分类正确，去掉 --dry-run 参数即可执行。")
        return

    # 5. 执行物理文件操作
    if clean and output_dir.exists():
        print(f"[清理] 正在清空旧目标目录: {output_dir}...")
        shutil.rmtree(output_dir)

    output_dir.mkdir(parents=True, exist_ok=True)
    tags_records: list[dict[str, Any]] = []

    print(f"正在执行文件归整操作模式: [{action.upper()}]...")
    t0 = time.time()
    for idx, item in enumerate(plan, 1):
        target_folder = item["dest"].parent
        target_folder.mkdir(parents=True, exist_ok=True)

        src_p: Path = item["src"]
        dest_p: Path = item["dest"]

        if action == "move":
            shutil.move(src_p, dest_p)
        elif action == "link":
            try:
                if dest_p.exists():
                    dest_p.unlink()
                os.link(src_p, dest_p)
            except Exception:
                # 跨盘符硬链接失败时自动优雅降级为复制
                shutil.copy2(src_p, dest_p)
        else: # copy
            shutil.copy2(src_p, dest_p)

        # 构造用于打包工具的 tags.json 记录
        tags_records.append({
            "path": f"{item['target_tag']}/{item['filename']}",
            "file": item["filename"],
            "tag": item["target_tag"],
            "catalog": item["catalog"],
            "catalogs": item["catalogs"],
            "confidence": 0.95 if item["target_tag"] != item["old_folder"] else 0.85,
            "correctedTag": None,
            "review_required": False,
            "subject": "",
            "scene": "",
            "reason": item["reason"],
            "original_folder": item["old_folder"],
        })

        if verbose:
            print(f"[{idx}/{len(plan)}] {item['old_folder']}/{item['filename']} -> {item['target_tag']}/ ({item['reason']})")
        elif idx % 1000 == 0 or idx == len(plan):
            print(f"  进度: {idx}/{len(plan)} ({idx/len(plan)*100:.1f}%)...")

    elapsed = time.time() - t0
    print(f"文件处理完成！共处理 {len(plan)} 张，耗时: {elapsed:.2f} 秒。\n")

    # 6. 生成 tags.json 数据库
    tags_file = output_dir / "tags.json"
    tags_file.write_text(json.dumps(tags_records, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[落盘] 打包工具元数据写入成功: {tags_file} ({len(tags_records)} 条)")

    # 7. 若源目录有 _metadata，同步完整镜像
    meta_src = input_dir / "_metadata"
    if meta_src.exists() and meta_src.is_dir():
        meta_dest = output_dir / "_metadata"
        meta_dest.mkdir(exist_ok=True)
        for jf in meta_src.glob("*.jsonl"):
            try:
                shutil.copy2(jf, meta_dest / jf.name)
            except Exception:
                pass
        print(f"[落盘] 原始生图参数已镜像至: {meta_dest}")

    # 8. 生成人读分类报告
    report_file = output_dir / "_reorganize_report.txt"
    with report_file.open("w", encoding="utf-8") as f:
        f.write("=== Jigsaw 素材分类整理报告 ===\n\n")
        f.write(f"源目录:   {input_dir.resolve()}\n")
        f.write(f"目标目录: {output_dir.resolve()}\n")
        f.write(f"操作模式: {action.upper()}\n")
        f.write(f"总计图片: {len(plan)} 张\n")
        f.write(f"新标归类: {refined_count} 张 ({refined_count/len(plan)*100:.1f}%)\n")
        f.write(f"保持原标: {kept_count} 张 ({kept_count/len(plan)*100:.1f}%)\n")
        f.write(f"总子目录: {len(stats_target_counts)} 个\n\n")
        f.write("----------------------------------------------------\n")
        f.write(f"{'目标子目录':<20} {'数量':>8}\n")
        f.write("----------------------------------------------------\n")
        for tag, cnt in sorted(stats_target_counts.items(), key=lambda x: -x[1]):
            f.write(f"{tag:<20} {cnt:>8} 张\n")
        f.write("----------------------------------------------------\n\n")
        f.write("分类来源明细清单:\n")
        for old_dir in sorted(stats_old_to_new.keys()):
            sub = stats_old_to_new[old_dir]
            f.write(f"\n[{old_dir}] (共 {sum(sub.values())} 张):\n")
            for new_tag, cnt in sorted(sub.items(), key=lambda x: -x[1]):
                f.write(f"  -> {new_tag:<18} : {cnt} 张\n")

    print(f"[落盘] 详细分类报告已保存: {report_file}")
    print("\n[就绪] 您现在可以直接在目标目录中浏览筛选，或启动 Content Studio 进行审查：")
    print(f"  python scripts/packaging/server.py")
    print(f"  在网页端「源图片目录」填入: {output_dir.resolve()}")


def main() -> None:
    default_lib = PROJECT_ROOT / "scripts" / "my_prompt_library_v5.json"
    parser = argparse.ArgumentParser(
        description="Jigsaw 图片素材通用分类整理工具（按新 Tag 分子目录，无对应新 Tag 则严格保持源目录名）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  1. 预览任意目录的分类分布:
     python scripts/organize_images_by_tag.py -i "D:\\my_puzzles" --dry-run

  2. 极速整理（NTFS 硬链接，0 空间占用，极度推荐）:
     python scripts/organize_images_by_tag.py -i "C:\\Home\\Temp\\JigsawV5_full" -o "C:\\Home\\Temp\\JigsawV5_by_tag" --action link

  3. 复制到新目录并清理旧输出:
     python scripts/organize_images_by_tag.py -i "D:\\raw_images" -o "D:\\cleaned_tags" --action copy --clean
        """,
    )
    parser.add_argument(
        "-i", "--input", "--src",
        required=True,
        type=Path,
        help="输入源图片目录路径（必填）",
    )
    parser.add_argument(
        "-o", "--output", "--dest",
        default=None,
        type=Path,
        help="输出目标目录路径。若不填写，默认自动保存为 '<input>_by_tag'",
    )
    parser.add_argument(
        "--action",
        choices=["copy", "link", "move"],
        default="copy",
        help="文件处理模式: 'link' (NTFS硬链接，0磁盘开销瞬间完成，推荐), 'copy' (安全复制, 默认), 'move' (物理移动)",
    )
    parser.add_argument(
        "--metadata",
        default=None,
        type=Path,
        help="自定义元数据目录或文件路径（支持 _metadata 目录、.jsonl 或 tags.json；默认自动在源目录探测）",
    )
    parser.add_argument(
        "--library",
        default=default_lib if default_lib.exists() else None,
        type=Path,
        help="自定义生图词库 JSON 路径（默认自动寻找 scripts/my_prompt_library_v5.json）",
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        help="若输出目录已存在，在整理前彻底清空旧目录",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="仅预览分类映射统计结果，不执行任何实际文件操作",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="显示每张图片的详细移动与判定日志",
    )

    args = parser.parse_args()

    input_dir = args.input.resolve()
    if args.output:
        output_dir = args.output.resolve()
    else:
        output_dir = input_dir.parent / f"{input_dir.name}_by_tag"

    run_organize(
        input_dir=input_dir,
        output_dir=output_dir,
        action=args.action,
        custom_meta=args.metadata,
        custom_lib=args.library,
        clean=args.clean,
        dry_run=args.dry_run,
        verbose=args.verbose,
    )


if __name__ == "__main__":
    main()
