# Jigsaw Puzzle 分类标签体系单一事实源 (SSOT) 与代码生成架构方案

> **文档版本**：v1.0  
> **创建日期**：2026-09-04  
> **依据规范**：`docs/catalog-tags-mapping-specification.md` (v3.0 定稿版)  
> **核心目标**：建立全项目跨语言统一的单一数据事实源（SSOT），通过构建脚本自动生成 Dart/Python/JS 常量，消除多处硬编码导致的定义撕裂与代码漂移。

---

## 一、 现状分析与痛点

在目前的拼图工程中，标签体系（Taxonomy）经历了从「旧 21 Primary Tags」到「Catalog-Specific 双层映射」，再到「v3.0 14 主 Tags + 细分模式词库」的演进。

由于历史原因，各端代码散落维护着各自的标签定义：
1. **Flutter 客户端**（`lib/pages/tabs/home_tab_view.dart`）：
   - 硬编码了旧的 21 个标签（`kHomeTags`，包含 Cartoon, Space, Transportation, Seasons 等旧词）；
   - UI 底部抽屉排布为 22 项（含 All），无法对齐最新的 15 项（含 All）3 列 × 5 行黄金矩阵。
2. **素材打包与管理工具**（`scripts/packaging/server.py` & `index.html`）：
   - 包含旧的双层分类字典（`SPECIFIC_TAG_DEFS`, `CATALOG_TO_TAGS_MAP` 等历史遗留结构）。
3. **Studio 资产工作台**（`studio/taxonomy.py`）：
   - 已初步手写适配了 v3.0 的 14 个主 Tags 与正则推断规则，但属于 Python 侧单端维护，未能与 Flutter 和 Web 前端直接打通。
4. **AI 打标脚本**（`scripts/ai_tag_images.py`）：
   - 仍内置写死的 21 类标签提示词。

**痛点总结**：
手写维护多份代码常量，只要规范微调（如调整中文展示、新增正则推断词、修改排序），极易产生不同步。因此，必须确立**唯一数据事实源（Single Source of Truth, SSOT）**并配套**自动化代码生成工具（CodeGen）**。

---

## 二、 总体架构与流水线设计

```
                         ┌────────────────────────────────────────────────────────┐
                         │   规范说明书                                           │
                         │   docs/catalog-tags-mapping-specification.md           │
                         └──────────────────────────┬─────────────────────────────┘
                                                    │ 人工校准与定稿
                                                    ▼
                         ┌────────────────────────────────────────────────────────┐
                         │   【唯一数据源 SSOT】 (JSON 数据文件)                  │
                         │   data/taxonomy.json                                   │
                         └──────────────────────────┬─────────────────────────────┘
                                                    │
                                                    ▼ 运行构建生成器
                                      scripts/build_taxonomy.py
                                                    │
         ┌──────────────────────────────────────────┼──────────────────────────────────────────┐
         │                                          │                                          │
         ▼ (生成 Dart 常量)                         ▼ (生成 Python 核心模块)                   ▼ (生成 JS 静态配置)
lib/data/constants/puzzle_tags.dart         studio/taxonomy.py                         studio/static/js/taxonomy.js
  ├─ 14 个强类型常量 (kTagLandscapes)         ├─ MAIN_TAGS (14主类)                      ├─ window.TAXONOMY 静态对象
  ├─ kMainTags 完整元数据列表                ├─ TAG_PATTERNS 细分正则词库                └─ (Web 离线降级与开发辅助)
  ├─ kHomeTags 前台 15 项黄金矩阵           ├─ normalize_tag 归一化 API
  └─ PuzzleTagItem 强类型模型                └─ infer_tags_from_path 路径推断
         │                                          │                                          │
         ▼ 供消费端使用                             ▼ 供消费端使用                             ▼ 供消费端使用
Flutter App                                1. Studio Web Server                       Studio Web UI
  ├─ home_tab_view.dart (标签栏/弹窗)        2. 素材整理脚本 (organize_images)           ├─ /api/taxonomy 动态驱动
  └─ 数据模型与内容管道过滤                  3. 打包导出工具 (packaging)                └─ 离线单机运行支持
```

