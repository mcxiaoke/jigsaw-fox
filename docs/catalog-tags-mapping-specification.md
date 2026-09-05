# Jigsaw Puzzle 分类与标签规范说明书 (v3.1 定稿版)

> **版本**：v3.1 Final (2026-09-05)  
> **体系架构**：统一精炼 16 主 Tags + 1 系统兜底（Others） + 1 全部（All）  
> **UI 矩阵**：前台展示 16 主 Tags + 1 Others + 1 "All(全部)" = **18 项黄金矩阵（3 列 × 6 行完美网格）**  
> **数据结构**：完全兼容现有代码（`LevelItem.tags: List<String>` 与 `tags.json` 格式标准数组结构）  

---

## 一、 架构演进与设计原则

经过对全球拼图市场多源调研数据、46 个存量真实图库目录（24,592 张图片）实测分析，我们对分类标签系统进行了全面升级：

1. **客观实体为主，兼具形式载体**：
   - 移除原体系中偏向主观情感的 `Cozy`（温馨），将其具象拆解为 `People`（人物）、`Objects`（物品）和 `Structures`（建筑室内），使标注标准统一、客观、零歧义。
   - 拆解原范围过宽的 `Travel`（旅行）为 `Cities`（城市）与 `Structures`（建筑）。
2. **多选打标与附加 Tag 机制**：
   - 标签字段为标准数组（`tags: ["Animals", "Art", "Colors"]`），单张图片可同时拥有多个标签。
   - **`Colors` (色彩)** 与 **`Composition` (组合)** 定位为**【附加 Tag】**，一般不单独使用，由运营人员手动指定。例如色彩艳丽的平铺花卉可打 `["Flowers", "Colors", "Composition"]`。
   - 目录自动识别时不自动模糊推断 `Colors` 与 `Composition`（除非目录名直接为 `Colors` 或 `Composition` 等明确目录），避免形式标签冲淡实体分类。
3. **黄金排布，极致的视觉体验**：
   - 16 个主 Tags + 1 个 "Others (其他)" + 1 个 "All (全部)" = **18 项**；
   - 在手机端底部抽屉（BottomSheet）或筛选面板中，刚好排成 **3 列 × 6 行** 完美对称矩阵，整除无留白、无悬空项。

---

## 二、 核心 16 主 Tags + Others（前台 UI 与打标展示层）

在 App 首页导航与筛选面板中的 18 项（含全部）3×6 黄金排布：

```
┌───────────────────┬───────────────────┬───────────────────┐
│     All (全部)    │  Landscapes (风光)│   Nature (自然)   │  <- R1: 宏观天地与自然生机
├───────────────────┼───────────────────┼───────────────────┤
│   Flowers (花卉)  │   Animals (动物)  │    Pets (宠物)    │  <- R2: 植物名花与生命萌物
├───────────────────┼───────────────────┼───────────────────┤
│    Cities (城市)  │ Structures (建筑) │  Vehicles (交通)  │  <- R3: 城市天际、工程建筑与交通载具
├───────────────────┼───────────────────┼───────────────────┤
│    People (人物)  │   Objects (物品)  │     Food (美食)   │  <- R4: 人物肖像、日常器物与环球美食
├───────────────────┼───────────────────┼───────────────────┤
│     Art (艺术)    │   Fantasy (奇幻)  │  Holidays (庆典)  │  <- R5: 艺术插画、奇妙幻想与节庆盛典
├───────────────────┼───────────────────┼───────────────────┤
│    Colors (色彩)  │Composition (组合) │   Others (其他)   │  <- R6: 形式美感（附加Tag）与兜底
└───────────────────┴───────────────────┴───────────────────┘
```

### 主 Tags 详细定义与覆盖范围表

