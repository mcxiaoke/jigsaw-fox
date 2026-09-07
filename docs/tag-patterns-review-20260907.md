# tag_patterns 增补提案评审（2026-09-07）

> **2026-09-07 更新：评审结论已实施。** 见文末「实施结果」章节。
> 当前 `data/taxonomy.json` 已升级到 **v3.2.0**，`tag_patterns` 全部重写，`build_taxonomy.py` 的匹配引擎改为「全词精确 → 正则最长命中（风格让位主体）」。
> 下方 1~6 节保留为评审过程记录。

---

评审对象：`temp/tag_patterns_update_20260907.json`（拟替换 `data/taxonomy.json` 的 `tag_patterns`）
生效链路：`data/taxonomy.json` → `scripts/build_taxonomy.py` → `studio/taxonomy.py` → `studio/core/tags_manager.py` / `studio/exporters/main_exporter.py` 的 `guess_tags_from_path()`

> 说明：`scripts/packaging/server.py` 走的是另一套 `ALIASES` 精确查表（先整串后分词），**不使用 tag_patterns**。本评审只针对 studio 智能目录名识别这条链路。

---

## 0. 一句话结论

词表**扩充方向对、覆盖度明显提升（15 组共约 1000 条）**，但**不能直接替换**：

1. 缺 `Others` 键 → `build_taxonomy.py` 校验直接报错，生成链断掉；
2. 匹配机制是「按组顺序首个命中」，词表变大后**冲突呈平方级放大**（实测 130 条标注目录名上准确率 74% → 69%，**不升反降**）；
3. 大量短词裸写（无边界），在真实目录名上制造了 **67/736 条误判**（`jigsaw`→`saw`→物品、`services`→`ice`→风光、`shared_preferences`→`red`→色彩）。

**建议：内容增补照单全收，但必须先做两处机制/数据修正再合入。**

---

## 1. 致命问题（阻塞合入）

### 1.1 缺少 `Others` 键

`scripts/build_taxonomy.py:76-78` 强制要求 `main_tags` 的每个 id 都在 `tag_patterns` 里有定义：

```
ValueError: tag_patterns 缺少主标签 [Others] 的模式定义
```

新文件只有 16 个键（缺 `Others`）。补回即可，建议保留原值：

```json
"Others": ["^others?$", "^misc$"]
```

### 1.2 组内重复（自检索出来的死词）

无重复项（已核对），此项 OK。

---

## 2. 系统性问题：首个命中 + 无边界 = 冲突爆炸

`studio/taxonomy.py` 生成的 `normalize_tag()` 是 **按 dict 插入顺序遍历、命中即返回**：

```python
for main_tag, patterns in _COMPILED_PATTERNS.items():
    for pat in patterns:
        if pat.search(cleaned):   # 子串匹配、re.IGNORECASE
            return main_tag
```

两个后果：

| 后果 | 机理 | 典型例子 |
|---|---|---|
| **长词被短词抢**（遮蔽） | 组序靠前的短词先命中 | `christmas_tree` → Nature(`tree`)；`easter_egg` → Food(`egg`)；`ice_cream` → Landscapes(`ice`)；`school_bus` → Structures(`school`)；`oil_painting` → Objects(`painting`)；`unicorn` → Food(`corn`)；`skyline` → Landscapes(`sky`)；`street` → Nature(`tree`) |
| **无关单词被误伤** | 无边界子串 | `jigsaw`→`saw`、`services`→`ice`、`constants`→`ant`、`chatgpt`→`hat`、`exporters`→`port`、`cardboard`→`boa`、`shared_preferences`→`red`、`embeddedpdfs`→`bed` |

本次静态扫描共发现 **106 条遮蔽**（后组 pattern 被前组 pattern 吃掉），其中约 2/3 是本次新增词带来的**新增回归**。

### 2.1 实测数据

**A. 130 条人工标注目录名测试集**（`temp/_gt.json`，覆盖 17 个主类的常见命名）

| 配置 | 准确率 |
|---|---|
| 现行 v3.1.0 / 首个命中 | 96/130 = **74%** |
| 新提案原样 / 首个命中 | 90/130 = **69%** ⬇ |
| 新提案 + 边界守卫 / 首个命中 | 103/130 = 79% |
| 新提案 / **最长命中优先** | 118/130 = **91%** |
| 新提案 + 守卫 + 最长命中 | 117/130 = 90% |

