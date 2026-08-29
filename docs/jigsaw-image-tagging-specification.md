# Jigsaw Puzzle Image Tagging Specification v1.1

> 变更记录（v1.0 → v1.1）
> - 移除 `Travel` / `Vintage` / `Cozy`：三者属"意图/年代/氛围"维度，无法由像素稳定判定，已从 AI 自动打标中删除，仅作为**用户层筛选**（见附录 A）。
> - 移除 `Landmarks`，并入 `Architecture`：著名地标不再单列，统一归 "Architecture / 建筑"。
> - 对 5 个"风格/符号/属性"类标签（`Art` / `Seasons` / `Holidays` / `Abstract` / `Cartoon`）增加**护栏规则**：必须基于图内内容证据，禁止仅凭观感/色调判定。
> - 标签总数：25 → 21。

## 1. 总体规则

每张图片只分配 **1 个 Primary Tag**。

AI 不允许自己创建新的分类名称，只能从以下 21 个固定 Tag 中选择。

### 标准 Tag 列表

> 类型说明：
> - **主体/场景**：图中可"看见"的实体或场景，AI 直接判定，准确率高。
> - **风格/符号/属性**：描述"画风/符号/时间属性"，需内容证据，且必须服从护栏（见第 3 章对应小节）。

| ID | Tag | 中文 | 类型 | 核心定义 |
|---|---|---|---|---|
| 01 | Animals | 动物 | 主体 | 野生动物、动物群、动物自然场景（不含家庭宠物/鸟类，见 Pets/Birds） |
| 02 | Pets | 宠物 | 主体 | 猫、狗、兔子、仓鼠等家庭宠物 |
| 03 | Nature | 自然 | 场景 | 森林、植物、自然生态、自然元素 |
| 04 | Landscapes | 风景 | 场景 | 山川、湖泊、田野、峡谷等宏观景观 |
| 05 | Flowers | 花卉 | 主体 | 花朵、花束、花田、园艺植物 |
| 06 | Ocean | 海洋 | 场景/主体 | 海洋、海滩、海浪、水下、海洋生态 |
| 07 | Birds | 鸟类 | 主体 | 鹰、猫头鹰、鹦鹉、火烈鸟等鸟类 |
| 08 | Cities | 城市 | 场景 | 城市街景、城市生活、城市天际线 |
| 09 | Architecture | 建筑 | 主体 | 建筑本体、住宅、教堂、桥梁、城堡、以及著名地标（见护栏） |
| 10 | Food | 美食 | 主体 | 食物、甜点、料理、餐桌、美食摄影 |
| 11 | Art | 艺术 | 风格 | 绘画、艺术作品、艺术风格、经典名画（需护栏） |
| 12 | Fantasy | 奇幻 | 主体 | 魔法、龙、独角兽、精灵、幻想世界 |
| 13 | Space | 太空 | 主体/场景 | 宇宙、星球、银河、宇航员 |
| 14 | Transportation | 交通 | 主体 | 汽车、飞机、火车、轮船、自行车等 |
| 15 | People | 人物 | 主体 | 人像、人物活动、人物生活场景 |
| 16 | Sports | 运动 | 活动 | 足球、篮球、网球、滑雪等运动 |
| 17 | Seasons | 四季 | 属性 | 春、夏、秋、冬及明显季节场景（需护栏） |
| 18 | Holidays | 节日 | 符号 | 圣诞节、万圣节、复活节、新年等（需护栏） |
| 19 | Abstract | 抽象 | 风格 | 抽象艺术、几何图案、纹理、非具象视觉（需护栏） |
| 20 | Cartoon | 卡通 | 风格 | 卡通、动漫风、漫画、儿童插画（需护栏） |
| 21 | Others | 其他 | 兜底 | 无法稳定归入上述主题的小众内容 |

---

# 2. Tag 判定原则

AI 的任务不是判断"这张图看起来像什么"，而是判断：

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
- 海边度假场景 → Ocean

### Priority 3：著名地点归入 Architecture

原 `Landmarks` 已并入 `Architecture`。如果图片的核心价值在于一个**著名且易识别的地标建筑**，仍使用 `Architecture`，但需明确它是"以地标建筑为主体"的建筑图。

例：

- 埃菲尔铁塔 → Architecture
- 泰姬陵 → Architecture
- 长城 → Architecture
- 普通城堡 → Architecture

> 不再单列 `Landmarks`；判断要点是"建筑/地标本身是图片卖点"，而非"这是哪里"。

