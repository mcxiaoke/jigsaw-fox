# Jigsaw Puzzle 分类与标签规范说明书 (v3.0 定稿版)

> **版本**：v3.0 Final (2026-09-04)  
> **体系架构**：统一精炼 14 主 Tags（前台展示/多选打标） + 无限细分词库（后台自动识别与运营手册）  
> **UI 矩阵**：前台展示 14 主 Tags + 1 "All(全部)" = **15 项黄金矩阵（3 列 × 5 行完美网格）**  
> **数据结构**：完全兼容现有代码（`LevelItem.tags: List<String>` 与 `tags.json` 格式零破坏迁移）  

---

## 一、 架构演进与设计原则

经过对全球拼图市场多源调研数据（`temp/reports/`）、46 个存量真实图库目录（24,592 张图片）实测分析，我们对早期繁复的“Catalog - Tags 双层映射系统”进行了终极重构与升华：

1. **化繁为简，消除认知撕裂**：
   - 过去强行区分 Catalog 与 Specific Tags 导致前后台概念不一致。现全系统统一称为 **`Tag`**。
   - 存储字段、数据库与 `tags.json` 保持 `tags: ["Animals", "Cozy"]` 字符串数组结构，无需改动任何基础数据模型。
2. **多选打标，天然实现多维流通**：
   - 承认拼图内容存在**「物理主体」**与**「情感氛围/画风载体」**双重视角；
   - 打标时直接**多选主 Tag**（推荐 1 个主体 + 1 个氛围/画风）。例如“壁炉前的猫”同时勾选 `Pets` 与 `Cozy`，使图片在两个频道均自然曝光，彻底消灭“二选一”分类内耗。
3. **主次分明，细分词库退居幕后**：
   - 前台 UI 与打标面板**只展示 14 个高频主 Tags**；
   - 细分标签（如 cats, rabbits, castles, coffee, mandalas, zodiac 等）不再设数量限制，统一定义为后台模式匹配词库（`tag_patterns`），专门用于**智能识别素材目录名、推断历史数据以及作为运营选品指南**。
4. **黄金排布，极致的视觉体验**：
   - 14 个主 Tags + 1 个 "All (全部)" = **15 项**；
   - 在手机端底部抽屉（BottomSheet）或筛选面板中，刚好排成 **3 列 × 5 行** 完美对称矩阵，没有任何空缺与悬挂项。

---

## 二、 核心 14 主 Tags（前台 UI 与打标展示层）

在 App 首页导航与筛选面板中的 15 项（含全部）3×5 黄金排布：

```
┌───────────────────┬───────────────────┬───────────────────┐
│     All (全部)    │  Landscapes (风光)│   Nature (自然)   │  <- R1: 大视野与大自然
├───────────────────┼───────────────────┼───────────────────┤
│   Flowers (花卉)  │   Animals (动物)  │    Pets (宠物)    │  <- R2: 花卉与两大生命题材
├───────────────────┼───────────────────┼───────────────────┤
│    Travel (旅行)  │  Vehicles (交通)  │    Cozy (温馨)    │  <- R3: 人文探索、机械与治愈生活
├───────────────────┼───────────────────┼───────────────────┤
│     Food (美食)   │     Art (艺术)    │   Fantasy (奇幻)  │  <- R4: 味觉、视觉与幻想世界
├───────────────────┼───────────────────┼───────────────────┤
│    Colors (缤纷)  │  Holidays (节日)  │   Others (其他)   │  <- R5: 机制图腾、节庆与兜底
└───────────────────┴───────────────────┴───────────────────┘
```

### 主 Tags 详细定义与覆盖范围表