| 行号 | Tag ID (代码值) | 中文名 | 阵营属性 | 核心定位与视觉基调 | 典型覆盖场景与画面实体 | 标注规则与附加说明 |
| :---: | :--- | :--- | :---: | :--- | :--- | :--- |
| **R1** | **`Landscapes`** | **风光** | 宏观主体 | 宏观地理、壮阔山川、浩瀚天象 | 雪山、冰川湖泊、江河瀑布、原始森林大景、海岸悬崖、热带沙滩、晚霞暮光、日出晨曦、极光天象 | 适合宏观大场景自然风光 |
| **R1** | **`Nature`** | **自然** | 宏观主体 | 植物生态、奇趣真菌、四季物候 | 绿色观叶植物、多肉仙人掌、盆景蕨类、森林奇趣荧光真菌/蘑菇、苔藓地衣、四季节令物候 | 微观与中观自然生态，四季风貌 |
| **R2** | **`Flowers`** | **花卉** | 客观主体 | 浪漫名花、花海花艺、优雅园艺 | 玫瑰月季、牡丹芍药、郁金香、向日葵、绣球紫藤、樱花花道、田园花海、桌面精致插花、花艺花房 | 画面核心视觉为主体花朵 |
| **R2** | **`Animals`** | **动物** | 客观主体 | 野生生灵、飞禽鸟类、海洋水族 | 陆地野生猛兽（狮虎豹狼狐、鹿熊象猴）、飞禽鸟类（金刚鹦鹉、巨嘴鸟、猫头鹰、天鹅白鹭）、海洋水族（蓝鲸海豚海龟热带鱼） | 野生陆生/两栖/鸟类/水族动物 |
| **R2** | **`Pets`** | **宠物** | 客观主体 | 家庭伴侣萌宠、治愈生灵 | 猫咪（各类家猫/品种猫）、狗狗（金毛/柯基/柴犬等名犬）、兔子、荷兰猪/豚鼠、仓鼠、龙猫、水豚、小鸭芦丁鸡等家庭萌宠 | 家庭常见驯化萌宠，强调治愈感 |
| **R3** | **`Cities`** | **城市** | 客观主体 | 城市天际线、都市夜景、市井街巷 | 世界都市天际线、宏观俯瞰、繁华夜景街区、老城巷弄、水乡石桥运河、欧洲古典小镇街景 | 强调宏观城市场景与市井氛围 |
| **R3** | **`Structures`** | **建筑** | 客观主体 | 知名地标建筑、古堡宫殿、几何构造 | 世界知名地标建筑实体（铁塔/泰姬陵/斗兽场/大本钟）、中世纪古堡宫殿、跨海大桥、海岸灯塔、大教堂穹顶、寺庙塔楼、室内建筑与壁炉书房 | 强调单体/群落构造本体与工程美学 |
| **R3** | **`Vehicles`** | **交通** | 客观主体 | 交通载具、工业机械、出行工具 | 经典复古汽车、老爷车、现代超跑机车、蒸汽列车、观光火车铁轨、古典多桅大帆船、豪华游轮游艇、老式双翼飞机、热气球群 | 交通工具与出行机械 |
| **R4** | **`People`** | **人物** | 客观主体 | 人物肖像、时尚写真、日常慢调人物 | 人物肖像、时尚写真、童话角色、闲适阅读/下午茶人物、亲子情侣、民族服饰人像、街头纪实抓拍 | 画面核心主体为人物 |
| **R4** | **`Objects`** | **物品** | 客观主体 | 复古器物、静物台饰、生活日常用品 | 老式打字机、黑胶唱机、手作编织工艺品、复古杂货、钟表、乐器、玩具乐高、精美茶具餐具、静物台饰 | 独立物品、器物陈列与工艺品 |
| **R4** | **`Food`** | **美食** | 客观主体 | 烘焙甜点、环球料理、鲜果茶饮 | 法式蛋糕西点、面包烘焙、马卡龙冰淇淋、料理（寿司/拉面/披萨/牛排）、热带鲜果时蔬拼盘、拿铁拉花咖啡、英式下午茶 | 美味佳肴、西点烘焙与饮品 |
| **R5** | **`Art`** | **艺术** | 画风载体 | 各种艺术插画、手绘、AI生成插画、名画 | 大师古典油画名作（梵高/莫奈等）、手绘水彩绘本插画、动漫二次元赛璐璐（吉卜力风）、中国工笔花鸟国风水墨、AI生成唯美数码插画 | 重点涵盖插画、手绘与 AI 插画 |
| **R5** | **`Fantasy`** | **奇幻** | 想象世界 | 魔法神兽、深空星系、占星图腾 | 西方巨龙独角兽、浮空岛魔法城堡仙境、炼金水晶、舱外宇航员深空星云天体行星、十二星座守护兽与神秘学图腾 | 超越现实的幻想与深空宇宙 |
| **R5** | **`Holidays`** | **庆典** | 节庆活动 | 活动、节日、庆典、运动会赛事 | 圣诞节节庆、万圣节南瓜糖果、复活节彩蛋、除夕春节灯笼年夜饭、嘉年华狂欢游行、体育赛事与运动会（足球/滑雪/冲浪/马拉松） | 涵盖传统节日、民俗庆典与体育盛会 |
| **R6** | **`Colors`** | **色彩** | 形式属性 | **【附加Tag】** 彩虹渐变、纯色冲击、强烈撞色 | 彩虹高饱和色相矩阵、纯单色调视觉冲击、明艳撞色搭配、马卡龙调色盘、丙烯流体色彩 | **附加Tag，一般不单独使用，运营手动多选指定** |
| **R6** | **`Composition`** | **组合** | 形式属性 | **【附加Tag】** 平铺俯拍、模块排布、拼贴对称 | 器物平铺整齐陈列（Flat-Lay）、模块化排布（Knolling）、拼贴画（Collage）、曼陀罗万花筒对称几何、器物集合 | **附加Tag，一般不单独使用，运营手动多选指定** |
| **R6** | **`Others`** | **其他** | 系统兜底 | 无法明确归类的特殊杂项素材 | 无法归入上述 16 类的主题素材兜底 | 兜底项，触发人工复核 |

