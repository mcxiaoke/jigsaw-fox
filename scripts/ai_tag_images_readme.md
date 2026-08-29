# Jigsaw Puzzle Image Tagger — Batch Edition

本工具用于本地使用 **Ollama + Qwen3-VL 4B** 给 Jigsaw Puzzle 图片自动分类。

针对你的使用场景，默认设计为：

- 21 个固定分类
- 每张图片只能有 1 个 Primary Tag
- 默认 4 张图片 / 请求
- 默认模型 `qwen3-vl:4b`
- 输出 `tags.json`
- 增量处理
- 支持中断后继续
- 使用 SHA-1 判断图片是否已经处理
- 每个成功 batch 后立即保存
- 低置信度和 `Others` 自动标记人工复核
- 最后输出 21 个分类的数量统计

---

## 1. 21 个固定分类

```text
Animals          动物
Pets             宠物
Nature           自然
Landscapes       风景
Flowers          花卉
Ocean            海洋
Birds            鸟类
Cities           城市
Architecture     建筑
Food             美食
Art              艺术
Fantasy          奇幻
Space            太空
Transportation   交通
People           人物
Sports           运动
Seasons          四季
Holidays         节日
Abstract         抽象
Cartoon          卡通
Others           其他
```

### 特别说明

这里已经按照你的要求删除：

- Travel
- Landmarks
- Vintage
- Cozy

同时，原来的 `Landmarks` 不再单独分类。

**著名地标统一归入 `Architecture`。**

例如：

```text
Eiffel Tower        -> Architecture
Big Ben             -> Architecture
Taj Mahal           -> Architecture
Great Wall          -> Architecture
Neuschwanstein      -> Architecture
```

这样可以明显减少 AI 在 `Travel / Cities / Architecture / Landmarks` 之间摇摆。

---

## 2. 分类规则

### Animals

野生动物、动物群、动物自然场景。

例如：

```text
Lion
Tiger
Elephant
Giraffe
Bear
Deer
Fox
Zebra
```

不包括：

```text
Cat / Dog / Rabbit -> Pets
Eagle / Owl        -> Birds
Whale / Dolphin    -> Ocean
Dragon / Unicorn   -> Fantasy
```

---

### Pets

家庭宠物：

```text
Cats
Dogs
Rabbits
Hamsters
Guinea pigs
Domestic pets
```

例如：

```text
cat in a house      -> Pets
dog on a beach     -> Pets
rabbit in a garden -> Pets
```

但是：

```text
dog is tiny, beach dominates -> Ocean
cat is tiny, garden dominates -> Nature / Flowers
```

原则是 **主要视觉主体优先**。

---

### Nature

自然生态和自然元素：

```text
Forest
Trees
Plants
Waterfalls
Nature scenes
Natural ecosystems
```

例如：

```text
dense forest       -> Nature
waterfall          -> Nature
forest with trees  -> Nature
```

---

### Landscapes

宏观风景：

```text
Mountains
Lakes
Valleys
Countryside
Cliffs
Panoramic scenic views
```

例如：

```text
mountain + lake + sunset -> Landscapes
wide countryside view    -> Landscapes
large valley panorama    -> Landscapes
```

简单规则：

```text
森林/植物本身 -> Nature
宏观景观视角 -> Landscapes
```

---

### Flowers

花是主要视觉主体：

```text
Roses
Tulips
Sunflowers
Lavender
Flower bouquets
Flower fields
Floral arrangements
```

花园里如果：

```text
flowers dominate -> Flowers
house/building dominates -> Architecture
```

---

### Ocean

海洋相关：

```text
Ocean
Sea
Beach
Waves
Underwater
Coral reefs
Marine environments
```

例如：

```text
tropical beach -> Ocean
underwater coral reef -> Ocean
ocean waves -> Ocean
```

海里出现一条船时：

```text
ship dominates -> Transportation
ocean dominates -> Ocean
```

---

### Birds

鸟类独立分类：

```text
Eagle
Owl
Parrot
Flamingo
Swan
Peacock
Penguin
```

只要鸟是主要主体：

```text
bird in forest -> Birds
eagle on mountain -> Birds
```

如果鸟非常小、整个图片明显是宏观风景：

```text
tiny birds + large mountain view -> Landscapes
```

---

### Cities

城市环境：

```text
City streets
City life
Downtown
City skyline
Urban scenes
```

例如：

```text
New York skyline -> Cities
Tokyo street -> Cities
London city scene -> Cities
```

但如果画面重点是一栋著名建筑：

```text
Eiffel Tower -> Architecture
```

---

### Architecture

建筑和结构。

包括：

```text
Houses
Churches
Bridges
Castles
Towers
Mansions
Buildings
Famous landmarks
```

### 重要