**B. 项目内 736 个真实目录名**（回归回归检测）

| 配置 | 相对现行发生归类变化的目录数 |
|---|---|
| 新提案原样 | **67**（几乎全是误判） |
| 新提案 + 边界守卫 | **26** |

> 守卫把误伤从 67 压到 26；最长命中把准确率从 69% 拉到 91%。**两者作用互补，都要做。**

---

## 3. 建议的两处机制修正（编号决策项）

### ① 【推荐】匹配策略改为「最长命中优先」（改生成器，约 10 行）

`scripts/build_taxonomy.py` 生成的 `normalize_tag()` / `infer_tags_from_path()` 由「首个命中即返回」改为「收集全部命中 → 取 pattern 最长者 → 平手按组序」：

```python
def normalize_tag(tag):
    ...
    best = (-1, None)
    for i, (main_tag, patterns) in enumerate(_COMPILED_PATTERNS.items()):
        for pat, plen in _COMPILED_PATTERNS_SIZED[main_tag]:
            if pat.search(cleaned) and plen > best[0]:
                best = (plen, main_tag)
    return best[1] or "Others"
```

收益：一次性自愈绝大多数遮蔽，数据侧不用大改。
成本：需要同步 `build_taxonomy.py` + 重跑三端生成 + `studio/test_studio.py` 回归（现有 4 条路径断言仍应通过）。

### ② 短词统一加边界守卫（改数据）

对所有「纯 `[a-z_]` 组成的裸词」自动包一层，并兼容复数：

```
flower  ->  (?<![a-z])flowers?(?![a-z])
ice     ->  (?<![a-z])ices?(?![a-z])
ant     ->  (?<![a-z])ants?(?![a-z])
```

- 已带 `\b` / `^...$` 的条目（如 `sea\b`、`^colors?$`）**保持原样，不要二次包裹**；
- 必须带 `s?` 复数尾，否则 `mountains`/`ruins`/`kittens` 会漏（实测不带复数时准确率反降 3pp）；
- 注意：`(?<![a-z])` 在 `re.IGNORECASE` 下无法区分 `snow_man`（应拦）和 `CherryBlossom`（不应拦，驼峰）。**驼峰目录名需靠「先分词再匹配」解决**，见 ③。

### ③ 【可选，第二阶段】加一层精确分词词典

参考 `scripts/packaging/server.py:match_dir_part()` 已验证的做法：目录名先按 `[^A-Za-z0-9_]+` + 驼峰切成 token，逐 token 做「小写 + 去分隔符 + 单复数归一」的**精确查表**，命中即返回；未命中再回退到正则层。
好处：驼峰、复数、连字符全支持，误伤归零。代价是生成器要改结构（把纯词 pattern 自动导出成词典）。

---

## 4. 词表逐组修正清单

### 4.1 跨组重复（后者永不生效，需二选一）

| 词 | 现归属 | 建议 |
|---|---|---|
| `wood` | Landscapes / Objects | Objects 删（或改 `wooden`、`woodwork`） |
| `arch` | Landscapes / Structures | **Landscapes 删**（`architecture` 已被误吃），或改 `natural_arch` |
| `frost` | Landscapes / Nature | 二选一，建议留 Nature（`frost` 更偏物候） |
| `mushroom` | Nature / Food | Nature 改 `wild_mushroom`，食材义留给 Food |
| `earth` | Nature / Fantasy | Nature 删（改用 `soil`/`earth_texture`），`hearth`、`earth_day` 才能归位 |
| `octopus` | Animals / Food | Food 删 |
| `bat` | Animals / Holidays | Holidays 改 `halloween_bat` |
| `market` | Cities / Structures | Structures 删（`christmas_market` 才能归 Holidays） |
| `artist` | People / Art | 二选一，建议留 People（Art 改 `painter`） |
| `lantern` | Objects / Holidays | Holidays 改 `lantern_festival` |
| `orange` | Food / Colors | Colors 加 `^...$` 锚定 |
| `elf` | Fantasy / Holidays | Holidays 改 `christmas_elf` |

### 4.2 建议删除 / 语义收窄的高危词