| 行号 | Tag ID (代码值) | 中文名 | 阵营属性 | 核心定位与视觉基调 | 典型覆盖场景与画面实体 |
| :---: | :--- | :--- | :---: | :--- | :--- |
| **R1** | **`Landscapes`** | **风光** | 宏观主体 | 宏观地理、壮阔山川、浩瀚天象 | 雪山、冰川湖泊、江河瀑布、原始森林大景、海岸悬崖、热带沙滩、晚霞暮光、日出晨曦、极光天象 |
| **R1** | **`Nature`** | **自然** | 宏观主体 | 植物生态、奇趣真菌、四季物候 | 绿色观叶植物、多肉仙人掌、盆景蕨类、森林奇趣荧光真菌/蘑菇、苔藓地衣、四季节令（春生夏长秋收冬雪物候） |
| **R2** | **`Flowers`** | **花卉** | 客观主体 | 浪漫名花、花海花艺、优雅园艺 | 玫瑰月季、牡丹芍药、郁金香、向日葵、绣球紫藤、樱花花道、田园花海、桌面精致插花、花艺花房（实测图库 No.1 大类） |
| **R2** | **`Animals`** | **动物** | 客观主体 | 野生生灵、飞禽鸟类、海洋水族 | 陆地野生猛兽（狮虎豹狼狐、鹿熊象猴）、飞禽鸟类（金刚鹦鹉、巨嘴鸟、猫头鹰、天鹅白鹭）、海洋水族（蓝鲸海豚海龟热带鱼） |
| **R2** | **`Pets`** | **宠物** | 客观主体 | 家庭伴侣萌宠、治愈生灵 | 猫咪（各类家猫/品种猫）、狗狗（金毛/柯基/柴犬等名犬）、兔子、荷兰猪/豚鼠、仓鼠、龙猫、水豚、小鸭芦丁鸡等家庭萌宠 |
| **R3** | **`Travel`** | **旅行** | 客观主体 | 城市天际线、名胜古迹、欧式古堡 | 世界知名地标建筑（铁塔/泰姬陵/斗兽场/大本钟）、都市街景天际线、欧式中世纪古堡宫殿、石头乡村小镇、水乡古镇 |
| **R3** | **`Vehicles`** | **交通** | 客观主体 | 交通载具、复古工业机械 | 经典复古汽车、老爷车、现代超跑机车、蒸汽列车、观光火车铁轨、古典多桅大帆船、豪华游轮游艇、老式双翼飞机、热气球群 |
| **R3** | **`Cozy`** | **温馨** | 情感氛围 | 治愈慢生活、室内温暖角、复古手作 | 室内壁炉暖房、阳光书房飘窗、童话小木屋、闲适阅读野餐、毛线编织缝纫、老式打字机黑胶唱机、复古杂货铺、日常慢调人物 |
| **R4** | **`Food`** | **美食** | 客观主体 | 烘焙甜点、环球料理、鲜果茶饮 | 法式蛋糕西点、面包烘焙、马卡龙冰淇淋、寿司拉面披萨料理、热带鲜果时蔬拼盘、拿铁拉花咖啡、英式下午茶、夏日特调鸡尾酒 |
| **R4** | **`Art`** | **艺术** | 画风载体 | 传世名画、唯美插画、二次元、国风 | 大师古典油画名作（梵高/莫奈等）、治愈水彩故事绘本插画、动漫二次元赛璐璐（吉卜力风）、中国工笔花鸟青绿山水传统艺术 |
| **R4** | **`Fantasy`** | **奇幻** | 想象世界 | 魔法神兽、深空星系、占星图腾 | 西方巨龙独角兽、浮空岛魔法城堡仙境、炼金水晶、舱外宇航员深空星云天体行星、十二星座守护兽与神秘学图腾 |
| **R5** | **`Colors`** | **缤纷** | 机制载体 | 曼陀罗图腾、平铺静物、彩虹渐变 | 对称万花筒曼陀罗花窗、器物平铺整齐陈列（Flat-Lay）、彩虹高饱和色相矩阵、丙烯流体画、大理石裂纹现代抽象 |
| **R5** | **`Holidays`** | **节日** | 节庆仪式 | 节庆假日、民俗庆典、仪式装扮 | 圣诞树彩灯礼物盒、万圣节南瓜灯糖果、复活节彩蛋、除夕春节灯笼烟花年夜饭、感恩节烤火鸡等仪式场景 |
| **R5** | **`Others`** | **其他** | 系统兜底 | 体育运动、无法归类的特殊小众素材 | 滑雪、足球、冲浪等各项体育竞技活动；无法明确归入上述 13 类的杂项素材 |