### 特别说明：AI 打标脚本（`ai_tag_images.py`）边界限定
- **现状保留**：`scripts/ai_tag_images.py` **本次不强制接入生成的大标签常量，暂时保持独立现状**。
- **业务原因**：视觉大模型（如 Qwen-VL）对宏观抽象概念（如 Cozy 温馨、Art 艺术、Fantasy 奇幻、Colors 缤纷、Others 其他）的语义边界把握较弱，直接给大模型输入宽泛大词容易导致分类模糊或幻觉；相反，AI 对具体的客观物理实体（如 cats, dogs, roses, cakes, castles 等）识别精度极高。
- **演进规划**：未来 AI 打标将专门接入 `tag_patterns` 细分词库作为实体候选集，识别出具体实体后再通过 SSOT 的 `normalize_tag()` 算法自动映射到 14 主 Tag 上。因此本次重构将其明确隔离开，避免大标签对 AI 识别造成干扰。

---

## 三、 SSOT 数据文件定义：`data/taxonomy.json`

数据文件采用标准的 JSON 格式，具备良好的跨语言原生解析能力与直观性。

### 字段 Schema 设计

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "version": "3.0.0",
  "updated_at": "2026-09-04",
  "specification_reference": "docs/catalog-tags-mapping-specification.md",
  "grid": {
    "columns": 3,
    "rows": 5,
    "total_slots": 15,
    "include_all": true
  },
  "main_tags": [
    {
      "id": "Landscapes",
      "name": "Landscapes",
      "zh": "风光",
      "icon": "🏔️",
      "category_type": "macro_subject",
      "description": "宏观地理、壮阔山川、浩瀚天象",
      "examples": ["雪山", "冰川湖泊", "江河瀑布", "海岸悬崖", "晚霞晨曦", "极光"],
      "grid_row": 1,
      "order": 1
    },
    {
      "id": "Nature",
      "name": "Nature",
      "zh": "自然",
      "icon": "🌲",
      "category_type": "macro_subject",
      "description": "植物生态、奇趣真菌、四季物候",
      "examples": ["观叶植物", "多肉仙人掌", "盆景", "荧光蘑菇", "苔藓", "四季节令"],
      "grid_row": 1,
      "order": 2
    },
    {
      "id": "Flowers",
      "name": "Flowers",
      "zh": "花卉",
      "icon": "🌸",
      "category_type": "objective_subject",
      "description": "浪漫名花、花海花艺、优雅园艺",
      "examples": ["玫瑰月季", "牡丹芍药", "郁金香", "向日葵", "插花花艺", "花园"],
      "grid_row": 2,
      "order": 3
    },
    {
      "id": "Animals",
      "name": "Animals",
      "zh": "动物",
      "icon": "🦁",
      "category_type": "objective_subject",
      "description": "野生生灵、飞禽鸟类、海洋水族",
      "examples": ["猛兽猛禽", "鸟类飞禽", "鲸豚海龟", "昆虫水族"],
      "grid_row": 2,
      "order": 4
    },
    {
      "id": "Pets",
      "name": "Pets",
      "zh": "宠物",
      "icon": "🐾",
      "category_type": "objective_subject",
      "description": "家庭伴侣萌宠、治愈生灵",
      "examples": ["猫咪名犬", "兔子仓鼠", "龙猫水豚", "金鱼观赏鸟"],
      "grid_row": 2,
      "order": 5
    },
    {
      "id": "Travel",
      "name": "Travel",
      "zh": "旅行",
      "icon": "✈️",
      "category_type": "objective_subject",
      "description": "城市天际线、名胜古迹、欧式古堡",
      "examples": ["世界名胜建筑", "都市街景", "欧式古堡宫殿", "水乡石桥小镇"],
      "grid_row": 3,
      "order": 6
    },
    {
      "id": "Vehicles",
      "name": "Vehicles",
      "zh": "交通",
      "icon": "🚂",
      "category_type": "objective_subject",
      "description": "交通载具、复古工业机械",
      "examples": ["老爷车超跑", "蒸汽火车", "古典帆船游轮", "飞机热气球"],
      "grid_row": 3,
      "order": 7
    },
    {
      "id": "Cozy",
      "name": "Cozy",
      "zh": "温馨",
      "icon": "☕",
      "category_type": "atmosphere",
      "description": "治愈慢生活、室内温暖角、复古手作",
      "examples": ["壁炉书房", "童话木屋", "编织手作", "黑胶打字机", "闲适阅读"],
      "grid_row": 3,
      "order": 8
    },
    {
      "id": "Food",
      "name": "Food",
      "zh": "美食",
      "icon": "🍰",
      "category_type": "objective_subject",
      "description": "烘焙甜点、环球料理、鲜果茶饮",
      "examples": ["西点蛋糕", "环球美食料理", "时蔬鲜果", "拿铁咖啡下午茶"],
      "grid_row": 4,
      "order": 9
    },
    {
      "id": "Art",
      "name": "Art",
      "zh": "艺术",
      "icon": "🎨",
      "category_type": "style",
      "description": "传世名画、唯美插画、二次元、国风",
      "examples": ["古典油画", "绘本水彩插画", "二次元动漫", "中国国风水墨"],
      "grid_row": 4,
      "order": 10
    },
    {
      "id": "Fantasy",
      "name": "Fantasy",
      "zh": "奇幻",
      "icon": "✨",
      "category_type": "imagination",
      "description": "魔法神兽、深空星系、占星图腾",
      "examples": ["神兽巨龙", "浮空仙境", "宇航员深空星云", "十二星座图腾"],
      "grid_row": 4,
      "order": 11
    },
    {
      "id": "Colors",
      "name": "Colors",
      "zh": "缤纷",
      "icon": "🌈",
      "category_type": "mechanism",
      "description": "曼陀罗图腾、平铺静物、彩虹渐变",
      "examples": ["对称万花筒", "器物平铺Flat-Lay", "彩虹高饱和色相", "抽象流体"],
      "grid_row": 5,
      "order": 12
    },
    {
      "id": "Holidays",
      "name": "Holidays",
      "zh": "节日",
      "icon": "🎉",
      "category_type": "festival",
      "description": "节庆假日、民俗庆典、仪式装扮",
      "examples": ["圣诞节彩灯礼物", "万圣节南瓜", "除夕春节", "感恩节复活节"],
      "grid_row": 5,
      "order": 13
    },
    {
      "id": "Others",
      "name": "Others",
      "zh": "其他",
      "icon": "📦",
      "category_type": "fallback",
      "description": "体育运动、无法归类的特殊小众素材",
      "examples": ["竞技体育", "无法归类的杂项素材兜底"],
      "grid_row": 5,
      "order": 14
    }
  ],
  "tag_patterns": {
    "Landscapes": [
      "landscape", "mountain", "peak", "canyon", "valley", "cliff", "scree",
      "forest", "wood", "bamboo", "jungle",
      "ocean", "sea\\b", "beach", "coast", "reef", "wave", "iceberg",
      "sunset", "sunrise", "dusk", "dawn", "twilight", "horizon",
      "waterfall", "lake", "river", "creek", "stream", "fjord",
      "desert", "dune", "aurora", "sky", "cloud", "rainbow"
    ],
    "Nature": [
      "nature", "botanical", "succulent", "cactus", "bonsai", "fern", "leaf", "foliage",
      "mushroom", "fungi", "toadstool", "moss", "lichen",
      "season", "spring\\b", "summer", "autumn", "fall\\b", "winter", "frost", "snow_scene"
    ],
    "Flowers": [
      "flower", "floral", "rose\\b", "roses\\b", "peony", "tulip", "sunflower",
      "hydrangea", "wisteria", "cherry_blossom", "lotus", "water_lily", "bouquet",
      "garden", "meadow", "greenhouse"
    ],
    "Animals": [
      "animal", "wildlife", "fauna", "mammal",
      "lion", "tiger", "leopard", "cheetah", "jaguar", "bear\\b", "polar_bear",
      "deer", "stag", "elk", "wolf", "fox\\b", "foxes\\b", "elephant", "giraffe", "zebra",
      "rhino", "hippo", "monkey", "panda", "sloth", "otter",
      "bird", "parrot", "macaw", "toucan", "owl", "eagle", "hawk",
      "swan", "flamingo", "peacock", "penguin", "hummingbird", "kingfisher",
      "sealife", "marine", "ocean_creature", "whale", "dolphin", "orca",
      "shark", "turtle", "sea_turtle", "jellyfish", "seahorse", "stingray", "octopus", "coral_fish",
      "insect", "butterfly", "dragonfly", "beetle", "chameleon", "tree_frog"
    ],
    "Pets": [
      "pet\\b", "pets\\b", "cat\\b", "cats\\b", "kitten", "kitty", "feline", "ragdoll", "british_shorthair",
      "dog\\b", "dogs\\b", "puppy", "puppies", "canine", "corgi", "shiba", "golden_retriever", "labrador",
      "poodle", "bulldog", "husky", "samoyed",
      "rabbit", "bunny", "bunnies", "hare\\b",
      "guinea_pig", "hamster", "chinchilla", "hedgehog", "capybara", "ferret",
      "goldfish", "betta", "aquarium", "budgie", "call_duck"
    ],
    "Travel": [
      "travel", "place", "trip", "tour",
      "cit(y|ies)", "urban", "skyline", "metropolis", "street", "alley", "canal", "night_view",
      "landmark", "monument", "eiffel", "taj_mahal", "colosseum", "pyramid", "big_ben",
      "castle", "palace", "chateau", "fortress", "manor",
      "village", "town", "old_town", "water_town", "cotswolds", "santorini",
      "architecture", "building", "bridge", "cathedral", "church", "temple", "shrine", "pagoda", "windmill", "lighthouse"
    ],
    "Vehicles": [
      "vehicle", "transport",
      "car\\b", "cars\\b", "automobile", "classic_car", "vintage_car", "sports_car", "camper", "van\\b", "motorcycle", "scooter", "truck",
      "train", "locomotive", "steam_train", "railway", "railroad", "tram", "metro",
      "ship\\b", "ships\\b", "boat", "sailboat", "tall_ship", "yacht", "cruise", "gondola", "canoe", "vessel",
      "aircraft", "airplane", "plane\\b", "planes\\b", "biplane", "balloon", "hot_air_balloon", "helicopter", "airship"
    ],
    "Cozy": [
      "cozy", "coziness", "cozyhome", "snug", "hygge",
      "interior", "room", "living_room", "bedroom", "study", "reading_nook", "windowsill", "balcony", "kitchen", "fireplace", "hearth", "bookshelf",
      "cottage", "cabin", "log_cabin", "chalet", "thatched",
      "lifestyle", "reading", "picnic", "slow_living", "tea_time", "people",
      "craft", "handicraft", "knitting", "yarn", "wool", "sewing", "embroidery", "patchwork", "pottery", "woodworking",
      "vintage", "retro", "nostalgia", "americana", "antique", "typewriter", "gramophone"
    ],
    "Food": [
      "food", "meal", "dish", "gourmet",
      "dessert", "sweet", "cake", "pastry", "bakery", "croissant", "bread",
      "macaron", "donut", "waffle", "pancake", "cookie", "pie\\b", "ice_cream", "chocolate",
      "cuisine", "sushi", "ramen", "pizza", "pasta", "steak", "dim_sum", "taco", "burger", "bbq",
      "fruit", "berry", "berries", "strawberry", "citrus", "lemon", "apple", "vegetable", "harvest",
      "drink", "beverage", "coffee", "coffeetea", "latte", "tea\\b", "afternoon_tea", "cocktail", "wine", "matcha"
    ],
    "Art": [
      "art\\b", "arts\\b", "fine_?art", "masterpiece", "museum",
      "painting", "oil_painting", "watercolor", "acrylic", "canvas", "impressionism", "van_gogh", "monet",
      "illustration", "storybook", "picture_book", "whimsical", "hand_drawn", "sketch",
      "anime", "manga", "cartoon", "chibi", "ghibli", "cel_shaded",
      "oriental", "asian_art", "chinese_painting", "gongbi", "ink_wash", "blue_green_landscape", "ukiyo_e"
    ],
    "Fantasy": [
      "fantasy", "fairy_tale", "enchanted",
      "mythical", "mythology", "dragon", "unicorn", "griffin", "phoenix", "kitsune", "pegasus", "mermaid", "fairy", "pixie", "elf", "elves",
      "magic", "wizard", "witch", "spell", "potion", "cauldron", "crystal_cave", "floating_island", "portal",
      "space", "universe", "cosmos", "galaxy", "galaxies", "nebula", "planet", "saturn", "earth", "moon", "astronaut", "spaceship", "space_station", "sci_fi",
      "zodiac", "astrology", "horoscope", "constellation", "tarot"
    ],
    "Colors": [
      "color", "colorful", "rainbow", "gradient", "vibrant_palette",
      "mandala", "kaleidoscope", "fractal", "symmetry", "stained_glass", "mosaic",
      "flat_?lay", "knolling", "collage", "assortment", "overhead_table",
      "abstract", "fluid_art", "acrylic_pour", "marble_texture", "pattern", "geometry"
    ],
    "Holidays": [
      "holiday", "festival", "celebration",
      "christmas", "xmas", "santa", "reindeer", "gingerbread",
      "halloween", "jack_o_lantern", "pumpkin",
      "easter", "easter_egg",
      "new_?year", "spring_festival", "chinese_new_year", "lunar_new_year", "lantern",
      "thanksgiving", "turkey", "valentine"
    ],
    "Others": [
      "\\bsports?\\b", "athletics?", "stadium", "skiing", "surfing", "soccer", "football",
      "\\bothers?\\b", "\\bmisc\\b"
    ]
  },
  "zh_alias_map": {
    "风光": "Landscapes", "风景": "Landscapes", "雪山": "Landscapes", "山峦": "Landscapes", "湖泊": "Landscapes",
    "森林": "Landscapes", "海洋": "Landscapes", "海滩": "Landscapes", "日落": "Landscapes", "晚霞": "Landscapes",
    "自然": "Nature", "植物": "Nature", "多肉": "Nature", "绿植": "Nature", "蘑菇": "Nature", "真菌": "Nature", "四季": "Nature",
    "花卉": "Flowers", "花朵": "Flowers", "花园": "Flowers", "花海": "Flowers", "插花": "Flowers", "玫瑰": "Flowers", "牡丹": "Flowers", "郁金香": "Flowers",
    "动物": "Animals", "野生动物": "Animals", "野兽": "Animals", "鸟类": "Animals", "飞禽": "Animals", "海洋水族": "Animals", "水族": "Animals",
    "宠物": "Pets", "萌宠": "Pets", "猫咪": "Pets", "猫": "Pets", "狗狗": "Pets", "狗": "Pets", "兔子": "Pets", "仓鼠": "Pets", "荷兰猪": "Pets",
    "旅行": "Travel", "城市": "Travel", "建筑": "Travel", "地标": "Travel", "古堡": "Travel", "城堡": "Travel", "小镇": "Travel", "古镇": "Travel", "街景": "Travel",
    "交通": "Vehicles", "机械": "Vehicles", "汽车": "Vehicles", "跑车": "Vehicles", "火车": "Vehicles", "列车": "Vehicles", "船舶": "Vehicles", "帆船": "Vehicles", "飞机": "Vehicles",
    "温馨": "Cozy", "生活": "Cozy", "室内": "Cozy", "木屋": "Cozy", "手作": "Cozy", "复古": "Cozy", "日常": "Cozy",
    "美食": "Food", "料理": "Food", "甜品": "Food", "甜点": "Food", "烘焙": "Food", "蛋糕": "Food", "水果": "Food", "咖啡": "Food", "茶饮": "Food",
    "艺术": "Art", "名画": "Art", "油画": "Art", "插画": "Art", "绘本": "Art", "动漫": "Art", "二次元": "Art", "国风": "Art", "水墨": "Art",
    "奇幻": "Fantasy", "科幻": "Fantasy", "神兽": "Fantasy", "巨龙": "Fantasy", "魔法": "Fantasy", "太空": "Fantasy", "星云": "Fantasy", "星座": "Fantasy",
    "缤纷": "Colors", "色彩": "Colors", "曼陀罗": "Colors", "平铺": "Colors", "色块": "Colors", "抽象": "Colors",
    "节日": "Holidays", "节庆": "Holidays", "圣诞": "Holidays", "万圣": "Holidays", "复活节": "Holidays", "春节": "Holidays", "新年": "Holidays",
    "其他": "Others", "运动": "Others", "体育": "Others"
  },
  "legacy_map": {
    "cat_nature": "Nature",
    "cat_animals": "Animals",
    "cat_pets": "Pets",
    "cat_colors": "Colors",
    "cat_flowers": "Flowers",
    "cat_cozy": "Cozy",
    "cat_travel": "Travel",
    "cat_vehicles": "Vehicles",
    "cat_food": "Food",
    "cat_art": "Art",
    "cat_fantasy": "Fantasy",
    "cat_holidays": "Holidays",
    "cat_landscapes": "Landscapes",
    "cat_others": "Others"
  }
}
```

---

## 四、 构建脚本与代码生成规范

### 1. 构建脚本职责：`scripts/build_taxonomy.py`
构建脚本负责执行以下流水线：
1. **数据健全性校验**：
   - 校验主标签数量严格等于 14 个；
   - 校验每个主标签必须具备 `id`, `name`, `zh`, `icon`, `grid_row`, `order`；
   - 校验 `tag_patterns` 中包含所有 14 个主标签的 Key；
   - 校验所有正则表达式语法有效性（尝试 `re.compile`，杜绝非法正则）。
2. **多语言产物生成**：
   - 输出 Dart 文件：`lib/data/constants/puzzle_tags.dart`；
   - 输出 Python 文件：`studio/taxonomy.py`；
   - 输出 JS 文件：`studio/static/js/taxonomy.js`。
3. **安全原子写入**：
   - 写入临时文件校验后原子替换，打印详细的生成报告与行数统计。

---

### 2. 产物一：Flutter / Dart 代码规范 (`puzzle_tags.dart`)

生成于 `lib/data/constants/puzzle_tags.dart`：

```dart
// Generated by scripts/build_taxonomy.py. DO NOT EDIT DIRECTLY.
// Source: data/taxonomy.json (v3.0.0, 2026-09-04)