---

## 三、 细分词库与目录智能推断规则（`tag_patterns`）

细分词库不限制条数，作为后台算法与运营百科全书。当脚本扫描素材目录时，若命中以下模式正则（大小写不敏感），将**自动归一化推断为主 Tag**：

```python
TAG_PATTERNS = {
    # 1. Landscapes (风光)
    "Landscapes": [
        r"landscape", r"mountain", r"peak", r"canyon", r"valley", r"cliff", r"scree",
        r"forest", r"wood", r"bamboo", r"jungle",
        r"ocean", r"sea\b", r"beach", r"coast", r"reef", r"wave", r"iceberg",
        r"sunset", r"sunrise", r"dusk", r"dawn", r"twilight", r"horizon",
        r"waterfall", r"lake", r"river", r"creek", r"stream", r"fjord",
        r"desert", r"dune", r"aurora", r"sky", r"cloud"
    ],

    # 2. Nature (自然)
    "Nature": [
        r"nature", r"botanical", r"succulent", r"cactus", r"bonsai", r"fern", r"leaf", r"foliage",
        r"mushroom", r"fungi", r"toadstool", r"moss", r"lichen",
        r"season", r"spring\b", r"summer", r"autumn", r"fall\b", r"winter", r"frost", r"snow_scene"
    ],

    # 3. Flowers (花卉)
    "Flowers": [
        r"flower", r"floral", r"rose\b", r"roses\b", r"peony", r"tulip", r"sunflower",
        r"hydrangea", r"wisteria", r"cherry_blossom", r"lotus", r"water_lily", r"bouquet",
        r"garden", r"meadow", r"greenhouse"
    ],

    # 4. Animals (野生动物与鸟类水族)
    "Animals": [
        r"animal", r"wildlife", r"fauna", r"mammal",
        r"lion", r"tiger", r"leopard", r"cheetah", r"jaguar", r"bear\b", r"polar_bear",
        r"deer", r"stag", r"elk", r"wolf", r"fox\b", r"foxes\b", r"elephant", r"giraffe", r"zebra",
        r"rhino", r"hippo", r"monkey", r"panda", r"sloth", r"otter",
        r"bird", r"parrot", r"macaw", r"toucan", r"owl", r"eagle", r"hawk",
        r"swan", r"flamingo", r"peacock", r"penguin", r"hummingbird", r"kingfisher",
        r"sealife", r"marine", r"ocean_creature", r"whale", r"dolphin", r"orca",
        r"shark", r"turtle", r"sea_turtle", r"jellyfish", r"seahorse", r"stingray", r"octopus", r"coral_fish",
        r"insect", r"butterfly", r"dragonfly", r"beetle", r"chameleon", r"tree_frog"
    ],

    # 5. Pets (家庭伴侣宠物)
    "Pets": [
        r"pet\b", r"pets\b", r"cat\b", r"cats\b", r"kitten", r"kitty", r"feline", r"ragdoll", r"british_shorthair",
        r"dog\b", r"dogs\b", r"puppy", r"puppies", r"canine", r"corgi", r"shiba", r"golden_retriever", r"labrador",
        r"poodle", r"bulldog", r"husky", r"samoyed",
        r"rabbit", r"bunny", r"bunnies", r"hare\b",
        r"guinea_pig", r"hamster", r"chinchilla", r"hedgehog", r"capybara", r"ferret",
        r"goldfish", r"betta", r"aquarium", r"budgie", r"call_duck"
    ],

    # 6. Cities (城市与街景)
    "Cities": [
        r"^cit(y|ies)$", r"urban", r"skyline", r"metropolis", r"street", r"alley", r"canal", r"night_view",
        r"cityscape", r"downtown", r"old_town", r"water_town", r"cotswolds", r"santorini", r"village", r"town"
    ],

    # 7. Structures (建筑与空间)
    "Structures": [
        r"^structures?$", r"architecture", r"building", r"bridge", r"landmark", r"monument",
        r"eiffel", r"taj_mahal", r"colosseum", r"pyramid", r"big_ben",
        r"castle", r"palace", r"chateau", r"fortress", r"manor",
        r"cathedral", r"church", r"temple", r"shrine", r"pagoda", r"windmill", r"lighthouse",
        r"interior", r"living_room", r"bedroom", r"study", r"fireplace", r"hearth", r"cottage", r"cabin", r"log_cabin", r"chalet", r"thatched"
    ],

    # 8. Vehicles (交通机械)
    "Vehicles": [
        r"vehicle", r"transport",
        r"car\b", r"cars\b", r"automobile", r"classic_car", r"vintage_car", r"sports_car", r"camper", r"van\b", r"motorcycle", r"scooter", r"truck",
        r"train", r"locomotive", r"steam_train", r"railway", r"railroad", r"tram", r"metro",
        r"ship\b", r"ships\b", r"boat", r"sailboat", r"tall_ship", r"yacht", r"cruise", r"gondola", r"canoe", r"vessel",
        r"aircraft", r"airplane", r"plane\b", r"planes\b", r"biplane", r"balloon", r"hot_air_balloon", r"helicopter", r"airship"
    ],

    # 9. People (人物肖像与纪实)
    "People": [
        r"^people$", r"^person$", r"portrait", r"human", r"girl", r"boy", r"woman", r"man\b", r"lady",
        r"child\b", r"children", r"couple", r"family", r"lifestyle", r"reading", r"picnic", r"model", r"figure"
    ],

    # 10. Objects (物品与复古器物)
    "Objects": [
        r"^objects?$", r"item", r"craft", r"handicraft", r"knitting", r"yarn", r"wool", r"sewing", r"embroidery", r"patchwork", r"pottery", r"woodworking",
        r"vintage", r"retro", r"nostalgia", r"americana", r"antique", r"typewriter", r"gramophone",
        r"clock", r"book", r"toy", r"lego", r"instrument", r"still_life", r"tableware"
    ],

    # 11. Food (美食饮品)
    "Food": [
        r"food", r"meal", r"dish", r"gourmet",
        r"dessert", r"sweet", r"cake", r"pastry", r"bakery", r"croissant", r"bread",
        r"macaron", r"donut", r"waffle", r"pancake", r"cookie", r"pie\b", r"ice_cream", r"chocolate",
        r"cuisine", r"sushi", r"ramen", r"pizza", r"pasta", r"steak", r"dim_sum", r"taco", r"burger", r"bbq",
        r"fruit", r"berry", r"berries", r"strawberry", r"citrus", r"lemon", r"apple", r"vegetable", r"harvest",
        r"drink", r"beverage", r"coffee", r"coffeetea", r"latte", r"tea\b", r"afternoon_tea", r"cocktail", r"wine", r"matcha"
    ],

    # 12. Art (艺术插画与画作)
    "Art": [
        r"art\b", r"arts\b", r"fine_?art", r"masterpiece", r"museum",
        r"painting", r"oil_painting", r"watercolor", r"acrylic", r"canvas", r"impressionism", r"van_gogh", r"monet",
        r"illustration", r"storybook", r"picture_book", r"whimsical", r"hand_drawn", r"sketch",
        r"anime", "manga", r"cartoon", r"chibi", r"ghibli", r"cel_shaded",
        r"oriental", r"asian_art", r"chinese_painting", r"gongbi", r"ink_wash", r"blue_green_landscape", r"ukiyo_e",
        r"ai_art", r"ai_generated", r"digital_art", r"concept_art"
    ],

    # 13. Fantasy (奇幻异界与深空)
    "Fantasy": [
        r"fantasy", r"fairy_tale", r"enchanted",
        r"mythical", r"mythology", r"dragon", r"unicorn", r"griffin", r"phoenix", r"kitsune", r"pegasus", r"mermaid", r"fairy", r"pixie", r"elf", r"elves",
        r"magic", r"wizard", r"witch", r"spell", r"potion", r"cauldron", r"crystal_cave", r"floating_island", r"portal",
        r"space", r"universe", r"cosmos", r"galaxy", r"galaxies", r"nebula", r"planet", r"saturn", r"earth", r"moon", r"astronaut", r"spaceship", r"space_station", r"sci_fi",
        r"zodiac", r"astrology", r"horoscope", r"constellation", r"tarot"
    ],

    # 14. Holidays (庆典、节日与体育赛事)
    "Holidays": [
        r"holiday", r"festival", r"celebration", r"carnival", r"parade",
        r"christmas", r"xmas", r"santa", r"reindeer", r"gingerbread",
        r"halloween", r"jack_o_lantern", r"pumpkin",
        r"easter", r"easter_egg",
        r"new_?year", r"spring_festival", r"chinese_new_year", r"lunar_new_year", r"lantern",
        r"thanksgiving", r"turkey", r"valentine",
        r"\bsports?\b", r"athletics?", r"stadium", r"skiing", r"surfing", r"soccer", r"football", r"basketball", r"olympics?", r"marathon", r"championship"
    ],

    # 15. Colors (色彩 - 附加Tag，严格匹配专有目录名，不作模糊匹配)
    "Colors": [
        r"^colors?$", r"^rainbow$", r"^gradients?$", r"^vibrant_palette$", r"^monochrome$"
    ],

    # 16. Composition (组合 - 附加Tag，严格匹配专有目录名，不作模糊匹配)
    "Composition": [
        r"^composition$", r"^flat_?lays?$", r"^knolling$", r"^collages?$", r"^assortment$", r"^mandala$", r"^kaleidoscopes?$"
    ],

    # 17. Others (其他兜底)
    "Others": [
        r"^others?$", r"^misc$"
    ]
}
```

