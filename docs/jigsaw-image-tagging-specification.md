# Jigsaw Puzzle Image Tagging Specification v1.0

## 1. 总体规则

每张图片只分配 **1 个 Primary Tag**。

AI 不允许自己创建新的分类名称，只能从以下 25 个固定 Tag 中选择。

### 标准 Tag 列表

| ID | Tag | 中文 | 核心定义 |
|---|---|---|---|
| 01 | Animals | 动物 | 野生动物、动物群、动物自然场景 |
| 02 | Pets | 宠物 | 猫、狗、兔子、仓鼠等家庭宠物 |
| 03 | Nature | 自然 | 森林、植物、自然生态、自然元素 |
| 04 | Landscapes | 风景 | 山川、湖泊、田野、峡谷等景观 |
| 05 | Flowers | 花卉 | 花朵、花束、花田、园艺植物 |
| 06 | Ocean | 海洋 | 海洋、海滩、海浪、水下、海洋生态 |
| 07 | Birds | 鸟类 | 鹰、猫头鹰、鹦鹉、火烈鸟等鸟类 |
| 08 | Travel | 旅行 | 旅游目的地、异国风情、旅行体验 |
| 09 | Cities | 城市 | 城市街景、城市生活、城市天际线 |
| 10 | Architecture | 建筑 | 建筑本体、住宅、教堂、桥梁、城堡等 |
| 11 | Landmarks | 地标 | 世界著名地标或容易识别的著名建筑 |
| 12 | Food | 美食 | 食物、甜点、料理、餐桌、美食摄影 |
| 13 | Art | 艺术 | 绘画、艺术作品、艺术风格、经典名画 |
| 14 | Fantasy | 奇幻 | 魔法、龙、独角兽、精灵、幻想世界 |
| 15 | Space | 太空 | 宇宙、星球、银河、宇航员 |
| 16 | Transportation | 交通 | 汽车、飞机、火车、轮船、自行车等 |
| 17 | People | 人物 | 人像、人物活动、人物生活场景 |
| 18 | Sports | 运动 | 足球、篮球、网球、滑雪等运动 |
| 19 | Seasons | 四季 | 春、夏、秋、冬及明显季节场景 |
| 20 | Holidays | 节日 | 圣诞节、万圣节、复活节、新年等 |
| 21 | Vintage | 复古 | 老照片、复古海报、怀旧物件、历史感 |
| 22 | Abstract | 抽象 | 抽象艺术、几何图案、纹理、非具象视觉 |
| 23 | Cozy | 温馨 | 室内、壁炉、客厅、咖啡馆、舒适生活氛围 |
| 24 | Cartoon | 卡通 | 卡通、动漫风、漫画、儿童插画 |
| 25 | Others | 其他 | 无法稳定归入上述主题的小众内容 |

---

# 2. Tag 判定原则

AI 的任务不是判断“这张图看起来像什么”，而是判断：

> **用户最可能为什么主题来搜索/筛选这张拼图？**

因此采用以下优先级：

### Priority 1：明确主体

如果图片存在非常明确的核心主体，优先按照主体分类。

例：

- 一只猫在家里 → Pets
- 一只老虎在森林里 → Animals
- 一架飞机 → Transportation
- 一盘蛋糕 → Food
- 一个宇航员 → Space

### Priority 2：场景主题

如果不存在非常明确的主体，则按照整个场景的主要主题分类。

例：

- 山谷和湖泊 → Landscapes
- 城市夜景 → Cities
- 森林风景 → Nature
- 海边度假场景 → Ocean / Travel

### Priority 3：著名地点

如果图片的核心价值在于一个著名地标，则优先 Landmarks，而不是 Architecture。

例：

- 埃菲尔铁塔 → Landmarks
- 泰姬陵 → Landmarks
- 长城 → Landmarks

### Priority 4：艺术/风格

如果图片主要是一幅艺术作品、插画或抽象作品：

- 名画 → Art
- 奇幻插画 → Fantasy
- 卡通插画 → Cartoon
- 抽象图案 → Abstract

### Priority 5：氛围

只有当图片缺乏明确主体，而主要卖点是生活氛围时，才使用 Cozy。

---

# 3. 每个 Tag 的详细判定规则

## 01 Animals / 动物

### 使用条件

图片主要表现：

- 野生动物
- 动物群
- Safari
- 动物在自然环境中
- 农场动物
- 非家庭宠物性质的动物

