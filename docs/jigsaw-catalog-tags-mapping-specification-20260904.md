# Jigsaw Puzzle: Catalogs 与 Specific Tags 映射规范

> **版本**：v2.3 (2026-09-04)  
> **体系**：11 个主题分类（带 `cat_` 前缀，含 1 兜底）+ 31 个精简细分标签（全小写、无前缀，含 1 兜底，共 32 个）。  
> **单复数与词性规范**：
> 1. **可数名词统一使用复数（Plural）**：如 `cats`, `dogs`, `birds`, `mountains`, `forests`, `oceans`, `sunsets`, `landmarks`, `castles`, `villages`, `flowers`, `cottages`, `desserts`, `fruits`, `colors`, `mandalas`, `illustrations`, `holidays`, `seasons`, `crafts`, `others`；
> 2. **不可数名词、形容词及固定短语保留原形**：不可数名词如 `wildlife`, `sealife`, `cuisine`, `fine_art`；形容词如 `botanical`, `vintage`, `oriental`, `mythical`；专有/名词短语如 `cozy_home`, `flat_lay`, `zodiac`；
> 3. **目录识别规则**：脚本识别素材目录名时，不区分大小写，自动消除单复数差异（如 `Cat`/`Cats`、`Holiday`/`Holidays`、`Ocean`/`Oceans`、`Mandala`/`Mandalas` 均无缝等同识别），且严格只识别目录名，不从文件名提取标签。

---

## 一、 Catalogs（主分类）

UI 展示层分类（Key 全小写且统一使用 `cat_` 前缀）：

| Key | Name | 中文名称 | 说明 |
| :--- | :--- | :--- | :--- |
| `cat_all` | All | 全部 | 全库关卡集合，不按标签过滤 |
| `cat_nature` | Nature | 自然风光 | 山峦湖泊、森林、海洋、日落等大自然景观 |
| `cat_animals` | Animals | 动物萌宠 | 萌宠家养、野生猛兽、飞禽水族等生命题材 |
| `cat_colors` | Colors | 缤纷色彩 | 彩虹色块、渐变色系、图腾与平铺阵列 |
| `cat_flowers` | Flowers | 花卉园艺 | 庭院花园、缤纷花海、桌面插花与绿植多肉 |
| `cat_cozy` | Cozy | 温馨生活 | 小木屋、壁炉暖房、手作编织、复古珍奇与治愈日常 |
| `cat_travel` | Travel | 城市旅行 | 世界地标、欧洲古堡、浪漫小镇与街景风情 |
| `cat_food` | Food | 美食甜品 | 甜点茶饮、环球料理、鲜果时蔬等美食盛宴 |
| `cat_art` | Art | 唯美艺术 | 经典名画、治愈插画、国风工笔等审美艺术 |
| `cat_fantasy` | Fantasy | 奇幻仙境 | 神兽巨龙、独角兽仙子、魔法城堡与星座星象 |
| `cat_holidays` | Holidays | 节日时令 | 节庆假日、四季节令与庆典节期 |
| `cat_others` | Others | 其他分类 | 系统兜底分类，收纳未识别或无标签关卡 |

---

## 二、 Tags（细分标签）

核心运营与打标使用的 31 个精简细分标签（加 1 个系统兜底，共 32 个），Key 全小写且不带任何前缀：