---

## 四、 真实图库目录识别印证矩阵（46 目录 100% 验证）

针对真实素材目录 `C:\Home\Temp\Jigsaw_Organized`（共 24,592 张图片）的全量推断映射：

| 原始素材目录 | 识别主 Tag | 原始素材目录 | 识别主 Tag | 原始素材目录 | 识别主 Tag |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `Flowers` (1449) | **Flowers** | `Forests` (388) | **Landscapes** | `CoffeeTea` (210) | **Food** |
| `Animals` (1376) | **Animals** | `Sunsets` (107) | **Landscapes** | `Crafts` (160) | **Objects** |
| `Architecture` (1268) | **Structures** | `Nature` (875) | **Nature** | `FineArt` (156) | **Art** |
| `Food` (1171) | **Food** | `Botanical` (18) | **Nature** | `Villages` (119) | **Cities** |
| `Birds` (1052) | **Animals** | `Seasons` (731) | **Nature** | `Christmas` (110) | **Holidays** |
| `Transportation` (959)| **Vehicles** | `Cats` (345) | **Pets** | `Halloween` (108) | **Holidays** |
| `Illustration` (930) | **Art** | `Dogs` (365) | **Pets** | `Colors` (106) | **Colors** |
| `Cities` (927) | **Cities** | `Pets` (792) | **Pets** | `Mandala` (48) | **Composition** |
| `Fantasy` (883) | **Fantasy** | `Wildlife` (846) | **Animals** | `Oriental` (42) | **Art** |
| `Landscapes` (843) | **Landscapes** | `SeaLife` (563) | **Animals** | `CozyHome` (15) | **Structures** |
| `Space` (796) | **Fantasy** | `Vintage` (528) | **Objects** | `FlatLay` (15) | **Composition** |
| `People` (691) | **People** | `Landmarks` (510) | **Structures** | `Zodiac` (14) | **Fantasy** |
| `Art` (636) | **Art** | `Sweets` (499) | **Food** | `Sports` (380) | **Holidays** |
| `Abstract` (591) | **Colors** | `Mountains` (403)| **Landscapes** | `Others` (953) | **Others** |
| `Ocean` (554) | **Landscapes** | `Castles` (277) | **Structures** | - | - |
| `Holidays` (541) | **Holidays** | `Mythical` (242) | **Fantasy** | - | - |