### 典型例子

- Lion
- Tiger
- Elephant
- Deer
- Bear
- Giraffe
- Zebra
- Monkey
- Fox

### 不应该使用

- Cat / Dog 等明显家庭宠物 → Pets
- Eagle / Owl 等主要以鸟类为主体 → Birds
- Dolphin / Whale 等 → Ocean
- Dragon / Unicorn → Fantasy

### 边界案例

一只猫趴在森林里：

→ **Pets**

因为“猫”作为主体比“森林”更明确。

---

## 02 Pets / 宠物

### 使用条件

图片核心主体是常见家庭宠物：

- Cats
- Dogs
- Rabbits
- Hamsters
- Guinea pigs
- Domestic pets

### 优先级

即使背景是：

- 家庭 → Pets
- 花园 → Pets
- 城市 → Pets
- 海滩 → Pets

只要宠物明显是视觉核心，仍然使用 Pets。

### 边界案例

狗在海边奔跑：

→ Pets

狗只占很小一部分，而整个图片主要是海滩风景：

→ Ocean 或 Landscapes

---

## 03 Nature / 自然

### 使用条件

整个图片主要表现自然环境或自然元素：

- Forest
- Trees
- Waterfalls
- Rivers
- Plants
- Natural ecosystems
- Wilderness

### 与 Landscapes 区别

Nature = 自然本身

Landscapes = “风景画面 / 景观视角”

例如：

森林内部、树木很多：

→ Nature

远处山脉 + 湖泊 + 日落的大景：

→ Landscapes

---

## 04 Landscapes / 风景

### 使用条件

画面的主要卖点是宏观风景：

- Mountains
- Lakes
- Valleys
- Countryside
- Cliffs
- Scenic views
- Sunset scenery

### 典型特征

通常可以把图片描述为：

> “A beautiful scenic view of ...”

而不是某一个具体主体。

---

## 05 Flowers / 花卉

### 使用条件

花朵是主要视觉内容：

- Roses
- Tulips
- Sunflowers
- Lavender
- Cherry blossoms
- Flower bouquets
- Flower fields
- Floral arrangements

### 边界案例

花园 + 房子：

如果房子明显是主要主体 → Architecture

花园中大量鲜花是主要视觉内容 → Flowers

---

## 06 Ocean / 海洋

### 使用条件

主要与海洋、水下或海边有关：

- Ocean
- Sea
- Beach
- Waves
- Coral reefs
- Underwater scenes
- Marine animals

### 注意

海豚、鲸鱼、鲨鱼在海洋环境中：

→ Ocean

除非图片主要是动物肖像/特写，否则不要优先 Animals。

---

## 07 Birds / 鸟类

### 使用条件

画面主要主体是鸟：

- Eagle
- Owl
- Parrot
- Flamingo
- Swan
- Peacock
- Penguin

### 边界案例

企鹅在冰川环境中：

主体明显是企鹅 → Birds

整个画面主要是南极景观，企鹅只占很小区域：

→ Landscapes

---

## 08 Travel / 旅行

### 使用条件

图片重点是“旅行目的地/旅行体验”，但不属于一个明确的城市、地标或纯自然风景。

典型：

- European village
- Tropical vacation
- Exotic destination
- Travel photography
- Foreign streets
- Resort destinations

### 与 Cities 区别

城市本身 → Cities

旅游感、目的地感更强 → Travel

---

## 09 Cities / 城市

### 使用条件

核心内容是：

- City skyline
- Urban streets
- Downtown
- City life
- Buildings as an urban scene
- Famous city streets

### 例子

New York skyline → Cities

Tokyo street → Cities

Paris street → Cities

---

## 10 Architecture / 建筑

### 使用条件

重点是建筑本身：

- Houses
- Castles
- Churches
- Bridges
- Towers
- Mansions
- Buildings
- Interior architecture

### 与 Landmarks 区别

普通建筑 → Architecture

世界著名、具有明显识别意义的地标 → Landmarks

例如：

普通城堡 → Architecture

Neuschwanstein Castle → Landmarks

---

## 11 Landmarks / 地标

### 使用条件

图片包含一个明确的著名地标：

- Eiffel Tower
- Big Ben
- Statue of Liberty
- Taj Mahal
- Great Wall
- Colosseum
- Sydney Opera House

### 核心判断

必须满足：

