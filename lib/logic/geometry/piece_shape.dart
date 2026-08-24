import 'dart:math';
import 'dart:ui' show Offset, Path, Rect;

import 'edge_layout.dart';

/// 碎片四周向外延展的凸出比例包围盒（Overhang）。
///
/// 【设计背景与核心原理】：
/// 拼图碎片不是简单的矩形，凸头（Tab）会伸出到基础矩形单元格外，
/// 同时凹槽（Blank）在卡扣两侧根部也存在约 10% 的微小外扩。
/// 为了确保：
/// 1. 贴图采样区域（[srcRect]）与渲染绘制区域（[fillRect]）能 100% 完整覆盖贝塞尔曲线的极值外轮廓；
/// 2. 避免边缘纹理被矩形画布边界意外截断，导致在拼装交界角露白或漏底黑缝。
///
/// 【裕量参数选值依据】：
/// - [standardTabRatio] = 0.35：四大形状库中最大的外凸深度为 Sock/Finger 的 34.46%，0.35 能完整包含峰顶；
/// - [standardBlankRatio] = 0.15：凹槽根部向外微凸的最大值为 9.85%，0.15 提供充裕的安全采样余量；
/// - Flat 边框为 0.0：外平直边界严禁向外采样，防止跨出拼图整图边界。
class Overhang {
  const Overhang({
    this.left = 0.0,
    this.top = 0.0,
    this.right = 0.0,
    this.bottom = 0.0,
  });

  /// 左侧向外延展比例（占碎片宽度的比例）
  final double left;

  /// 上方向外延展比例（占碎片高度的比例）
  final double top;

  /// 右侧向外延展比例（占碎片宽度的比例）
  final double right;

  /// 下方向外延展比例（占碎片高度的比例）
  final double bottom;

  /// 凸头（Tab）标准外凸裕量比例（35%）
  static const double standardTabRatio = 0.35;

  /// 凹槽（Blank）根部安全外扩采样裕量比例（15%）
  static const double standardBlankRatio = 0.15;

  /// 根据碎片的四条边属性计算四周的 Overhang
  factory Overhang.fromEdges(PieceEdges edges, {double? tip}) {
    double ratioFor(dynamic edge) {
      if (edge.isFlat) return 0.0;
      if (edge.isTab) return tip ?? standardTabRatio;
      return standardBlankRatio;
    }

    return Overhang(
      top: ratioFor(edges.top),
      right: ratioFor(edges.right),
      bottom: ratioFor(edges.bottom),
      left: ratioFor(edges.left),
    );
  }

  @override
  String toString() =>
      'Overhang(L:${left.toStringAsFixed(2)}, T:${top.toStringAsFixed(2)}, R:${right.toStringAsFixed(2)}, B:${bottom.toStringAsFixed(2)})';
}

/// 拼图碎片几何形状管理器。
///
/// 负责生成并缓存单个碎片的封闭二次贝塞尔路径 [path]、
/// 局部渲染包围盒 [fillRect]、原图采样矩形 [srcRect] 以及精确碰撞拾取检测。
class PieceShape {
  PieceShape({
    required this.edges,
    required this.width,
    required this.height,
    double? tipRatio,
  }) : overhang = Overhang.fromEdges(edges, tip: tipRatio) {
    path = _buildPath();
  }

  /// 碎片的四条边缘描述子（上、右、下、左）
  final PieceEdges edges;

  /// 基础单元格宽度（不含凸头）
  final double width;

  /// 基础单元格高度（不含凸头）
  final double height;

  /// 四周向外延展比例包围盒
  final Overhang overhang;

  /// 预计算并缓存的顺时针封闭贝塞尔曲线路径
  late final Path path;

  /// 局部坐标系下的完整渲染绘制外包矩形。
  /// 原点 (0, 0) 对应碎片基础矩形单元格的左上角。
  Rect get fillRect => Rect.fromLTWH(
        -overhang.left * width,
        -overhang.top * height,
        (1.0 + overhang.left + overhang.right) * width,
        (1.0 + overhang.top + overhang.bottom) * height,
      );