import 'package:flutter/foundation.dart';

@immutable
class PuzzleTagItem {
  final String id;
  final String name;
  final String zh;
  final String icon;
  final String categoryType;
  final String description;
  final int gridRow;
  final int order;

  const PuzzleTagItem({
    required this.id,
    required this.name,
    required this.zh,
    required this.icon,
    required this.categoryType,
    required this.description,
    required this.gridRow,
    required this.order,
  });
}

// 14 个独立静态常量（供代码中防手误引用）
const String kTagLandscapes = 'Landscapes';
const String kTagNature = 'Nature';
const String kTagFlowers = 'Flowers';
const String kTagAnimals = 'Animals';
const String kTagPets = 'Pets';
const String kTagTravel = 'Travel';
const String kTagVehicles = 'Vehicles';
const String kTagCozy = 'Cozy';
const String kTagFood = 'Food';
const String kTagArt = 'Art';
const String kTagFantasy = 'Fantasy';
const String kTagColors = 'Colors';
const String kTagHolidays = 'Holidays';
const String kTagOthers = 'Others';

// 14 主 Tags 列表
const List<PuzzleTagItem> kMainTags = [
  PuzzleTagItem(
    id: 'Landscapes',
    name: 'Landscapes',
    zh: '风光',
    icon: '🏔️',
    categoryType: 'macro_subject',
    description: '宏观地理、壮阔山川、浩瀚天象',
    gridRow: 1,
    order: 1,
  ),
  // ... 其余 13 项
];