### Priority 4：艺术/风格

如果图片主要是一幅艺术作品、插画或抽象作品：

- 名画 → Art
- 奇幻插画 → Fantasy
- 卡通插画 → Cartoon
- 抽象图案 → Abstract

> 风格类标签（Art / Cartoon / Abstract）**必须服从护栏**（见第 3 章）：仅当图中确有"非照片的绘画/插画/卡通笔触"或"无具象主体的图案"等内容证据时才使用，禁止仅凭画风艺术感或色调归类。

### Priority 5：属性类（Seasons / Holidays）

季节与节日属于"属性/符号"维度，不是独立主体：

- 仅当"季节本身就是主题"（如满屏秋叶、积雪冬景）才用 `Seasons`，否则归入 `Nature` / `Landscapes`。
- 仅当图中存在**明确节日符号**（圣诞树、南瓜灯、复活节彩蛋等）才用 `Holidays`，否则归入对应主体/场景类。

### 已移除：氛围维度（Cozy）

原 `Cozy / 温馨` 已从 AI 打标移除——"温暖舒适"是氛围而非图中物体，AI 极易误判。若图片核心价值是室内温馨场景，请将其作为**用户层筛选**（见附录 A "Interiors / 室内家居"），AI 打标时仍按具体主体（如 `Food` / `Architecture`）归类。

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

因为"猫"作为主体比"森林"更明确。

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

Landscapes = "风景画面 / 景观视角"

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

> "A beautiful scenic view of ..."

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

## 08 Cities / 城市

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

## 09 Architecture / 建筑（含著名地标）

### 使用条件

重点是建筑本身或著名地标：

- Houses
- Castles
- Churches
- Bridges
- Towers
- Mansions
- Buildings
- Interior architecture
- **著名地标（Eiffel Tower / Big Ben / Statue of Liberty / Taj Mahal / Great Wall / Colosseum / Sydney Opera House 等）**

### 与 Cities 区别

城市街景 / 城市生活感 → Cities

建筑本体是视觉核心（无论普通还是著名） → Architecture

例如：

普通城堡 → Architecture

Neuschwanstein Castle → Architecture

埃菲尔铁塔 → Architecture

### 重要

原 `Landmarks` 已并入本类。判断核心是"建筑/地标本身是图片卖点"，而不是"这是哪座城市"。

---

## 10 Food / 美食

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

整个咖啡馆氛围（无明确食物主体） → 按建筑/场景归类（AI 不判 Cozy；用户层可归 Interiors）

---

## 11 Art / 艺术（风格类 · 需护栏）

### 使用条件

图片主要是：

- Fine art
- Oil painting
- Watercolor
- Classic paintings
- Famous artworks
- Artistic compositions

如果图片明显是"艺术作品"，而不是现实摄影，则优先 Art。

### 护栏（必须遵守）

- 仅当图中确有**非照片的绘画/插画笔触/材质证据**时才用 Art。
- 有明确猫/花/建筑主体、只是"画风比较艺术"的现实摄影 → 仍按主体分类（Animals / Flowers / Architecture 等）。
- 禁止仅凭"色调复古/滤镜/艺术感"判定为 Art。

---

## 12 Fantasy / 奇幻

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

卡通龙 → Fantasy（题材是幻想）

卡通猫 → Cartoon / Pets（题材是宠物，形式是卡通）

---

## 13 Space / 太空

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

## 14 Transportation / 交通

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

## 15 People / 人物

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

## 16 Sports / 运动

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

## 17 Seasons / 四季（属性类 · 需护栏）

### 使用条件

图片主要通过季节特征表达主题：

- Spring
- Summer
- Autumn
- Winter
- Snowy winter
- Autumn foliage
- Spring blossoms

### 护栏（必须遵守）

- 仅当"季节本身就是图片主题"时使用（例如满屏秋叶、积雪冬景、盛大开春花海）。
- 只是普通森林/风景恰好有少量秋叶或雪 → 归 `Nature` / `Landscapes`，**不要**用 Seasons。
- Seasons 是 `Nature` / `Landscapes` 的**属性**，不是独立主体；不确定时归 Nature/Landscapes。

### 判断方法

如果用户更可能因为"这是秋天"而选择它：

→ Seasons

如果只是普通森林恰好有一些秋叶：

→ Nature

---

## 18 Holidays / 节日（符号类 · 需护栏）

### 使用条件

图中存在**明确节日符号**：