> 这个地方/建筑本身就是图片的卖点。

如果只是普通建筑：

→ Architecture

---

## 12 Food / 美食

### 使用条件

视觉核心是：

- Food
- Desserts
- Cakes
- Pizza
- Sushi
- Coffee
- Fruits
- Restaurant dishes
- Food photography

### 边界案例

咖啡馆内部：

食物/咖啡占主体 → Food

整个咖啡馆氛围 → Cozy

---

## 13 Art / 艺术

### 使用条件

图片主要是：

- Fine art
- Oil painting
- Watercolor
- Classic paintings
- Famous artworks
- Artistic compositions

如果图片明显是“艺术作品”，而不是现实摄影，则优先 Art。

---

## 14 Fantasy / 奇幻

### 使用条件

现实世界不存在或明显幻想化的主题：

- Dragons
- Unicorns
- Fairies
- Wizards
- Magical castles
- Fantasy worlds
- Mythical creatures

### 与 Cartoon 区别

幻想题材 → Fantasy

卡通/漫画表现形式 → Cartoon

例如：

卡通龙 → Fantasy

卡通猫 → Cartoon / Pets

---

## 15 Space / 太空

### 使用条件

- Planets
- Galaxy
- Stars
- Moon
- Nebula
- Astronauts
- Spacecraft
- Outer space

即使画面是插画，只要主题明确是宇宙/太空：

→ Space

---

## 16 Transportation / 交通

### 使用条件

主要主体是：

- Cars
- Trains
- Airplanes
- Ships
- Boats
- Bicycles
- Motorcycles
- Buses
- Trams

### 边界案例

汽车 + 城市场景：

汽车是主体 → Transportation

汽车只是城市街道中的小元素：

→ Cities

---

## 17 People / 人物

### 使用条件

图片主要表现人物：

- Portraits
- Groups of people
- People walking
- Family
- Lifestyle photography
- Human activities

### 例外

人物属于明确主题时优先主题：

宇航员 → Space

运动员在比赛 → Sports

圣诞老人 → Holidays

卡通人物 → Cartoon

---

## 18 Sports / 运动

### 使用条件

明确的体育/运动行为：

- Football
- Basketball
- Tennis
- Baseball
- Golf
- Skiing
- Surfing
- Cycling
- Running

### 边界案例

一个人在海边冲浪：

→ Sports

只有海浪和冲浪板，没有明显运动行为：

→ Ocean

---

## 19 Seasons / 四季

### 使用条件

图片主要通过季节特征表达主题：

- Spring
- Summer
- Autumn
- Winter
- Snowy winter
- Autumn foliage
- Spring blossoms

### 判断方法

如果用户更可能因为“这是秋天”而选择它：

→ Seasons

如果只是普通森林恰好有一些秋叶：

→ Nature

---

## 20 Holidays / 节日

### 使用条件

明确的节日主题：

- Christmas
- Halloween
- Easter
- New Year
- Valentine's Day
- Thanksgiving
- Hanukkah
- Lunar New Year

### 边界案例

一棵普通圣诞树：

→ Holidays

一间温暖的房间里摆着普通装饰，但没有明显节日元素：

→ Cozy

---

## 21 Vintage / 复古

### 使用条件

主要卖点是怀旧/历史感：

- Old photographs
- Retro posters
- Vintage cars
- Antique objects
- 1950s / 1960s style
- Historical scenes

### 重要规则

Vintage 是“主题/时代风格”，不是单纯“图片颜色偏黄”。

现代照片做成复古滤镜：

不要因为色调复古就强制选 Vintage。

---

## 22 Abstract / 抽象

### 使用条件

图片缺少明显具象主体，主要表现：

- Abstract art
- Geometric patterns
- Shapes
- Textures
- Mandala
- Decorative patterns

### 不应该使用

有明确猫/花/建筑主体，只是画风比较艺术：

→ 仍按主体分类

---

## 23 Cozy / 温馨

### 使用条件

核心卖点是舒适、温暖、惬意的生活氛围：

- Cozy room
- Fireplace
- Warm bedroom
- Reading corner
- Cottage interior
- Café atmosphere
- Warm home
- Hygge lifestyle

### 这是一个“氛围型”Tag

只有当没有比 Cozy 更明确的主题时才使用它。

---

## 24 Cartoon / 卡通

### 使用条件

图片明显属于：