| Key | 词性/数 | Name | 中文名称 | 覆盖场景与实体 |
| :--- | :--- | :--- | :--- | :--- |
| `cats` | 复数 | Cats | 猫咪 | 家猫、幼猫、猫咪生活特写 |
| `dogs` | 复数 | Dogs | 狗狗 | 各类家犬、名犬生活日常 |
| `birds` | 复数 | Birds | 飞禽鸟类 | 观赏鸟、野生鸟禽、鸣禽与水鸟 |
| `wildlife` | 不可数 | Wildlife | 陆地野兽 | 狮虎豹、森林鹿狼狐、熊等陆地野生动物 |
| `sealife` | 不可数 | SeaLife | 海洋水族 | 海豚鲸鱼、海龟、热带鱼群与珊瑚礁水下世界 |
| `mountains` | 复数 | Mountains | 山峦湖泊 | 雪山、高山湖泊及其倒影水面 |
| `forests` | 复数 | Forests | 森林自然 | 原始林、苔藓古树、丁达尔光束穿透的深林 |
| `oceans` | 复数 | Oceans | 海洋海岸 | 白沙滩、海浪礁石、热带海滨与海岸灯塔 |
| `sunsets` | 复数 | Sunsets | 日落晚霞 | 暮光晚霞、火烧云、日落地平线与晨曦 |
| `landmarks` | 复数 | Landmarks | 名胜地标 | 世界著名地标建筑与都市天际线 |
| `castles` | 复数 | Castles | 古堡宫殿 | 欧式城堡、皇家宫殿与中世纪要塞 |
| `villages` | 复数 | Villages | 街景小镇 | 水乡、欧洲石板街景、悬崖彩色小镇 |
| `flowers` | 复数 | Flowers | 花卉花园 | 花园庭院、花田花海、桌面插花花束 |
| `botanical` | 形容词 | Botanical | 绿植微观 | 多肉仙人掌、盆栽绿植、奇趣真菌蘑菇 |
| `cottages` | 复数 | Cottages | 乡村木屋 | 森林小木屋、雪夜暖灯屋、英式茅草屋 |
| `cozy_home` | 短语 | CozyHome | 温馨室内 | 壁炉、书架、毛毯、暖阳门廊等温馨室内场景 |
| `vintage` | 形容词 | Vintage | 复古珍奇 | 老爷车、复古杂货、古董打字机/怀表/留声机 |
| `crafts` | 固有复数 | Crafts | 手作布艺 | 毛线编织、刺绣缝纫盒、拼布布头与纽扣珠串 |
| `desserts` | 复数 | Desserts | 甜点茶饮 | 蛋糕西点、面包烘焙、马卡龙、下午茶点心架、咖啡与茶饮 |
| `cuisine` | 不可数 | Cuisine | 环球料理 | 亚洲美食（寿司/拉面/点心/火锅）、欧美主食（披萨/意面/牛排）、塔可大餐 |
| `fruits` | 复数 | Fruits | 鲜果时蔬 | 鲜果拼盘、切开的柑橘柠檬横截面、热带果盘、水润浆果果篮 |
| `colors` | 复数 | Colors | 彩虹色彩 | 彩虹光谱、渐变色块、高饱和色彩矩阵 |
| `flat_lay` | 短语 | FlatLay | 俯拍平铺 | 平铺排列的文具、杂物、工具等整齐构图 |
| `mandalas` | 复数 | Mandalas | 曼陀罗图腾 | 对称万花筒图腾、放射色谱与马赛克纹理 |
| `fine_art` | 不可数 | FineArt | 经典名画 | 大师古典油画、博物馆艺术名作 |
| `illustrations` | 复数 | Illustrations | 治愈插画 | 水彩手绘绘本、密集寻宝插画与童话王国 |
| `oriental` | 形容词 | Oriental | 国风东方 | 工笔花鸟、青绿山水、国潮古建与东方美学 |
| `mythical` | 形容词 | Mythical | 奇幻神兽 | 西方巨龙、独角兽、薄翼仙子等神话生灵 |
| `zodiac` | 专有词 | Zodiac | 星座星象 | 十二星座守护兽、占星日月星宿图腾与塔罗 |
| `holidays` | 复数 | Holidays | 节庆假日 | 【合并】圣诞节、万圣节、复活节、感恩节、新年等所有节日 |
| `seasons` | 复数 | Seasons | 四季节令 | 春花、夏日海滨、秋叶金秋、冬雪原野等四季风貌 |
| `others` | 兜底 | Others | 其他分类 | 未识别或无特定标签兜底 |

---

## 三、 映射关系（Catalog → Tags）

- cat_nature: mountains, forests, oceans, sunsets, seasons
- cat_animals: cats, dogs, birds, wildlife, sealife
- cat_colors: colors, flat_lay, mandalas, crafts
- cat_flowers: flowers, botanical
- cat_cozy: cottages, cozy_home, vintage, crafts
- cat_travel: landmarks, castles, villages, vintage
- cat_food: desserts, cuisine, fruits
- cat_art: fine_art, illustrations, oriental, mandalas
- cat_fantasy: mythical, zodiac, colors
- cat_holidays: holidays, seasons
- cat_others: others

