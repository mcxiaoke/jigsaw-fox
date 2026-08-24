# 拼图切片算法与拟真 3D 渲染设计方案

## 一、 背景与设计目标

为了打造业界领先、媲美专业在线拼图网站（如 Jigsaw Explorer）的拼图游戏体验，本项目对碎片切割（Geometry Slicing）与视觉渲染（Visual Rendering）进行了全面重构升级。

### 1.1 现状与痛点分析
- **几何单一性**：原实现仅使用固定单一的静态贝塞尔曲线控制点，所有碎片边缘完全千篇一律，缺乏手作冲压拼图的自然随机有机感。
- **视觉平面感**：原渲染仅绘制一条单色扁平描边，缺乏真实拼图冲压纸板/木板的凹凸倒角压痕（Bevel）与立体光照，显得扁平生硬。
- **包围盒静态化**：Overhang 采用写死的经验比例，缺乏基于实际贝塞尔极值的精确包围盒，不利于复杂异形形状扩展。

### 1.2 升级目标
1. **真实圆滑的几何轮廓**：支持多种经典冲压形状库（Classic Bulb、Sock/Hook、Stubby、Natural Jitter），曲线采用 $C^1$ 连续的高阶三次贝塞尔曲线，圆润饱满且绝无折角。
2. **100% 严丝合缝与确定性**：相邻碎片边缘严格共享几何参数，Tab 与 Hole 完美互锁；完全由关卡种子（Seed）确定性驱动，相同关卡每次进入形态完全一致。
3. **拟真 3D 边缘倒角光影（Bevel & Emboss）**：模拟真实冲压纸板边缘的立体光影，左上方产生柔和受光高光（Top-Left Highlight），右下方产生深色背光内阴影（Bottom-Right Shadow）。
4. **双层动态悬浮软阴影**：托盘与棋盘静止时呈现贴地环境遮挡（Ambient Occlusion），拖拽拾起时呈现大扩散立体下沉投影（Floating Drop Shadow）。

---

## 二、 几何切片数学模型与算法体系

### 2.1 全局边拓扑图（Global Edge Graph）
拼图由 $R$ 行 $C$ 列网格构成。网格内部包含：
- 水平内部边：$(R - 1) \times C$ 条
- 垂直内部边：$R \times (C - 1)$ 条

每条边拥有唯一的确定性几何描述对象 `EdgeCurveDescriptor`：
```dart
class EdgeCurveDescriptor {
  final EdgeShapeType shapeType; // Classic, Hook, Stubby, Jitter
  final double tabSign;          // +1 为正向凸，-1 为反向凹
  final bool isFlipped;          // 曲线横向镜像反转
  final double tabSize;          // 凸头深度与宽度缩放
  final double jitterAlong;      // 凸头中心沿边方向偏置 (b)
  final double jitterDepth;      // 凸头高度微调 (c)
  final double asymmetry;        // 颈部收口不对称度 (d)
  final double startTangent;     // 起始端点切线高度 (a)
  final double endTangent;       // 终止端点切线高度 (e)
}
```

### 2.2 参数化三次贝塞尔曲线模型（Cubic Bezier Formulation）
每条非平整边缘由 3 段三次贝塞尔曲线（共 10 个控制点 $P_0 \sim P_9$）平滑拼接而成：
- **Segment 1（起点至左颈）**：$P_0 \to P_3$，控制点为 $P_1, P_2$。
- **Segment 2（凸头圆弧/球冠）**：$P_3 \to P_6$，控制点为 $P_4, P_5$。
- **Segment 3（右颈回收至终点）**：$P_6 \to P_9$，控制点为 $P_7, P_8$。