| 组 | 词 | 问题 |
|---|---|---|
| Structures | **`studio`** | 极危：本仓库自身目录、美术工作室、摄影棚全中招；实测 `studio`、`studio_cache`、`studio_pre_v2.3` 全被判建筑。建议删，或改 `photo_studio`/`art_studio` 并加锚定 |
| Structures | `museum` | 从 Art「搬」过来导致 `museum`→建筑；建议只留 Art |
| Structures | `office` | 与 `ice` 冲突（守卫后归建筑，语义勉强，建议改 `office_building`） |
| Structures | `bar` | 吃 `barge`（交通）、`baroque`（艺术）、`barbecue`；改 `\bbar\b` |
| Structures | `school` | 吃 `school_bus`；改 `\bschool\b` |
| Structures | `cabin` | 吃 `cabinet`；改 `\bcabin\b`（已有 bug，非本次新增） |
| Structures | `gate`/`dome`/`column` | 会吃 `aggregate`/`domestic`；加守卫 |
| Landscapes | **`ice`** | 吃 `office`/`juice`/`rice`/`dice`/`police_car`/`services`；加守卫，或改 `ice_floe`/`sea_ice`/`iceland` |
| Landscapes | **`spring`** | 吃 `spring_festival`、`spring_roll`、`spring_equinox`；**建议删**（保留 `hot_spring`） |
| Landscapes | `sky` | 吃 `skyline`、`skyscraper`；改 `sky(?!line)` 或加守卫 |
| Landscapes | `snow` | 吃 `snowman`、`snowflake`；加守卫 |
| Landscapes | `butte` | 吃 `butterfly`、`butter`；加守卫 |
| Landscapes | `field` | 吃 `flower_field`、`depth_of_field`；改 `wheat_field`/`wildflower_field` 或加守卫 |
| Landscapes | `mist` | 吃 `mistletoe`；加守卫 |
| Landscapes | `lake` | 吃 `snowflake`；加守卫 |
| Landscapes | `cave` | 吃 `crystal_cave`（奇幻）；加守卫 |
| Landscapes | `island` | 吃 `floating_island`（奇幻）；加守卫 |
| Landscapes | `wave` | 吃 `microwave`；加守卫 |
| Nature | **`tree`** | 吃 `street`、`christmas_tree`、`tree_frog`、`street_art`；加守卫 |
| Nature | `stone` | 吃 `stone_circle`；加守卫 |
| Nature | `coral` | 吃 `coral_fish`（动物）；加守卫 |
| Nature | `macro` / `texture` | 与 Composition 的 `^macro$`/`^texture$` 直接冲突，且语义属于摄影技法 → **建议从 Nature 删除** |
| Nature | `closeup` | 同上，Composition 有 `^close_up$`；建议删或统一拼写 |
| Cities | **`port`** | 吃 `transport`、`sports_car`、`portrait`、`portal`、`\bsports?\b`（庆典）；加守卫 |
| Cities | `road` | 吃 `railroad`、`roadster`、`road_bike`；加守卫 |
| Animals | **`ant`** | 吃 `constants`、`plants`、`restaurant`、`santorini`、`fantasy`、`enchanted`、`giant`、`phantom`、`santa_claus`、`romanticism`、`antique`、`tarantula`… **危害最大**；必须 `(?<![a-z])ants?(?![a-z])` |
| Animals | `moth` / `bee` / `crow` / `boa` / `bat` / `bull` / `eagle` / `pig` / `wolf` / `deer` / `otter` / `owl` / `fly` / `seal` | 分别吃 `mother`/`beer`/`crowd`/`boat`/`batch`/`bulldozer`/`beagle`/`pigeon`/`werewolf`/`reindeer`/`pottery`/`bowl`/`butterfly`/`sealed`；全部加守卫 |
| Objects | `pan` / `pot` / `pen` / `key` / `hat` / `cap` / `saw` / `bed` / `box` / `ring` / `bag` / `tool` / `cup` / `jar` | 分别吃 `expanded`/`potato`/`independence_day`/`whiskey`/`chatgpt`/`landscape`/`jigsaw`/`embeddedpdfs`/`inbox`/`rendering`/`baggage`/`tools`/`cupcake`/`jargon`；全部加守卫 |
| Objects | `painting` | 吃 `oil_painting`、`chinese_painting`（艺术）→ **建议删**，只留 Art |
| Objects | `basket` | 吃 `basketball`、`easter_basket`；加守卫 |
| Objects | `spider` | 在 Pets，吃 `spider_web`（庆典）；建议 spider 归 Animals |
| Food | `egg` | 吃 `easter_egg`、`eggnog`；改 `\beggs?\b` |
| Food | `corn` | 吃 `unicorn`；加守卫 |
| Food | `fig` / `date` / `pear` / `rice` | 吃 `config`/`update`/`appear`/`price`；加守卫 |
| Food | `bread` | 吃 `gingerbread`（庆典）；加守卫 |
| Fantasy | `gem` | 吃 `arrangement`、`gemini`；加守卫 |
| Fantasy | `space` | 吃 `negative_space`（Composition，`^...$` 也救不了）；加守卫 |
| Holidays | `eid` | 吃 `kaleidoscopes`；加守卫 |
| Holidays | `bus` | 在 Vehicles，吃 `columbus_day`；加守卫 |
| Colors | 裸色词 `red/blue/green/...` (12 个) | 与组内 `^...$` 风格**不一致**，且会吃 `shared_preferences`、`greenland`；**建议全部锚定**为 `^red$` 等，或至少加守卫 |
| Colors | `metallic` | 被 Objects `metal` 吃；Objects 加守卫即可 |
| Composition | `^macro$`/`^texture$`/`^wallpaper$`/`^panorama$`/`^arrangement$`/`^negative_space$`/`^depth_of_field$`/`^kaleidoscopes?$`/`^pastel$`/`^rainbow$` | 全部被前组吃掉（见 4.2 各条），守卫 + 最长命中后可恢复 |