这个版本没有 `Landmarks` 分类。

因此：

```text
Eiffel Tower -> Architecture
Big Ben -> Architecture
Taj Mahal -> Architecture
Colosseum -> Architecture
Great Wall -> Architecture
```

这样可以降低模型边界误判。

---

### Food

食物/饮品是主要主体：

```text
Pizza
Sushi
Cake
Coffee
Bread
Fruit
Desserts
Restaurant dishes
```

---

### Art

图片本身主要是一件艺术作品：

```text
Oil painting
Watercolor
Classic painting
Fine art
Artwork
```

例如：

```text
Mona Lisa -> Art
Oil painting of a landscape -> Art
Watercolor illustration -> Art
```

但如果是明显卡通/动漫插画：

```text
Cartoon -> Cartoon
```

如果是无具象图形：

```text
Abstract -> Abstract
```

---

### Fantasy

幻想世界和神话生物：

```text
Dragon
Unicorn
Fairy
Wizard
Magic
Mythical creatures
Fantasy worlds
```

例如：

```text
dragon in magical castle -> Fantasy
unicorn -> Fantasy
fairy forest -> Fantasy
```

现实动物只是画得很梦幻：

```text
stylized cat -> Pets
```

不要因为画风“梦幻”就变成 Fantasy。

---

### Space

宇宙：

```text
Galaxy
Planets
Nebula
Stars
Astronauts
Spacecraft
Outer space
```

---

### Transportation

交通工具是主要主体：

```text
Cars
Airplanes
Trains
Ships
Boats
Bicycles
Motorcycles
Buses
Trams
```

例如：

```text
sports car -> Transportation
airplane -> Transportation
steam train -> Transportation
```

---

### People

人物为主要主体：

```text
Portrait
People
Family
Groups
Lifestyle
Human activities
```

但有明确专门主题时优先：

```text
football player during match -> Sports
astronaut -> Space
Santa Claus -> Holidays
```

---

### Sports

明确的体育活动：

```text
Football
Basketball
Tennis
Baseball
Golf
Skiing
Surfing
Running
Cycling
```

重点是“运动行为”。

---

### Seasons

图片的核心主题是明确的季节：

```text
Spring
Summer
Autumn
Winter
```

例如：

```text
autumn forest covered with fall leaves -> Seasons
snowy winter village -> Seasons
spring blossom landscape -> Seasons
```

注意：

**不要因为颜色像秋天就使用 Seasons。**

例如普通绿色森林里只有几片黄叶：

```text
-> Nature
```

---

### Holidays

只有出现明确节日符号时使用：

```text
Christmas
Halloween
Easter
New Year
Valentine's Day
Thanksgiving
Lunar New Year
```

例如：

```text
Christmas tree -> Holidays
Santa Claus -> Holidays
Halloween pumpkins -> Holidays
```

普通温馨壁炉：

```text
-> 不使用 Holidays
```

---

### Abstract

非具象内容：

```text
Geometric patterns
Textures
Shapes
Mandala
Abstract art
Non-representational compositions
```

如果图中明确出现：

```text
cat
house
car
flower
```

即使艺术风格很强，也优先按照主体分类，而不是 Abstract。

---

### Cartoon

卡通/动漫/漫画/儿童插画：

```text
Cartoon characters
Anime-style art
Comic art
Children's illustration
Character illustration
```

只有当“卡通/插画形式”是主要卖点时使用。

例如：

```text
cute cartoon character -> Cartoon
anime scene -> Cartoon
children's illustration -> Cartoon
```

如果是：

```text
cartoon cat
```

通常：

```text
cat is the main subject -> Pets
character illustration itself is the main theme -> Cartoon
```

---

### Others

真正无法稳定归入 20 个主题时使用。

不要把：

```text
两个类别都差不多
```

直接当成 Others。

只有：

```text
非常小众
混合且没有明显主题
完全不适合现有分类
```

才使用 Others。

---

# 3. 分类总优先级

模型遇到复杂图片时，遵循：

```text
主要视觉主体
        ↓
明确语义主题
        ↓
场景
        ↓
艺术/插画风格
        ↓
Others
```

几个非常重要的例子：

```text
cat + beach
    -> Pets

eagle + mountains
    -> Birds

car + city
    -> Transportation

Eiffel Tower + Paris
    -> Architecture

mountain + lake + sunset
    -> Landscapes

forest + small deer
    -> Nature 或 Animals
```

当主体非常明显时：

**Subject > Background**

---

# 4. 安装

确保电脑已经安装并运行 Ollama。

安装 Python 包：

```bash
pip install ollama
```

下载模型：

```bash
ollama pull qwen3-vl:4b
```

可以测试：

```bash
ollama list
```

应该能看到：