- Cartoon
- Anime-style
- Comic
- Children's illustration
- Cute illustration
- Hand-drawn character art

### 边界案例

一只卡通猫：

优先判断：

如果图片卖点是“猫” → Pets

如果图片卖点是“卡通角色/插画风” → Cartoon

如果图片是卡通化的幻想龙：

→ Fantasy

---

## 25 Others / 其他

只有在以下情况下使用：

1. 无法稳定归入其他 24 类
2. 内容非常小众
3. 图片主题混杂且没有明显主次
4. 模型视觉信息不足，无法可靠判断

### 重要规则

Others 不是“模型不知道”。

如果只是两个类别难以选择，必须根据优先级做判断。

只有真正没有合理分类时才允许 Others。

---

# 4. 冲突分类决策表

以下规则优先于模型自己的直觉。

| 图片情况 | Primary Tag |
|---|---|
| 猫 | Pets |
| 狗 | Pets |
| 狮子 | Animals |
| 鹰 | Birds |
| 鲸鱼 | Ocean |
| 花束 | Flowers |
| 山湖日落 | Landscapes |
| 森林 | Nature |
| 海滩 | Ocean |
| 城市街景 | Cities |
| 埃菲尔铁塔 | Landmarks |
| 普通城堡 | Architecture |
| 一盘意大利面 | Food |
| 名画 | Art |
| 龙 | Fantasy |
| 银河 | Space |
| 汽车 | Transportation |
| 人像 | People |
| 足球比赛 | Sports |
| 秋季森林 | Seasons |
| 圣诞场景 | Holidays |
| 老照片 | Vintage |
| 几何图案 | Abstract |
| 温暖客厅 | Cozy |
| 卡通角色 | Cartoon |

---

# 5. 复杂场景的最终判定原则

当图片同时包含多个主题时：

## Rule A：主体优先

主体明显占据视觉中心：

> Subject > Background

例：

一只狗 + 海滩  
→ Pets

一个宇航员 + 银河  
→ Space

一个人 + 城市背景  
→ People

---

## Rule B：著名地标优先于普通建筑

> Landmark > Architecture

例：

Eiffel Tower + Paris  
→ Landmarks

普通欧洲教堂  
→ Architecture

---

## Rule C：动物主体优先于环境

> Animal Subject > Nature / Landscape

但前提是动物足够显眼。

如果：

鹿占 40% 画面  
森林占 60%

仍可以 → Animals

如果：

鹿只占 5%

→ Nature / Landscapes

---

## Rule D：明确主题优先于氛围

> Subject > Cozy

例如：

咖啡 + 温暖木屋

如果咖啡/食物明显是核心：

→ Food

如果重点是整个室内氛围：

→ Cozy

---

## Rule E：节日主题优先

如果出现非常明确的节日符号：

> Holidays > Cozy / Seasons

例如：

圣诞树 + 壁炉  
→ Holidays

而不是 Cozy。

---

# 6. AI 输出规范

推荐模型只输出 JSON，不输出解释文字。

### 推荐 Schema

```json
{
  "tag": "Pets",
  "confidence": 0.96,
  "subject": "cat",
  "scene": "indoor home",
  "reason": "The cat is the clear visual subject."
}
```

其中：

### tag

只能是：

```text
Animals
Pets
Nature
Landscapes
Flowers
Ocean
Birds
Travel
Cities
Architecture
Landmarks
Food
Art
Fantasy
Space
Transportation
People
Sports
Seasons
Holidays
Vintage
Abstract
Cozy
Cartoon
Others
```

### confidence

范围：

```text
0.00 - 1.00
```

建议：

- 0.90–1.00 = 非常明确
- 0.75–0.89 = 比较明确
- 0.60–0.74 = 有一定歧义
- < 0.60 = 强烈建议人工复核

---

# 7. Ollama + Qwen3-VL 推荐 System Prompt

直接使用下面这段。