// 前台 UI 专用 15 项黄金矩阵列表（14 主 Tag + 1 All，完美对齐 3 列 × 5 行网格）
const List<Map<String, String>> kHomeTags = [
  {'id': 'all', 'label': '全部', 'icon': '🧩'},
  {'id': 'Landscapes', 'label': '风光', 'icon': '🏔️'},
  {'id': 'Nature', 'label': '自然', 'icon': '🌲'},
  {'id': 'Flowers', 'label': '花卉', 'icon': '🌸'},
  {'id': 'Animals', 'label': '动物', 'icon': '🦁'},
  {'id': 'Pets', 'label': '宠物', 'icon': '🐾'},
  {'id': 'Travel', 'label': '旅行', 'icon': '✈️'},
  {'id': 'Vehicles', 'label': '交通', 'icon': '🚂'},
  {'id': 'Cozy', 'label': '温馨', 'icon': '☕'},
  {'id': 'Food', 'label': '美食', 'icon': '🍰'},
  {'id': 'Art', 'label': '艺术', 'icon': '🎨'},
  {'id': 'Fantasy', 'label': '奇幻', 'icon': '✨'},
  {'id': 'Colors', 'label': '缤纷', 'icon': '🌈'},
  {'id': 'Holidays', 'label': '节日', 'icon': '🎉'},
  {'id': 'Others', 'label': '其他', 'icon': '📦'},
];