---

## 三、 细分词库与目录智能推断规则（`tag_patterns`）

细分词库不限制条数，作为后台算法与运营百科全书。当脚本扫描目录或解析文本时，若命中以下模式正则（大小写不敏感），将**自动归一化推断为主 Tag**：

```python
TAG_PATTERNS = {
    # 1. Landscapes (风光)
    "Landscapes": [
        r"landscape", r"mountain", r"peak", r"canyon", r"valley", r"cliff", r"scree",
        r"forest", r"wood", r"bamboo", r"jungle",
        r"ocean", r"sea", r"beach", r"coast", r"reef", r"wave", r"iceberg",
        r"sunset", r"sunrise", r"dusk", r"dawn", r"twilight", r"horizon",
        r"waterfall", r"lake", r"river", r"creek", r"stream", r"fjord",
        r"desert", r"dune", r"aurora", r"sky", r"cloud", r"rainbow"
    ],

    # 2. Nature (自然)
    "Nature": [
        r"nature", r"botanical", r"succulent", r"cactus", r"bonsai", r"fern", r"leaf", r"foliage",
        r"mushroom", r"fungi", r"toadstool", r"moss", r"lichen",
        r"season", r"spring", r"summer", r"autumn", r"fall", r"winter", r"frost", r"snow_scene"
    ],

    # 3. Flowers (花卉)
    "Flowers": [
        r"flower", r"floral", r"rose", r"peony", r"tulip", r"sunflower", 
        r"hydrangea", r"wisteria", r"cherry_blossom", r"lotus", r"water_lily", r"bouquet",
        r"garden", r"meadow", r"greenhouse"
    ],

    # 4. Animals (野生动物与鸟类水族)
    "Animals": [
        r"animal", r"wildlife", r"fauna", r"mammal",
        r"lion", r"tiger", r"leopard", r"cheetah", r"jaguar", r"bear", r"polar_bear",
        r"deer", r"stag", r"elk", r"wolf", r"fox", r"elephant", r"giraffe", r"zebra", 
        r"rhino", r"hippo", r"monkey", r"panda", r"sloth", r"otter",
        r"bird", r"parrot", r"macaw", r"toucan", r"owl", r"eagle", r"hawk", 
        r"swan", r"flamingo", r"peacock", r"penguin", r"hummingbird", r"kingfisher",
        r"sealife", r"marine", r"ocean_creature", r"whale", r"dolphin", r"orca",
        r"shark", r"turtle", r"sea_turtle", r"jellyfish", r"seahorse", r"stingray", r"octopus", r"coral_fish",
        r"insect", r"butterfly", r"dragonfly", r"beetle", r"chameleon", r"tree_frog"
    ],

    # 5. Pets (家庭宠物)
    "Pets": [
        r"pet", r"cat", r"kitten", r"kitty", r"feline", r"ragdoll", r"british_shorthair",
        r"dog", r"puppy", r"canine", r"corgi", r"shiba", r"golden_retriever", r"labrador", 
        r"poodle", r"bulldog", r"husky", r"samoyed",
        r"rabbit", r"bunny", r"hare",
        r"guinea_pig", r"hamster", r"chinchilla", r"hedgehog", r"capybara", r"ferret",
        r"goldfish", r"betta", r"aquarium", r"budgie", r"call_duck"
    ],

    # 6. Travel (城市旅行与建筑)
    "Travel": [
        r"travel", r"place", r"trip", r"tour",
        r"cit(y|ies)", r"urban", r"skyline", r"metropolis", r"street", r"alley", r"canal", r"night_view",
        r"landmark", r"monument", r"eiffel", r"taj_mahal", r"colosseum", r"pyramid", r"big_ben",
        r"castle", r"palace", r"chateau", r"fortress", r"manor",
        r"village", r"town", r"old_town", r"water_town", r"cotswolds", r"santorini",
        r"architecture", r"building", r"bridge", r"cathedral", r"church", r"temple", r"shrine", r"pagoda", r"windmill", r"lighthouse"
    ],

    # 7. Vehicles (交通机械)
    "Vehicles": [
        r"vehicle", r"transport",
        r"car", r"automobile", r"classic_car", r"vintage_car", r"sports_car", r"camper", r"van", r"motorcycle", r"scooter", r"truck",
        r"train", r"locomotive", r"steam_train", r"railway", r"railroad", r"tram", r"metro",
        r"ship", r"boat", r"sailboat", r"tall_ship", r"yacht", r"cruise", r"gondola", r"canoe", r"vessel",
        r"aircraft", r"airplane", r"plane", r"biplane", r"balloon", r"hot_air_balloon", r"helicopter", r"airship"
    ],

    # 8. Cozy (温馨生活日常)
    "Cozy": [
        r"cozy", r"coziness", r"cozyhome", r"snug", r"hygge",
        r"interior", r"room", r"living_room", r"bedroom", r"study", r"reading_nook", r"windowsill", r"balcony", r"kitchen", r"fireplace", r"hearth", r"bookshelf",
        r"cottage", r"cabin", r"log_cabin", r"chalet", r"thatched",
        r"lifestyle", r"reading", r"picnic", r"slow_living", r"tea_time", r"people",
        r"craft", r"handicraft", r"knitting", r"yarn", r"wool", r"sewing", r"embroidery", r"patchwork", r"pottery", r"woodworking",
        r"vintage", r"retro", r"nostalgia", r"americana", r"antique", r"typewriter", r"gramophone"
    ],

    # 9. Food (美食饮品)
    "Food": [
        r"food", r"meal", r"dish", r"gourmet",
        r"dessert", r"sweet", r"cake", r"pastry", r"bakery", r"croissant", r"bread", 
        r"macaron", r"donut", r"waffle", r"pancake", r"cookie", r"pie", r"ice_cream", r"chocolate",
        r"cuisine", r"sushi", r"ramen", r"pizza", r"pasta", r"steak", r"dim_sum", r"taco", r"burger", r"bbq",
        r"fruit", r"berry", r"strawberry", r"citrus", r"lemon", r"apple", r"vegetable", r"harvest",
        r"drink", r"beverage", r"coffee", r"latte", r"tea", r"afternoon_tea", r"cocktail", r"wine", r"matcha"
    ],

    # 10. Art (艺术画作)
    "Art": [
        r"art\b", r"arts\b", r"fine_?art", r"masterpiece", r"museum",
        r"painting", r"oil_painting", r"watercolor", r"acrylic", r"canvas", r"impressionism", r"van_gogh", r"monet",
        r"illustration", r"storybook", r"picture_book", r"whimsical", r"hand_drawn", r"sketch",
        r"anime", r"manga", r"cartoon", r"chibi", r"ghibli", r"cel_shaded",
        r"oriental", r"asian_art", r"chinese_painting", r"gongbi", r"ink_wash", r"blue_green_landscape", r"ukiyo_e"
    ],

    # 11. Fantasy (奇幻科幻)
    "Fantasy": [
        r"fantasy", r"fairy_tale", r"enchanted",
        r"mythical", r"mythology", r"dragon", r"unicorn", r"griffin", r"phoenix", r"kitsune", r"pegasus", r"mermaid", r"fairy", r"pixie", r"elf", r"elves",
        r"magic", r"wizard", r"witch", r"spell", r"potion", r"cauldron", r"crystal_cave", r"floating_island", r"portal",
        r"space", r"universe", r"cosmos", r"galaxy", r"nebula", r"planet", r"saturn", r"earth", r"moon", r"astronaut", r"spaceship", r"space_station", r"sci_fi",
        r"zodiac", r"astrology", r"horoscope", r"constellation", r"tarot"
    ],

    # 12. Colors (缤纷图腾)
    "Colors": [
        r"color", r"colorful", r"rainbow", r"gradient", r"vibrant_palette",
        r"mandala", r"kaleidoscope", r"fractal", r"symmetry", r"stained_glass", r"mosaic",
        r"flat_?lay", r"knolling", r"collage", r"assortment", r"overhead_table",
        r"abstract", r"fluid_art", r"acrylic_pour", r"marble_texture", r"pattern", r"geometry"
    ],

    # 13. Holidays (节日庆典)
    "Holidays": [
        r"holiday", r"festival", r"celebration",
        r"christmas", r"xmas", r"santa", r"reindeer", r"gingerbread",
        r"halloween", r"jack_o_lantern", r"pumpkin",
        r"easter", r"easter_egg",
        r"new_?year", r"spring_festival", r"chinese_new_year", r"lunar_new_year", r"lantern",
        r"thanksgiving", r"turkey", r"valentine"
    ],

    # 14. Others (其他兜底)
    "Others": [
        r"\bsports?\b", r"athletics?", r"stadium", r"skiing", r"surfing", r"soccer", r"football",
        r"\bothers?\b", r"\bmisc\b"
    ]
}
```