### 4.3 语义归属建议调整

- `moon` / `full_moon` 从 Fantasy 移到 Landscapes（新提案已移）——**需注意**：奇幻语境的月（`moon_goddess`、`blood_moon`）会被风光吃掉；建议 Fantasy 补 `moon_goddess`/`harvest_moon`。
- `snail` / `spider` / `tarantula` / `scorpion` / `hermit_crab` 放在 Pets 存疑，建议归 Animals（Pets 保留 `pet_snail` 之类限定词）。
- `mushroom` 见 4.1；`turkey`（Holidays）与动物义冲突， Animals 补 `wild_turkey`。

---

## 5. 内容补充建议（新提案仍缺的高频词）

按「对拼图图库的实际命中率」排序，建议追加：

**Landscapes**：`prairie`、`steppe`、`savanna`、`swamp`、`marsh`、`wetland`、`bog`、`moor`、`heath`、`rapids`、`salt_flat`、`badlands`、`hoodoo`、`natural_bridge`、`sinkhole`、`pack_ice`、`ice_floe`、`northern_lights`（现有 `aurora` 覆盖不到）、`golden_hour`、`blue_hour`、`moonset`、`star_trail`、`sunbeam`、`coastline`、`cliffside`、`sandbar`

**Nature**：`plant`、`herb`、`vine`、`ivy`、`pine`、`maple`、`oak`、`birch`、`palm`、`sprout`、`seed`、`pinecone`、`acorn`、`nest`、`hive`、`mineral`、`crystal`、`geode`、`ripple`、`sunlight`、`wildflower`（补 Flowers 后 Nature 可不留）

**Flowers（缺口最大）**：**`sakura`**（樱花，中文语境高频，当前 0 命中）、`blossom`、`petal`、`bud`、`sakura_festival`、`tulips`、`sunflower_field`、`lavender_field`、`rose_garden`、`protea`、`anemone`、`ranunculus`、`gerbera`、`freesia`、`hyacinth`、`bird_of_paradise`、`lily_of_the_valley`、`chrysanthemum`（已有）、`florist`、`flowerbed`

**Animals**：`duck`、`goose`、`swan`（已有）、`crane`、`falcon`、`vulture`、`ostrich`、`starfish`、`sea_urchin`、`manta_ray`、`crab`（Food 已占，需加 `sea_crab` 区分）、`meerkat`、`hyena`、`badger`、`mole`、`lemur`、`gorilla`、`orangutan`、`chimpanzee`、`safari`、`zoo`、`aviary`、`birdwatching`、`farm_animal`