#### 归一化参数空间定义：
令边缘长度为 $L$，法向量为 $\vec{N}$，沿边单位切向量为 $\vec{U}$。
控制点在局部坐标系下的计算公式为：
$$
\begin{aligned}
P_0 &= (0.0, 0.0) \\
P_1 &= (0.2, a) \\
P_2 &= (0.5 + b + d, -t + c) \\
P_3 &= (0.5 - t + b, t + c) \\
P_4 &= (0.5 - 2t + b - d, 3t + c) \\
P_5 &= (0.5 + 2t + b - d, 3t + c) \\
P_6 &= (0.5 + t + b, t + c) \\
P_7 &= (0.5 + b + d, -t + c) \\
P_8 &= (0.8, e) \\
P_9 &= (1.0, 0.0)
\end{aligned}
$$
其中：
- $t$: 凸头基准尺度比例（通常 $0.18 \sim 0.24$）
- $b$: 凸头沿边缘的横向偏移（消除呆板居中感）
- $c$: 凸头高度扰动
- $d$: 左右颈部不对称扰动
- $e, a$: 前后两段连续边的端点斜率传递，满足 $a_{i+1} = \pm e_i$，保证跨网格交点时切线 $C^1$ 连续。

### 2.3 形状库预设矩阵
1. **Classic Bulb（经典圆润球形）**：对称大肚球冠，圆润厚重。
2. **Skewed Hook / Sock（短袜歪钩形）**：$b \ne 0, d \ne 0$，俏皮非对称。
3. **Stubby Tab（宽矮粗壮形）**：$t$ 适度降低，颈部加宽，抗变形力强。
4. **Natural Jitter（手切有机形）**：综合引入微小受控随机扰动。

---

## 三、 拟真 3D 倒角与立体光影系统

### 3.1 冲压倒角边缘光照（Bevel Lighting）
真实拼图在冲压下压时，边缘会形成大约 1~1.5mm 的倾斜倒角。当光线从左上方 45° 照射时：
- **Top / Left 边缘及朝向左上的曲线分段**：处于迎光面，呈现白色/浅亮色高光倒角（Highlight Bevel）。
- **Bottom / Right 边缘及朝向右下的曲线分段**：处于背光面，呈现暗色内阴影倒角（Shadow Bevel）。

### 3.2 渲染分层管线（Compositing Pipeline）
每个拼图组件在 `render(Canvas canvas)` 阶段按序渲染以下 5 个图层：
1. **Layer 1: 动态投影（Dynamic Drop Shadow）**
   - 处于拖拽状态时：平移 $(0, 8.0)$，使用高扩散羽化模糊（Blur 6.0~8.0），半透明纯黑（Alpha 0.35）。
   - 处于托盘/棋盘静止时：平移 $(0, 1.5)$，使用低扩散环境遮挡模糊（Blur 1.5），轻度半透明（Alpha 0.15）。
2. **Layer 2: 原图纹理裁切（Clipped Texture）**
   - `canvas.clipPath(shape.path)`
   - `canvas.drawImageRect(image, srcRect, fillRect, paint)`
3. **Layer 3: 左上受光高光倒角（Top-Left Bevel Highlight）**
   - 提取朝向左/上的路径分段，使用 `Color(0x66FFFFFF)`，线宽 1.5px，绘制柔和外凸亮边。
4. **Layer 4: 右下背光暗角倒角（Bottom-Right Bevel Shadow）**
   - 提取朝向右/下的路径分段，使用 `Color(0x55000000)`，线宽 1.5px，绘制凹陷暗边。
5. **Layer 5: 主轮廓微线与吸附高亮（Outer Seam / Snap Highlight）**
   - 常态：超细半透明暗线（`Color(0x22000000)`，0.6px），模拟真实拼装微小缝隙。
   - 吸附/正确提示状态：绿色脉冲辉光（`Color(0xFF4CAF50)`，2.5px）。

---

## 四、 确定性工程设计与性能优化

### 4.1 关卡种子确定性保证
- 严格基于 `seed` 初始化伪随机数生成器 `Random(seed)`。
- App 层关卡初始化、进度存档（Save/Load）、网络每日挑战均具备唯一 Seed，确保用户再次进入游戏时拼图切片形状绝对恒定。

### 4.2 零 GC 与预渲染 Path 缓存
- `PieceShape` 在初始化时一次性计算并预构建：
  - `path`：封闭的主形状剪裁路径
  - `highlightPath`：受光面高光路径
  - `shadowPath`：背光面暗角路径
  - `fillRect` & `srcRect`：精确包围盒
- `render()` 循环内零对象分配与零数学计算，保证满帧 60/120 FPS。