```text
You are an image classification system for a jigsaw puzzle application.

Your job is to assign EXACTLY ONE primary category to each image.

You MUST choose the category from the allowed list.
You MUST NOT invent new categories.
You MUST NOT return multiple categories.

The goal is to determine the category that best represents the main visual subject or theme that a user would most likely use to discover or filter this jigsaw puzzle.

Allowed categories:

1. Animals
2. Pets
3. Nature
4. Landscapes
5. Flowers
6. Ocean
7. Birds
8. Travel
9. Cities
10. Architecture
11. Landmarks
12. Food
13. Art
14. Fantasy
15. Space
16. Transportation
17. People
18. Sports
19. Seasons
20. Holidays
21. Vintage
22. Abstract
23. Cozy
24. Cartoon
25. Others

Classification principles:

1. Identify the main visual subject first.
2. The main subject is more important than the background.
3. Use Pets for domestic companion animals such as cats and dogs.
4. Use Animals for wildlife and general animals.
5. Use Birds when a bird is the main subject.
6. Use Ocean for ocean, beach, underwater scenes, and marine environments when the environment is the main theme.
7. Use Nature for forests, trees, plants, waterfalls, and natural ecosystems.
8. Use Landscapes for scenic panoramic views such as mountains, lakes, valleys, countryside, and scenic sunsets.
9. Use Landmarks for famous recognizable landmarks.
10. Use Architecture for buildings and structures that are not primarily famous landmarks.
11. Use Travel for destination-oriented travel scenes that are not better represented by Cities, Landmarks, Ocean, Nature, or Landscapes.
12. Use Food when food or drinks are the main visual subject.
13. Use Art for paintings and fine-art compositions.
14. Use Fantasy for dragons, unicorns, fairies, magic, mythical creatures, and fantasy worlds.
15. Use Space for planets, galaxies, astronauts, stars, and outer space.
16. Use Transportation for cars, trains, airplanes, ships, bicycles, motorcycles, buses, etc.
17. Use People for portraits and human-centered scenes unless a more specific category such as Sports, Space, or Holidays applies.
18. Use Sports for recognizable sporting activities.
19. Use Seasons when the main theme is a season such as autumn, winter, spring, or summer.
20. Use Holidays for clearly recognizable holiday themes such as Christmas, Halloween, Easter, New Year, etc.
21. Use Vintage when the main theme is historical, retro, nostalgic, or vintage imagery, not merely because of a warm color filter.
22. Use Abstract for non-representational visual compositions, geometric patterns, textures, and mandalas.
23. Use Cozy for warm, comfortable lifestyle or interior scenes when no more specific category dominates.
24. Use Cartoon for cartoon, anime, comic, and illustration-oriented imagery when the illustration style itself is the main theme.
25. Use Others only when none of the other categories can reasonably represent the image.

When multiple categories are possible, use this priority:

main subject
>
specific semantic category
>
famous landmark
>
scene/environment
>
style
>
mood

Do not classify solely based on color palette or image aesthetic.

Do not infer categories from text unless the visual content supports them.

Return valid JSON only.
```

---

# 8. 推荐 User Prompt

每次传图片时，User Prompt 可以非常简单：

```text
Classify this image according to the jigsaw puzzle category specification.

Return exactly one primary tag.

Analyze the image carefully before choosing the tag.
```

图片直接作为 Ollama 的 `images` 输入。

---

# 9. 推荐 JSON Schema

建议不要仅仅在 Prompt 里要求 JSON。

直接让 Ollama 用 `format` 传 JSON Schema。

```json
{
  "type": "object",
  "properties": {
    "tag": {
      "type": "string",
      "enum": [
        "Animals",
        "Pets",
        "Nature",
        "Landscapes",
        "Flowers",
        "Ocean",
        "Birds",
        "Travel",
        "Cities",
        "Architecture",
        "Landmarks",
        "Food",
        "Art",
        "Fantasy",
        "Space",
        "Transportation",
        "People",
        "Sports",
        "Seasons",
        "Holidays",
        "Vintage",
        "Abstract",
        "Cozy",
        "Cartoon",
        "Others"
      ]
    },
    "confidence": {
      "type": "number",
      "minimum": 0,
      "maximum": 1
    },
    "subject": {
      "type": "string"
    },
    "scene": {
      "type": "string"
    },
    "reason": {
      "type": "string"
    }
  },
  "required": [
    "tag",
    "confidence",
    "subject",
    "scene",
    "reason"
  ]
}
```

Ollama 官方目前支持这种 JSON Schema structured output，也支持直接通过 Python API 的 `format` 参数传 schema；官方建议 `temperature=0`。

---

# 10. 推荐 Python 调用方式