**Pets**：`terrier`、`pomeranian`、`chihuahua`、`border_collie`、`akita`、`maltese`、`shih_tzu`、`birman`、`norwegian_forest`、`gerbil`、`pet_mouse`、`parakeet`（已有）、`pet_parrot`（Animals 的 `parrot` 会抢）

**Cities（缺口大：缺具体城市名）**：`paris`、`london`、`tokyo`、`new_york`、`venice`、`amsterdam`、`prague`、`kyoto`、`istanbul`、`dubai`、`hong_kong`、`shanghai`、`beijing`、`seoul`、`rome`、`florence`、`barcelona`、`lisbon`、`vienna`、`budapest`、`marrakech`、`neon_light`、`rooftop`、`crossroad`、`night_market`、`street_photography`
（注：加 `amsterdam` 时 Structures 若有 `dam` 要小心）

**Structures**：`mosque`、`synagogue`、`basilica`、`chapel`、`monastery`、`abbey`、`citadel`、`torii`、`stupa`、`minaret`、`observatory`、`aqueduct`、`viaduct`、`tunnel`、`stairway`、`staircase`、`window`、`doorway`、`corridor`、`attic`、`cellar`、`kitchen`、`bathroom`、`dining_room`、`arcade`、`colonnade`、`portico`、`fresco`、`igloo`、`yurt`、`tent`、`hut`、`treehouse`、`boathouse`
（**不要加 `dam`**，会吃 `amsterdam`）

**Vehicles**：`carriage`、`stagecoach`、`chariot`、`kayak`、`rowboat`、`submarine`、`trolley`、`rickshaw`、`zeppelin`、`dirigible`、`snowmobile`、`jet_ski`、`harvester`、`convertible`（已有）、`rv`、`motorhome`

**People**：`bride`、`groom`、`monk`、`nun`、`samurai`、`geisha`、`warrior`、`nomad`、`shepherd`、`vendor`、`barista`、`craftsman`、`photographer`、`hiker`、`cyclist`、`silhouette`、`back_view`、`hands`、`street_portrait`

**Objects（缺口：乐器、数码）**：`guitar`、`piano`、`violin`、`flute`、`drum`、`saxophone`、`trumpet`、`harp`、`accordion`、`ukulele`、`vinyl`、`record_player`、`radio`、`telephone`、`smartphone`、`laptop`、`computer`、`camera`、`lens`、`telescope`、`microscope`、`binoculars`、`compass`、`globe`、`map`、`atlas`、`suitcase`、`barrel`、`carpet`、`rug`、`curtain`、`pillow`、`quilt`、`perfume`、`soap`、`broom`

**Food**：`cupcake`、`cheesecake`、`pudding`、`tart`、`muffin`、`bagel`、`pretzel`、`baguette`、`sourdough`、`honey`、`jam`、`yogurt`、`gelato`、`tiramisu`、`mochi`、`mooncake`（建议归 Holidays）、`hotpot`、`skewer`、`udon`、`soba`、`bento`、`onigiri`、`sashimi`、`tempura`、`papaya`、`dragon_fruit`、`durian`、`chili`、`spice`

**Art**：`poster`、`vintage_poster`、`engraving`、`woodcut`、`stained_glass`、`illuminated_manuscript`、`pixel_art`、`low_poly`、`3d_render`、`vector`、`flat_design`、`geometric`、`psychedelic`、`op_art`、`bauhaus`、`sumi_e`、`sketchbook`、`portrait_painting`

**Fantasy**：`sorcerer`、`sorceress`、`warlock`、`alchemist`、`paladin`、`valkyrie`、`yokai`、`oni`、`tanuki`、`qilin`、`chinese_dragon`、`loong`、`black_hole`、`supernova`、`eclipse`、`meteor`、`comet`、`asteroid`、`shooting_star`、`solar_system`、`mars`、`jupiter`、`venus`、`rocket`、`wormhole`、`spellbook`、`grimoire`、`amulet`、`talisman`、`orb`、`chalice`、`world_tree`、`crystal_ball`（已有）