---

## 四、 真实图库目录识别印证矩阵（46 目录 100% 验证）

针对真实目录 `C:\Home\Temp\Jigsaw_Organized`（共 24,592 张图片）进行全量推断映射：

| 原始素材目录 | 识别主 Tag | 原始素材目录 | 识别主 Tag | 原始素材目录 | 识别主 Tag |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `Flowers` (1449) | **Flowers** | `Forests` (388) | **Landscapes** | `CoffeeTea` (210) | **Food** |
| `Animals` (1376) | **Animals** | `Sunsets` (107) | **Landscapes** | `Crafts` (160) | **Cozy** |
| `Architecture` (1268) | **Travel** | `Nature` (875) | **Nature** | `FineArt` (156) | **Art** |
| `Food` (1171) | **Food** | `Botanical` (18) | **Nature** | `Villages` (119) | **Travel** |
| `Birds` (1052) | **Animals** | `Seasons` (731) | **Nature** | `Christmas` (110) | **Holidays** |
| `Transportation` (959)| **Vehicles** | `Cats` (345) | **Pets** | `Halloween` (108) | **Holidays** |
| `Illustration` (930) | **Art** | `Dogs` (365) | **Pets** | `Colors` (106) | **Colors** |
| `Cities` (927) | **Travel** | `Pets` (792) | **Pets** | `Mandala` (48) | **Colors** |
| `Fantasy` (883) | **Fantasy** | `Wildlife` (846) | **Animals** | `Oriental` (42) | **Art** |
| `Landscapes` (843) | **Landscapes** | `SeaLife` (563) | **Animals** | `CozyHome` (15) | **Cozy** |
| `Space` (796) | **Fantasy** | `Vintage` (528) | **Cozy** | `FlatLay` (15) | **Colors** |
| `People` (691) | **Cozy** | `Landmarks` (510) | **Travel** | `Zodiac` (14) | **Fantasy** |
| `Art` (636) | **Art** | `Sweets` (499) | **Food** | `Sports` (380) | **Others** |
| `Abstract` (591) | **Colors** | `Mountains` (403)| **Landscapes** | `Others` (953) | **Others** |
| `Ocean` (554) | **Landscapes** | `Castles` (277) | **Travel** | - | - |
| `Holidays` (541) | **Holidays** | `Mythical` (242) | **Fantasy** | - | - |

---

## 五、 打标实操指引（运营与标注人员）

1. **推荐模式：1 个核心主体 + 1 个氛围/画风载体**
   - 画面中主体鲜明，同时具备某种艺术或生活氛围时，直接同时勾选两个 Tag。
   - 例：“窗台前抱毛线团的猫咪” → 勾选 `['Pets', 'Cozy']`；
   - 例：“新海诚动漫风樱花车站与列车” → 勾选 `['Art', 'Vehicles', 'Nature']`；
   - 例：“悬崖雪山上的新天鹅堡” → 勾选 `['Travel', 'Landscapes']`。
2. **纯粹主体或纯粹形式：单选 1 个 Tag**
   - 纯野生狮子特写 → 只勾选 `['Animals']`；
   - 纯几何万花筒曼陀罗图腾 → 只勾选 `['Colors']`；
   - 纯经典法式马卡龙甜点剖面 → 只勾选 `['Food']`。
3. **标签数量限制**：
   - 每张拼图建议打 **1 ~ 3 个主 Tag**，禁止打超过 4 个主 Tag，避免标签稀释。
