import 'dart:math';

import 'edge_curve.dart';
import 'edge_type.dart';

/// 单个拼图碎片四条边缘几何描述的结构体集合。
class PieceEdges {
  const PieceEdges({
    required this.top,
    required this.right,
    required this.bottom,
    required this.left,
  });

  final EdgeCurveDescriptor top;
  final EdgeCurveDescriptor right;
  final EdgeCurveDescriptor bottom;
  final EdgeCurveDescriptor left;

  /// 是否属于外围边框碎片（至少有一条边为平直外框 Flat）
  bool get isBorder =>
      top.isFlat || right.isFlat || bottom.isFlat || left.isFlat;

  /// 是否属于四角角块（至少有两条边为平直外框 Flat）
  bool get isCorner {
    var flatCount = 0;
    if (top.isFlat) flatCount++;
    if (right.isFlat) flatCount++;
    if (bottom.isFlat) flatCount++;
    if (left.isFlat) flatCount++;
    return flatCount >= 2;
  }

  /// 碎片顺时针旋转 [times] 次（每次 90 度）后的边缘映射。
  ///
  /// 【旋转映射原理】：
  /// 顺时针旋转 90 度时：原 Left 边变为 Top，原 Top 边变为 Right，原 Right 边变为 Bottom，原 Bottom 边变为 Left。
  PieceEdges rotateClockwise(int times) {
    var edges = this;
    final count = times % 4;
    for (var i = 0; i < count; i++) {
      edges = PieceEdges(
        top: edges.left,
        right: edges.top,
        bottom: edges.right,
        left: edges.bottom,
      );
    }
    return edges;
  }

  /// [rotateClockwise] 的简写别名
  PieceEdges rotate(int times) => rotateClockwise(times);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PieceEdges &&
          runtimeType == other.runtimeType &&
          top == other.top &&
          right == other.right &&
          bottom == other.bottom &&
          left == other.left;

  @override
  int get hashCode => Object.hash(top, right, bottom, left);
}

/// 全局拼图网格边缘拓扑布局生成器。
///
/// 【核心设计思想与数学保证】：
/// 1. **公母扣绝对契合**：
///    拼图内部的水平分割线和垂直分割线，在全局拓扑中各仅生成一次物理定义。
///    上/下相邻两块碎片共享同一条物理水平分割线（一方为 Tab，另一方为其对偶 Blank）；
///    左/右相邻两块碎片共享同一条物理垂直分割线（一方为 Tab，另一方为其对偶 Blank）。
/// 2. **确定性关卡生成（Seed-driven Determinism）**：
///    使用固定种子 [seed] 初始化伪随机数生成器（`Random(seed)`），
///    确保相同关卡在不同设备、每次重新进入或存档读档时，生成的拼图卡扣形态 100% 绝对一致。
/// 3. **四大经典卡扣与镜像翻转的均匀离散分布**：
///    对每条内部边独立随机分配卡扣形状（Ball, Stub, Sock, Finger）与水平镜像状态（Bend），
///    使整个拼图盘面千姿百态、极富手切工艺的自然趣味性。
class EdgeLayout {
  EdgeLayout({
    required this.rows,
    required this.cols,
    int? seed,
  }) {
    _generate(seed ?? 42);
  }

  /// 拼图网格行数
  final int rows;

  /// 拼图网格列数
  final int cols;

  /// 水平内部分割线拓扑矩阵：尺寸为 (rows - 1) 行 x cols 列
  late final List<List<EdgeCurveDescriptor>> _h;

  /// 垂直内部分割线拓扑矩阵：尺寸为 rows 行 x (cols - 1) 列
  late final List<List<EdgeCurveDescriptor>> _v;

  /// 基于种子生成全盘拓扑结构
  void _generate(int seed) {
    final rng = Random(seed);

    // 内部帮助函数：随机生成一个内部边描述子
    EdgeCurveDescriptor randomDescriptor() {
      // 1. 随机决定凹凸朝向：50% 概率为 Tab（凸），50% 为 Blank（凹）
      final isTab = rng.nextBool();
      final type = isTab ? EdgeType.tab : EdgeType.blank;

      // 2. 随机从四大经典形状库中挑选一种模具
      const shapes = EdgeShapeType.values;
      final shape = shapes[rng.nextInt(shapes.length)];

      // 3. 随机决定是否水平镜像翻转（带来更丰富的不对称形态）
      final bend = rng.nextBool();

      // 4. 深度缩放：微量抖动（0.90 ~ 1.00），使每块碎片既协调又独一无二
      final depthScale = 0.90 + rng.nextDouble() * 0.10;

      return EdgeCurveDescriptor(
        edgeType: type,
        shapeType: shape,
        bend: bend,
        depthScale: depthScale,
      );
    }

    // 1. 生成所有内部水平边：位于第 r 行与第 r+1 行之间
    _h = List.generate(
      rows - 1,
      (_) => List.generate(cols, (_) => randomDescriptor()),
    );

    // 2. 生成所有内部垂直边：位于第 c 列与第 c+1 列之间
    _v = List.generate(
      rows,
      (_) => List.generate(cols - 1, (_) => randomDescriptor()),
    );
  }

  /// 获取指定网格单元格 (row, col) 碎片的四条边几何描述。
  ///
  /// 【外框与内边匹配规则】：
  /// - **Top**：若 row == 0 为平直外框（Flat）；否则取上一行对应的水平边 _h[row - 1][col] 的对偶（complementary）；
  /// - **Bottom**：若 row == rows - 1 为平直外框（Flat）；否则取本行对应的水平边 _h[row][col]；
  /// - **Left**：若 col == 0 为平直外框（Flat）；否则取左一列对应的垂直边 _v[row][col - 1] 的对偶（complementary）；
  /// - **Right**：若 col == cols - 1 为平直外框（Flat）；否则取本列对应的垂直边 _v[row][col]。
  PieceEdges edgesFor(int row, int col) {
    final top = (row == 0)
        ? EdgeCurveDescriptor.flat
        : _h[row - 1][col].complementary();

    final bottom = (row == rows - 1)
        ? EdgeCurveDescriptor.flat
        : _h[row][col];

    final left = (col == 0)
        ? EdgeCurveDescriptor.flat
        : _v[row][col - 1].complementary();

    final right = (col == cols - 1)
        ? EdgeCurveDescriptor.flat
        : _v[row][col];

    return PieceEdges(
      top: top,
      right: right,
      bottom: bottom,
      left: left,
    );
  }
}