// 中文转 ID 速查表
const Map<String, String> kTagZhToId = {
  '风光': 'Landscapes',
  '自然': 'Nature',
  // ...
};
```

---

### 3. 产物二：Python 模块规范 (`studio/taxonomy.py`)

生成于 `studio/taxonomy.py`，保留高效的标准 API：

```python
# Generated by scripts/build_taxonomy.py. DO NOT EDIT DIRECTLY.
# Source: data/taxonomy.json (v3.0.0, 2026-09-04)

from __future__ import annotations
import re
from pathlib import Path
from typing import Any

MAIN_TAGS: list[dict[str, Any]] = [ ... ]
MAIN_TAG_IDS: list[str] = [t["id"] for t in MAIN_TAGS]
TAG_ZH: dict[str, str] = {t["id"]: t["zh"] for t in MAIN_TAGS}
TAG_PATTERNS: dict[str, list[str]] = { ... }
ZH_ALIAS_MAP: dict[str, str] = { ... }
LEGACY_CAT_MAP: dict[str, str] = { ... }

# 预编译正则对象
COMPILED_PATTERNS: dict[str, list[re.Pattern]] = {
    tag: [re.compile(p, re.IGNORECASE) for p in patterns]
    for tag, patterns in TAG_PATTERNS.items()
}