```python
from ollama import chat
import json

MODEL = "qwen3-vl:8b"

SYSTEM_PROMPT = """PASTE YOUR SYSTEM PROMPT HERE"""

SCHEMA = {
    "type": "object",
    "properties": {
        "tag": {
            "type": "string",
            "enum": [
                "Animals",
                "Pets",
                "Nature",
                "Landscapes",
                "Flowers",
                "Ocean",
                "Birds",
                "Travel",
                "Cities",
                "Architecture",
                "Landmarks",
                "Food",
                "Art",
                "Fantasy",
                "Space",
                "Transportation",
                "People",
                "Sports",
                "Seasons",
                "Holidays",
                "Vintage",
                "Abstract",
                "Cozy",
                "Cartoon",
                "Others"
            ]
        },
        "confidence": {
            "type": "number",
            "minimum": 0,
            "maximum": 1
        },
        "subject": {
            "type": "string"
        },
        "scene": {
            "type": "string"
        },
        "reason": {
            "type": "string"
        }
    },
    "required": [
        "tag",
        "confidence",
        "subject",
        "scene",
        "reason"
    ]
}

def classify_image(image_path: str):
    response = chat(
        model=MODEL,
        messages=[
            {
                "role": "system",
                "content": SYSTEM_PROMPT,
            },
            {
                "role": "user",
                "content": (
                    "Classify this image according to the jigsaw puzzle "
                    "category specification. Return exactly one primary tag."
                ),
                "images": [image_path],
            },
        ],
        format=SCHEMA,
        options={
            "temperature": 0,
        },
    )

    return json.loads(response.message.content)


result = classify_image("./example.jpg")
print(json.dumps(result, ensure_ascii=False, indent=2))
```

---

# 11. 生产环境建议

如果你准备一次性给几万张甚至几十万张图片打标，我建议最终数据库不要只存 `tag`。

最少保存：

```json
{
  "image_id": "abc123",
  "tag": "Pets",
  "confidence": 0.96,
  "subject": "cat",
  "scene": "indoor home",
  "model": "qwen3-vl:8b",
  "prompt_version": "jigsaw-tag-v1.0",
  "review_required": false
}
```

这样以后换模型或者调整分类规则时，可以重新跑一遍，而不会丢失旧结果。

推荐：

```text
confidence >= 0.90
    → 自动通过

0.75 <= confidence < 0.90
    → 正常入库，但标记 low_confidence

confidence < 0.75
    → 人工审核

Others
    → 单独进入人工审核池
```

尤其建议把 `Others` 做成一个非常重要的“异常检测池”。

如果某一批图片里：

```text
Others = 2%
```

基本正常。

如果突然：

```text
Others = 18%
```

通常意味着：

- 新图片类型发生变化
- Prompt 有问题
- 模型理解出现问题
- 分类体系漏掉了某个高频主题

所以不要让 Others 无限膨胀。

---

# 12. 一个很重要的产品层建议

**不要把 `confidence` 直接当成“模型正确率”。**

例如：

```text
tag = Pets
confidence = 0.98
```

只代表模型自己认为这个判断很明确，不代表它真的 98% 正确。

真正上线之前，最好人工抽查每个类别，例如：

```text
Animals       100 images
Pets          100 images
Nature        100 images
...
```

统计每一类真正的准确率。

尤其应该重点检查这些容易混淆的组合：

```text
Nature vs Landscapes
Travel vs Cities
Architecture vs Landmarks
Animals vs Pets
Animals vs Birds
Ocean vs Landscapes
Seasons vs Nature
Cozy vs Food
Cartoon vs Fantasy
Art vs Abstract
```

这几组会比“猫到底是不是 Pets”这种简单样本更值得测试。

---

# 13. V1 最终标准

你的整个分类系统可以简单概括为：

```text
                IMAGE
                  │
                  ▼
          Identify main subject
                  │
       ┌──────────┴──────────┐
       │                     │
  Clear subject         No clear subject
       │                     │
       ▼                     ▼
 Specific category      Scene / Theme
       │                     │
       └──────────┬──────────┘
                  ▼
           Check special cases
                  │
                  ▼
        Select exactly ONE tag
                  │
                  ▼
       Confidence + Review flag
```

最终目标不是让 AI “描述图片”，而是让 AI **稳定地把图片压缩到一个固定的商业分类体系里**。

对于你的 Jigsaw Puzzle App，这比让模型输出几十个自由 Tag 更实用，因为前台筛选、推荐、统计和后续运营都能直接复用这 25 个枚举值。