**Holidays（中文节日缺口最大）**：`mid_autumn`、`mooncake`、`lantern_festival`、`dragon_boat`、`qingming`、`qixi`、`double_seventh`、`chongyang`、`chuxi`（除夕）、`new_year_eve`、`laba`、`oktoberfest`、`beer_festival`、`hanabi`、`summer_festival`、`tanabata`、`world_cup`、`super_bowl`、`baby_shower`、`housewarming`、`epiphany`

**Colors**（全部按 `^...$` 锚定追加）：`gold`、`silver`、`bronze`、`copper`、`rose_gold`、`turquoise`、`magenta`、`cyan`、`maroon`、`navy`、`beige`、`ivory`、`olive`、`teal`、`indigo`、`violet`、`crimson`、`scarlet`、`jade`、`amber`
⚠️ 这些词与 Objects/Food/Fantasy 大量重名（`gold`/`silver`/`ruby`/`emerald`/`coral`/`lavender`/`peach`/`rose`/`olive`），**必须锚定**否则互相污染。

**Composition**：`^top_down$`、`^overhead$`、`^triptych$`、`^diptych$`、`^framed$`、`^polaroid$`、`^film_strip$`、`^reflection$`、`^silhouette$`、`^double_exposure$`、`^high_key$`、`^low_key$`、`^hdr$`、`^fisheye$`、`^aerial$`、`^drone_view$`、`^birds_eye$`、`^motion_blur$`、`^grid_layout$`

---

## 6. 需要拍板的编号项

| # | 决策 | 影响面 | 建议 |
|---|---|---|---|
| ① | 是否把匹配策略改为「最长命中优先」 | 改 `build_taxonomy.py` + 重生成三端 | **是**，收益最大（69% → 91%） |
| ② | 是否对短词统一加 `(?<![a-z])x s?(?![a-z])` 守卫 | 纯数据，约 400 条 | **是**，误伤 67 → 26 |
| ③ | 是否加「精确分词词典层」（支持驼峰/复数/连字符） | 生成器 + 数据结构 | 第二阶段做，先看 ①②效果 |
| ④ | `studio` 是否从 Structures 删除 | 数据 | **删**（本仓库自身目录全中招） |
| ⑤ | `museum` / `painting` 归 Art 还是 Structures / Objects | 数据 | **归 Art**，另两组删除 |
| ⑥ | 裸色词是否全部 `^...$` 锚定 | 数据 | **是**，与组内既有风格一致 |
| ⑦ | 是否追加第 5 节的补充词（约 250 条） | 数据 | 分批：先补 Cities 城市名 + Flowers + 中文节日 + 乐器，收益最高 |
| ⑧ | `Others` 补回 | 数据 | **必须**，否则生成链断 |

---

## 附 2：顺带发现的漂移

`python scripts/build_taxonomy.py --check` 当前即为 FAIL：
`lib/data/constants/puzzle_tags.dart` 与 SSOT 不同步，差异仅为 `PuzzleTagItem` 字段声明位置被手工调整（类首部 ↔ 构造函数后），**无语义差异**。
合入新词表前建议先 `python scripts/build_taxonomy.py` 跑一次把三端拉齐，否则 `--check` 的 FAIL 会掩盖真正的问题。

---

## 附 1：复现方式

```bash
# 1) 替换 tag_patterns 后先做 SSOT 校验（缺 Others 时会在此报错）
python scripts/build_taxonomy.py --dry-run

# 2) 三端产物同步
python scripts/build_taxonomy.py
python scripts/build_taxonomy.py --check

# 3) 回归测试
python studio/test_studio.py
```

评审用中间产物：`temp/_dirnames.json`（736 条真实目录名）、`temp/_gt.json`（130 条标注测试集）。

---

## 实施结果（2026-09-07 已完成）

### 落地的改动