def get_main_tags() -> list[dict[str, Any]]: ...
def normalize_tag(tag: str | None) -> str: ...
def normalize_tags(tags: list[str] | None) -> list[str]: ...
def infer_tags_from_path(path: str | Path, root: Path | None = None) -> list[str]: ...
def suggest_tags_for_image(filename: str, parent_dirs: list[str] | None = None) -> list[str]: ...

# 历史调用向下兼容
ALL_CANONICAL_TAGS = MAIN_TAG_IDS
CATALOG_DEFS = MAIN_TAGS
SPECIFIC_TAG_DEFS = MAIN_TAGS
CATALOG_TO_TAGS_MAP = {t["id"]: [t["id"]] for t in MAIN_TAGS}
TAG_TO_CATALOGS = {t["id"]: [t["id"]] for t in MAIN_TAGS}
normalize_token = normalize_tag
guess_tags_from_path = infer_tags_from_path
get_catalogs_for_tags = normalize_tags
```

---

### 4. 产物三：Web / JS 常量规范 (`studio/static/js/taxonomy.js`)

生成于 `studio/static/js/taxonomy.js`：

```javascript
// Generated by scripts/build_taxonomy.py. DO NOT EDIT DIRECTLY.
// Source: data/taxonomy.json (v3.0.0, 2026-09-04)