- Christmas（圣诞树、彩灯、礼物袜）
- Halloween（南瓜灯、鬼怪装饰）
- Easter（彩蛋、兔子）
- New Year
- Valentine's Day
- Thanksgiving
- Hanukkah
- Lunar New Year

### 护栏（必须遵守）

- 必须有可见的节日符号证据，不能仅凭"感觉像过节"或红金配色判定。
- 没有明显节日符号的普通装饰/温馨场景 → 归对应主体/场景类（如 Food / Architecture），**不要**用 Holidays。
- Holidays 优先于 Seasons（见 Rule E）。

### 边界案例

一棵普通圣诞树：

→ Holidays

一间温暖的房间里摆着普通装饰，但没有明显节日元素：

→ 按主体/场景归类（AI 不判 Cozy）

---

## 19 Abstract / 抽象（风格类 · 需护栏）

### 使用条件

图片缺少明显具象主体，主要表现：

- Abstract art
- Geometric patterns
- Shapes
- Textures
- Mandala
- Decorative patterns

### 护栏（必须遵守）

- 仅当图中**确实无具象主体**（纯几何/图案/纹理/曼陀罗）时使用。
- 有明确猫/花/建筑主体，只是画风比较抽象 → 仍按主体分类。
- 若连"图案/装饰"都难以界定、主题混杂 → 用 `Others`，不要硬套 Abstract。

### 不应该使用

有明确猫/花/建筑主体，只是画风比较艺术：

→ 仍按主体分类

---

## 20 Cartoon / 卡通（风格类 · 需护栏）

### 使用条件

图片明显属于：

- Cartoon
- Anime-style
- Comic
- Children's illustration
- Cute illustration
- Hand-drawn character art

### 护栏（必须遵守）

- 仅当图中确有**卡通/动漫/漫画/手绘插画笔触**时才用 Cartoon。
- 现实照片（哪怕内容可爱） → 按主体分类（Pets / Animals 等），不要因"可爱"判 Cartoon。
- 卡通化的幻想龙 → Fantasy（题材优先于表现形式）。

### 边界案例

一只卡通猫：

优先判断：

如果图片卖点是"猫" → Pets

如果图片卖点是"卡通角色/插画风" → Cartoon

如果图片是卡通化的幻想龙：

→ Fantasy

---

## 21 Others / 其他

只有在以下情况下使用：

1. 无法稳定归入其他 20 类
2. 内容非常小众
3. 图片主题混杂且没有明显主次
4. 模型视觉信息不足，无法可靠判断

### 重要规则

Others 不是"模型不知道"。

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
| 埃菲尔铁塔 | Architecture |
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
| 几何图案 | Abstract |
| 卡通角色 | Cartoon |

> 已移除项处理：旅行感图 → 按 Cities/Architecture/Landscapes/Ocean 归类；复古观感图 → 按主体归类（不用 Vintage）；温馨室内图 → 按 Food/Architecture 等主体归类（用户层可归 Interiors）。

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

## Rule B：地标归入建筑

> 著名地标 → Architecture（不再单列 Landmarks）

例：

Eiffel Tower + Paris  
→ Architecture

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

## Rule D：明确主题优先于风格/氛围

> Subject > Style / Mood

例如：

咖啡 + 温暖木屋

如果咖啡/食物明显是核心：

→ Food

如果重点是整个室内环境（无明确食物主体）：

→ Architecture（AI 不判 Cozy；用户层可归 Interiors）

---

## Rule E：节日主题优先

如果出现非常明确的节日符号：

> Holidays > Seasons

例如：

圣诞树 + 壁炉  
→ Holidays

而不是 Seasons。

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
Cities
Architecture
Food
Art
Fantasy
Space
Transportation
People
Sports
Seasons
Holidays
Abstract
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
8. Cities
9. Architecture
10. Food
11. Art
12. Fantasy
13. Space
14. Transportation
15. People
16. Sports
17. Seasons
18. Holidays
19. Abstract
20. Cartoon
21. Others

Classification principles:

1. Identify the main visual subject first.
2. The main subject is more important than the background.
3. Use Pets for domestic companion animals such as cats and dogs.
4. Use Animals for wildlife and general animals.
5. Use Birds when a bird is the main subject.
6. Use Ocean for ocean, beach, underwater scenes, and marine environments when the environment is the main theme.
7. Use Nature for forests, trees, plants, waterfalls, and natural ecosystems.
8. Use Landscapes for scenic panoramic views such as mountains, lakes, valleys, countryside, and scenic sunsets.
9. Use Architecture for buildings, structures, bridges, castles, and FAMOUS LANDMARKS (Eiffel Tower, Taj Mahal, Great Wall, etc.) when the building/landmark itself is the main subject.
10. Use Cities for city skylines, urban streets, and city life.
11. Use Food when food or drinks are the main visual subject.
12. Use Art ONLY when the image is clearly a painting, fine-art, or illustration (non-photographic evidence). Do NOT use Art merely because a photo looks artistic or has a retro filter; if a clear subject exists, classify by that subject.
13. Use Fantasy for dragons, unicorns, fairies, magic, mythical creatures, and fantasy worlds.
14. Use Space for planets, galaxies, astronauts, stars, and outer space.
15. Use Transportation for cars, trains, airplanes, ships, bicycles, motorcycles, buses, etc.
16. Use People for portraits and human-centered scenes unless a more specific category such as Sports, Space, or Holidays applies.
17. Use Sports for recognizable sporting activities.
18. Use Seasons ONLY when the season itself is the main theme (heavy autumn foliage, snowy winter, spring blossoms). Otherwise classify as Nature or Landscapes.
19. Use Holidays ONLY when clear holiday symbols are present (Christmas tree, pumpkin, Easter egg, etc.). Do NOT use Holidays based on color or mood alone.
20. Use Abstract ONLY when there is genuinely no recognizable subject (geometric patterns, textures, mandala). If a clear subject exists, classify by that subject.
21. Use Cartoon ONLY when the image clearly uses cartoon / anime / comic / hand-drawn illustration style. Do NOT use Cartoon merely because the content is cute; classify cute real photos by their subject.
22. Use Others only when none of the other categories can reasonably represent the image.

When multiple categories are possible, use this priority:

main subject
>
specific semantic category
>
scene/environment
>
style (only with content evidence)
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
        "Cities",
        "Architecture",
        "Food",
        "Art",
        "Fantasy",
        "Space",
        "Transportation",
        "People",
        "Sports",
        "Seasons",
        "Holidays",
        "Abstract",
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
                "Cities",
                "Architecture",
                "Food",
                "Art",
                "Fantasy",
                "Space",
                "Transportation",
                "People",
                "Sports",
                "Seasons",
                "Holidays",
                "Abstract",
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
  "prompt_version": "jigsaw-tag-v1.1",
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

尤其建议把 `Others` 做成一个非常重要的"异常检测池"。

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

**不要把 `confidence` 直接当成"模型正确率"。**

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
Animals vs Pets
Animals vs Birds
Ocean vs Landscapes
Seasons vs Nature
Art vs Abstract
Art vs Cartoon
Cartoon vs Fantasy
Holidays vs Seasons
Abstract vs Others
```

这几组会比"猫到底是不是 Pets"这种简单样本更值得测试。

---

# 13. V1.1 最终标准

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
        Style/Symbol guardrails
        (Art/Seasons/Holidays/Abstract/Cartoon
         need CONTENT evidence)
                  │
                  ▼
        Select exactly ONE tag
                  │
                  ▼
       Confidence + Review flag
```

最终目标不是让 AI "描述图片"，而是让 AI **稳定地把图片压缩到一个固定的商业分类体系里**。

对于你的 Jigsaw Puzzle App，这比让模型输出几十个自由 Tag 更实用，因为前台筛选、推荐、统计和后续运营都能直接复用这 21 个枚举值。

---

# 附录 A：用户层筛选分类（与 AI 打标解耦）

以下三类已从 AI 自动打标中移除，但可作为**用户层筛选维度**存在（由多个 AI 标签映射聚合，或作为可选的"风格"过滤）：

| 用户层筛选 | 来源 / 映射 | 说明 |
|---|---|---|
| Travel / 旅行 | Cities + Architecture + Landscapes + Ocean | "旅行目的地感"是策展概念，AI 不打标，仅作聚合筛选 |
| Vintage / 复古 | 任意 AI 标签 + 元数据标记 | 年代/怀旧是风格维度，建议用显式标记而非 AI 视觉判定 |
| Interiors / 室内家居 | Architecture（室内）+ Food（咖啡馆）等 | 替代原 Cozy；具体场景比"氛围"更易分类 |

> 推荐做法：AI 只产出上述 21 个 Primary Tag；用户层筛选 UI 在这 21 类之上做聚合/风格标记，互不污染。