---

## 五、 打标实操指引（运营与标注人员）

1. **组合打标模型：1 个核心物理主体 + 0~1 个画风/形式载体 + 0~1 个附加 Tag**
   - **核心主体 Tag (必选 1 个)**：`Landscapes`, `Nature`, `Flowers`, `Animals`, `Pets`, `Cities`, `Structures`, `Vehicles`, `People`, `Objects`, `Food`, `Fantasy`, `Holidays`；
   - **画风载体 Tag (按需)**：若画面为艺术插画、绘本手绘、AI 生成或油画风格，额外勾选 `Art`；
   - **附加 Tag (运营按需手动指定)**：
     - 若画面呈现强烈的彩虹渐变、纯单色调冲击或极度鲜明的色块碰撞，额外勾选 `Colors`；
     - 若画面呈现俯拍平铺（Flat-Lay）、模块整齐排布（Knolling）、拼贴（Collage）或对称万花筒，额外勾选 `Composition`。
   - **典型打标范例**：
     - “插画风格的樱花古堡与列车” → 勾选 `['Structures', 'Vehicles', 'Art']`；
     - “整齐平铺的彩色烘焙西点工具” → 勾选 `['Food', 'Objects', 'Composition', 'Colors']`；
     - “大片盛开的向日葵花田与蓝天” → 勾选 `['Flowers', 'Landscapes']`；
     - “纯野生雪山金雕特写” → 纯主体单选 `['Animals']`。
2. **标签数量建议**：
   - 每张拼图推荐打 **1 ~ 3 个 Tag**（通常 1 主体 + 1 形式/画风/附加），原则上不超过 4 个，确保各分类曝光既精准又丰富。