(function (global) {
  const TAXONOMY = {
    version: "3.0.0",
    main_tags: [ /* 14 项完整数组 */ ],
    grid: { columns: 3, rows: 5, total_slots: 15 },
    tag_zh: { "Landscapes": "风光", ... },
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = TAXONOMY;
  } else {
    global.TAXONOMY = TAXONOMY;
  }
})(typeof window !== "undefined" ? window : globalThis);
```

---

## 五、 消费端业务代码对接与改造清单

| 模块/文件 | 当前状态 | 改造方案 |
| :--- | :--- | :--- |
| `lib/pages/tabs/home_tab_view.dart` | 手写 21 旧标签 | 移除 `kHomeTags` 常量定义，直接 `import 'package:jigsaw_puzzle/data/constants/puzzle_tags.dart'`，使用生成的 15 项 `kHomeTags`；3 列网格完美填满 15 格。 |
| `studio/server.py` | 依赖手写 `studio.taxonomy` | 保持导入，数据源自动切换为生成的最新常量，`/api/taxonomy` 接口数据零偏差。 |
| `studio/static/js/app.js` | 从 `/api/taxonomy` 获取 | 保持现状（前端已实现零硬编码动态读取），可在 `index.html` 中引入 `taxonomy.js` 作为网络异常或离线本地降级。 |
| `scripts/organize_images_by_tag.py` | 内置旧 31 类标签匹配 | 改造为从 `studio.taxonomy` 导入 `MAIN_TAG_IDS`, `TAG_PATTERNS`, `infer_tags_from_path`，实现图库素材智能归集。 |
| `scripts/packaging/server.py` & `index.html` | 包含旧分类与特定标签 | 统一接入 `studio.taxonomy`，清理废弃的 `SPECIFIC_TAG_DEFS`。 |
| `scripts/ai_tag_images.py` | **保持现状** | **本次不动**。文档已注明 AI 打标适合细分实体词模式，后续再规划接入细分 pattern 字典。 |

---

## 六、 实施步骤与验收验证

### 实施路线
1. **第一阶段：固化 SSOT 数据源**
   - 新建 `data/taxonomy.json`，完整录入 14 主 Tags、tag_patterns、别名速查表与历史兼容映射。
2. **第二阶段：开发构建生成脚本**
   - 编写 `scripts/build_taxonomy.py`，实现 Schema 校验与 Dart/Python/JS 三端生成器；
   - 运行脚本，生成 `lib/data/constants/puzzle_tags.dart`、`studio/taxonomy.py`、`studio/static/js/taxonomy.js`。
3. **第三阶段：消费端平滑切换**
   - 更新 `lib/pages/tabs/home_tab_view.dart`，切换至新常量；
   - 适配 `scripts/packaging/server.py` 等工具模块。
4. **第四阶段：质量与编译验证**
   - 运行 `flutter analyze` 确保无代码警告；
   - 运行 `flutter test` 确保业务逻辑与组件测试通过；
   - 运行 `flutter build windows --debug` 验证整体编译成功。