```text
qwen3-vl:4b
```

---

# 5. 最简单运行

假设：

```text
images/
├── cat01.jpg
├── cat02.jpg
├── flowers/
│   ├── rose.jpg
│   └── tulip.jpg
└── cities/
    └── paris.jpg
```

执行：

```bash
python tag_images_batch.py ./images
```

默认：

```text
model      = qwen3-vl:4b
batch size = 4
output     = tags.json
```

---

# 6. 输出 tags.json

结果类似：

```json
[
  {
    "path": "cat01.jpg",
    "sha1": "abc123...",
    "tag": "Pets",
    "confidence": 0.97,
    "subject": "cat",
    "scene": "indoor home",
    "reason": "The cat is the clear main subject.",
    "review_required": false,
    "model": "qwen3-vl:4b",
    "taxonomy_version": "jigsaw-tag-v1.0-21"
  },
  {
    "path": "cities/paris.jpg",
    "sha1": "def456...",
    "tag": "Architecture",
    "confidence": 0.94,
    "subject": "Eiffel Tower",
    "scene": "Paris",
    "reason": "The famous landmark is the main visual subject.",
    "review_required": false,
    "model": "qwen3-vl:4b",
    "taxonomy_version": "jigsaw-tag-v1.0-21"
  }
]
```

---

# 7. 增量更新

这是这个脚本比较重要的功能。

第一次：

```bash
python tag_images_batch.py ./images
```

假设处理：

```text
1000 images
```

后来新增：

```text
100 images
```

再次执行同样命令：

```bash
python tag_images_batch.py ./images
```

脚本会：

```text
已有 1000
跳过 1000

新增 100
处理 100
```

不会重新跑全部图片。

---

# 8. 图片移动/改名

脚本保存：

```text
sha1
```

所以：

```text
images/cat.jpg
```

改成：

```text
images/pets/cat001.jpg
```

只要图片内容没有变化，SHA-1 一样，脚本也能识别为已经处理过。

---

# 9. 强制重新分类

修改了 Prompt 或模型之后，可以：

```bash
python tag_images_batch.py ./images --force
```

这样所有图片都会重新分类。

建议改变分类体系时，一定修改：

```text
taxonomy_version
```

例如：

```text
jigsaw-tag-v1.0-21
```

下一版：

```text
jigsaw-tag-v1.1-21
```

这样以后你能知道每条数据是用哪个分类版本生成的。

---

# 10. Batch Size

默认：

```bash
--batch-size 4
```

你的 RTX 4070 已经测试过 4 张 Qwen3-VL 可以工作，所以建议直接保持：

```bash
python tag_images_batch.py ./images --batch-size 4
```

如果某些图片非常大、显存压力上升，可以尝试：

```bash
python tag_images_batch.py ./images --batch-size 2
```

不建议为了追求速度盲目提高 batch。

---

# 11. 更换模型

默认：

```bash
--model qwen3-vl:4b
```

例如：

```bash
python tag_images_batch.py ./images --model qwen3-vl:8b
```

但你的任务是比较简单的 21 类主题分类，4B 已经是很合理的起点。

---

# 12. 置信度与人工审核

脚本会生成：

```text
review_required
```

规则：

```text
confidence < 0.75
        OR
tag == Others
```

则：

```json
"review_required": true
```

例如：

```json
{
  "tag": "Seasons",
  "confidence": 0.68,
  "review_required": true
}
```

这类图片建议人工检查。

---

# 13. 为什么不让 AI 自动创造 Tag

不要让模型输出：

```text
"Cozy"
"Travel"
"Vintage"
"Scenery"
"Wildlife"
"Flowers & Garden"
```

否则很快会出现：

```text
Nature
nature
Nature Scene
Scenery
Landscape
Landscapes
Wildlife
Animals
```

数据库会变得非常难管理。

本脚本强制使用：

```text
21 个 enum
```

模型只能从其中选择。

---

# 14. 最终运行推荐

你的实际环境建议就用这一条：

```bash
python tag_images_batch.py ./images \
    --model qwen3-vl:4b \
    --batch-size 4 \
    --output tags.json
```

跑完以后，输出会包含：

```text
Processed
Skipped
Failed batches
Total records
Review
```

以及 21 个分类的数量统计。

---

# 15. 后续增量工作流

推荐固定这样使用：

### 第一次

```bash
python tag_images_batch.py ./images
```

### 新增图片

直接再跑：

```bash
python tag_images_batch.py ./images
```

### 修改 Prompt / 分类规则

升级：

```text
taxonomy_version
```

然后：

```bash
python tag_images_batch.py ./images --force
```

### 只想人工检查问题图片

筛选：

```json
"review_required": true
```

以及：

```json
"tag": "Others"
```

即可。