| # | 决策 | 落地情况 |
|---|---|---|
| ① | 匹配改「最长命中优先」 | ✅ 已实现，并升级为**三段式**匹配 |
| ② | 短词守卫 | ✅ 纯 `[a-z_]` 且字母数 ≤6 自动包 `(?<![a-z])词s?(?![a-z])`（含复数） |
| ③ | 精确分词层 | ⏸ 搁置（改用更轻量的「全词精确匹配层」） |
| ④⑤ | Art/Fantasy/Colors 优先级最低 | ✅ 按 `category_type` 自动识别风格/属性类，主体未命中才启用 |
| ⑥ | 裸色词锚定 | ✅ Colors / Composition 整组强制 `^...$` 锚定 |
| ⑦ | 补充词（去歧义） | ✅ 已补 Cities 城市名、Flowers 樱花系、中文节日、乐器、数码等 |
| ⑧ | 补 `Others` | ✅ 已补 `["other", "others", "misc"]` |
| — | 删 `ice` / `ant` | ✅ 已删，连带删除同类高歧义短词 |
| — | 删细碎词 | ✅ 按「不会单独成目录」原则删（snowman/snowflake/mistletoe/eggnog/spider_web/…） |

### 新的匹配链路（`studio/taxonomy.py`）

```
1. 中文别名精确      ZH_ALIAS_MAP
2. 历史 cat_* 前缀   LEGACY_CAT_MAP
3. 主 Tag 全等       (大小写不敏感)
4. 全词精确匹配      EXACT_MAP  ← 新增
     整串归一(小写 + 空格/连字符→下划线) 后查表
     带单复数回退 (s / es / ies→y)
5. 正则最长命中      match_best_pattern()  ← 改造
     5a. 先只在「主体类」TAG 中取语义最长命中
     5b. 主体类全部未命中时，才在风格/属性类 (Art/Fantasy/Colors/Composition) 中取
6. Others
```

风格类由 `category_type ∈ {style, imagination, form_attribute}` 自动推导，不写死。

### 优先级（`tag_patterns` 的 key 顺序）

```
Landscapes > Nature > Flowers > Animals > Pets > Cities > Structures > Vehicles
> People > Objects > Food > Holidays          ← 主体/场景类
> Art > Fantasy > Colors > Composition        ← 风格/属性类（最低）
> Others
```

### 词表规模

| 组 | 条数 | 组 | 条数 |
|---|---|---|---|
| Landscapes | 76 | Objects | 148 |
| Nature | 52 | Food | 135 |
| Flowers | 53 | Holidays | 74 |
| Animals | 148 | Art | 105 |
| Pets | 50 | Fantasy | 118 |
| Cities | 51 | Colors | 56 |
| Structures | 111 | Composition | 48 |
| Vehicles | 79 | Others | 3 |
| People | 65 | **合计** | **~1400**（旧版 ~380） |

其中 **1394 条**可进全词精确表，跨组冲突仅 1 条（`orange` → Food，Colors 让位，符合预期）。

### 效果

| 指标 | 旧 v3.1.0 | 原提案 | **落地后 v3.2.0** |
|---|---|---|---|
| 130 条标注目录名准确率 | 74% | 69% | **100%** |
| 736 条真实目录名误判 | 基线 | 67 条变化（几乎全误判） | **24 条命中，且多为正确命中** |
| 风格让位（anime_girl） | Art ✗ | Art ✗ | **People ✓** |
| 复合词（christmas_tree / oil_painting / school_bus） | Nature / Objects / Structures ✗ | 同左 ✗ | **Holidays / Art / Vehicles ✓** |

### 残留的已知误判（可接受）

真实英文单词恰好命中词表，非图片素材场景不会遇到：
`android`→Fantasy、`store`→Structures、`notebooklm`→Objects、`worker`→People、
`student*`→People、`hive_probe`→Nature、`fox`→Animals（`analyzer_test_fox`）。
如需消除，把对应词从词表删除即可，但会损失真实图片的召回。

### 验证

```bash
python scripts/build_taxonomy.py --check   # ✅ 三端 UP-TO-DATE（顺带修好了 puzzle_tags.dart 的字段顺序漂移）
python studio/test_studio.py               # ✅ 分类相关测试全过；7 个 exporter/扫描失败为既有失败（已与基线逐条比对确认）
flutter test                               # ✅ 282 全过
flutter analyze                            # ✅ 0 error，puzzle_tags.dart 0 issue
```

### 词表重建脚本

`temp/build_tag_patterns_20260907.py`：一次性重建脚本（词表定义 + 守卫/锚定规则 + 审计），输出 `temp/tag_patterns_v2_20260907.json`，可复现本版词表。后续若需微调词表，改脚本内的 `WORDS` 字典后重跑即可。