  /// 对应原图像素坐标系下的纹理采样矩形。
  ///
  /// 【映射原理】：
  /// 根据碎片在拼图网格中的行索引 [row] 与列索引 [col]，结合四周延展比例 [overhang]，
  /// 按 1:1 物理比例截取原图对应区域的像素，确保拼接时整幅图案绝对平滑连续。
  Rect srcRect({
    required int row,
    required int col,
    required double srcWidthPerCol,
    required double srcHeightPerRow,
  }) {
    return Rect.fromLTWH(
      (col - overhang.left) * srcWidthPerCol,
      (row - overhang.top) * srcHeightPerRow,
      (1.0 + overhang.left + overhang.right) * srcWidthPerCol,
      (1.0 + overhang.top + overhang.bottom) * srcHeightPerRow,
    );
  }

  /// 构建顺时针封闭的 12 点二次贝塞尔路径。
  ///
  /// 【四边闭合几何追溯】：
  /// 1. Top 边：从 (0, 0) 绘制到 (width, 0)，外法线指向正上方 (0, -1)；
  /// 2. Right 边：从 (width, 0) 绘制到 (width, height)，外法线指向正右方 (1, 0)；
  /// 3. Bottom 边：定义规范为 (0, height) -> (width, height)，外法线指向正下方 (0, 1)。
  ///    由于顺时针闭合需要从 (width, height) 走回 (0, height)，因此传入 reverse=true 逆向回溯；
  /// 4. Left 边：定义规范为 (0, 0) -> (0, height)，外法线指向正左方 (-1, 0)。
  ///    由于顺时针闭合需要从 (0, height) 走回 (0, 0)，因此传入 reverse=true 逆向回溯；
  /// 5. 路径调用 p.close() 完美闭合。
  Path _buildPath() {
    final p = Path();
    p.moveTo(0, 0);

    // 1. Top 边：(0, 0) -> (width, 0)
    edges.top.appendToPath(
      p,
      start: const Offset(0, 0),
      end: Offset(width, 0),
      normal: const Offset(0, -1),
      reverse: false,
    );

    // 2. Right 边：(width, 0) -> (width, height)
    edges.right.appendToPath(
      p,
      start: Offset(width, 0),
      end: Offset(width, height),
      normal: const Offset(1, 0),
      reverse: false,
    );

    // 3. Bottom 边：标准定义为 (0, height) -> (width, height)，逆向倒回 (0, height)
    edges.bottom.appendToPath(
      p,
      start: Offset(0, height),
      end: Offset(width, height),
      normal: const Offset(0, 1),
      reverse: true,
    );

    // 4. Left 边：标准定义为 (0, 0) -> (0, height)，逆向倒回 (0, 0)
    edges.left.appendToPath(
      p,
      start: const Offset(0, 0),
      end: Offset(0, height),
      normal: const Offset(-1, 0),
      reverse: true,
    );

    p.close();
    return p;
  }

  /// 对包含旋转状态 [rot] (0, 1, 2, 3) 的碎片进行精准的点碰撞拾取检测。
  ///
  /// 【算法原理】：
  /// 不对复杂的贝塞尔 Path 做动态旋转变换，而是将输入的触摸点 [localPoint] 绕碎片几何中心点
  /// 进行逆向旋转变换，直接在缓存好的静态 [path] 上进行 `contains` 判定，计算性能极高且 100% 精确。
  bool containsLocalPoint(Offset localPoint, int rot) {
    if (rot % 4 == 0) {
      return path.contains(localPoint);
    }

    final cx = width / 2.0;
    final cy = height / 2.0;
    final dx = localPoint.dx - cx;
    final dy = localPoint.dy - cy;

    final angle = -(rot % 4) * (pi / 2.0);
    final cosA = cos(angle);
    final sinA = sin(angle);

    final origX = cx + dx * cosA - dy * sinA;
    final origY = cy + dx * sinA + dy * cosA;

    return path.contains(Offset(origX, origY));
  }
}
