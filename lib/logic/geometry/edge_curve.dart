import 'dart:math';
import 'dart:ui' show Offset, Path;

import 'edge_type.dart';

/// 经典拼图凸头（Tab）形状枚举，对应 Jigsaw Explorer 预设的四大经典几何模具。
enum EdgeShapeType {
  /// 经典对称圆球形 (Ball Tab)：
  /// 最标准、最受玩家欢迎的经典拼图卡扣形态，左右对称，球头饱满，颈部收口自然。
  ball,

  /// 宽矮平缓形 (Stub Tab)：
  /// 凸起深度较浅（约 23% 边长），基座更宽阔平缓，适合较小尺寸碎片或大网格，结构极其稳固。
  stub,

  /// 短袜歪头形 (Sock Tab)：
  /// 具有明显左右不对称的歪头短袜形卡扣，球头峰顶偏向一侧，带来手切拼图特有的俏皮感与辨识度。
  sock,

  /// 修长手指形 (Finger Tab)：
  /// 纵向过渡平缓、卡扣过渡略显修长，带来细腻的插拔手感。
  finger,
}

/// 归一化边缘坐标系下的二维控制点。
///
/// 坐标分量说明：
/// - [along]：沿边缘线段方向的归一化行进比例，区间为 [0.0, 1.0]。
///   起点为 0.0，终点为 1.0。
/// - [from]：垂直于边缘基线的法向偏移比例。
///   正值（+）代表向外凸出（Tab 方向），负值（-）代表向内凹陷（Blank/颈部内缩方向）。
///   例如 +0.2954 代表凸起高度占边长的 29.54%，-0.0985 代表颈部回缩占边长的 9.85%。
class CurvePoint {
  const CurvePoint(this.along, this.from);

  /// 沿边缘主轴方向的位置（0.0 到 1.0）
  final double along;

  /// 垂直于边缘法线方向的偏移（正为外凸，负为内凹）
  final double from;
}

/// 经典 12 点二次贝塞尔曲线矩阵库（基于 Jigsaw Explorer 生产环境验证算法）。
///
/// 【数学模型与设计原理】：
/// 每条边缘由 12 个控制点组成，构成 6 段连续平滑的二次贝塞尔曲线（Quadratic Bezier）：
/// - 偶数索引 `i = 0, 2, 4, 6, 8, 10` 为控制点 (Control Point)；
/// - 奇数索引 `i = 1, 3, 5, 7, 9, 11` 为曲线锚点 (Anchor Point)；
/// - 段 0 (`pts[0]->pts[1]`): 起点至左侧平缓过渡区；
/// - 段 1 (`pts[2]->pts[3]`): 左侧颈部回缩与大肚球头根部交界；
/// - 段 2 (`pts[4]->pts[5]`): 凸头左半球冠圆弧，达最高峰顶 (Peak)；
/// - 段 3 (`pts[6]->pts[7]`): 凸头右半球冠圆弧，下落至右颈部；
/// - 段 4 (`pts[8]->pts[9]`): 右侧颈部回缩与平缓过渡区；
/// - 段 5 (`pts[10]->pts[11]`): 收尾至边缘终点 (1.0, 0.0)。
///
/// 【为什么使用二次贝塞尔而非三次贝塞尔？】：
/// 二次贝塞尔曲线曲率极其平缓自然，且在保证连续性的前提下，不会因端点高阶导数过大
/// 而产生反向自相交、大头针状细柄或尖锐褶皱，能完美呈现大肚细颈的圆润卡扣。
class JigexCurves {
  /// 经典对称圆球形 (Ball) 12 点矩阵
  static const List<CurvePoint> ball = [
    CurvePoint(0.0643939393939394, -0.00378787878787879), // Ctrl 0
    CurvePoint(0.162878787878788, -0.0265151515151515),  // Anchor 0
    CurvePoint(0.534090909090909, -0.0984848484848485),  // Ctrl 1 (颈部内凹引导)
    CurvePoint(0.431818181818182, 0.0568181818181818),   // Anchor 1 (左颈节点)
    CurvePoint(0.265151515151515, 0.287878787878788),   // Ctrl 2 (大肚外扩)
    CurvePoint(0.500000000000000, 0.295454545454545),   // Anchor 2 (对称峰顶 +29.5%)
    CurvePoint(0.715909090909091, 0.287878787878788),   // Ctrl 3 (大肚外扩)
    CurvePoint(0.575757575757576, 0.0568181818181818),   // Anchor 3 (右颈节点)
    CurvePoint(0.515151515151515, -0.0795454545454545),  // Ctrl 4 (颈部内凹引导)
    CurvePoint(0.761363636363636, -0.0189393939393939),  // Anchor 4
    CurvePoint(0.905303030303030, 0.0113636363636364),   // Ctrl 5
    CurvePoint(1.000000000000000, 0.0000000000000000),   // Anchor 5 (终点)
  ];

  /// 宽矮粗壮形 (Stub) 12 点矩阵：峰顶深度约 +23.48%
  static const List<CurvePoint> stub = [
    CurvePoint(0.0946969696969697, 0.00757575757575758),
    CurvePoint(0.219696969696970, -0.0492424242424242),
    CurvePoint(0.397727272727101, -0.117424242424242),
    CurvePoint(0.378787878787097, 0.0189393939393114),
    CurvePoint(0.363636363636116, 0.234848484848119),
    CurvePoint(0.617424242424111, 0.151515151515102),
    CurvePoint(0.708333333333032, 0.109848484848083),
    CurvePoint(0.617424242424097, -0.01515151515151),
    CurvePoint(0.518939393939082, -0.181818181818111),
    CurvePoint(0.837121212121097, -0.0303030303030032),
    CurvePoint(0.909090909090105, 0.0037878787878711),
    CurvePoint(1.000000000000000, 0.0000000000000000),
  ];

  /// 短袜俏皮歪形 (Sock) 12 点矩阵：峰顶偏向 0.5416，最大深度 +34.46%
  static const List<CurvePoint> sock = [
    CurvePoint(0.0946969696969697, 0.0113636363636364),
    CurvePoint(0.227272727272727, -0.0303030303030303),
    CurvePoint(0.537878787878788, -0.117424242424242),
    CurvePoint(0.382575757575758, 0.132575757575758),
    CurvePoint(0.284090909090909, 0.344696969696970),
    CurvePoint(0.541666666666667, 0.268939393939394),
    CurvePoint(0.681818181818182, 0.208333333333333),
    CurvePoint(0.575757575757576, 0.0568181818181818),
    CurvePoint(0.515151515151515, -0.0795454545454545),
    CurvePoint(0.761363636363636, -0.0189393939393939),
    CurvePoint(0.905303030303030, 0.0113636363636364),
    CurvePoint(1.000000000000000, 0.0000000000000000),
  ];

  /// 修长手指形 (Finger) 12 点矩阵：峰顶偏向 0.4734，最大深度 +34.46%
  static const List<CurvePoint> finger = [
    CurvePoint(0.0492424242424242, 0.0000000000000000),
    CurvePoint(0.159090909090909, -0.0227272727272727),
    CurvePoint(0.545454545454545, -0.0681818181818182),
    CurvePoint(0.412878787878788, 0.1250000000000000),
    CurvePoint(0.253787878787879, 0.344696969696970),
    CurvePoint(0.473484848484849, 0.272727272727273),
    CurvePoint(0.553030303030303, 0.238636363636364),
    CurvePoint(0.549242424242424, 0.121212121212121),
    CurvePoint(0.500000000000000, -0.109848484848485),
    CurvePoint(0.761363636363636, -0.0189393939393939),
    CurvePoint(0.905303030303030, 0.0113636363636364),
    CurvePoint(1.000000000000000, 0.0000000000000000),
  ];

  /// 根据形状枚举获取对应的 12 个原始二次贝塞尔控制点
  static List<CurvePoint> getPoints(EdgeShapeType shape) {
    switch (shape) {
      case EdgeShapeType.ball:
        return ball;
      case EdgeShapeType.stub:
        return stub;
      case EdgeShapeType.sock:
        return sock;
      case EdgeShapeType.finger:
        return finger;
    }
  }
}

/// 拼图边缘几何曲线描述器。
///
/// 封装了单条边的几何属性（形状类型、凹凸方向、镜像反转、深度缩放），
/// 并提供精准将曲线绘制追加到 Flutter [Path] 上的数学变换能力。
class EdgeCurveDescriptor {
  const EdgeCurveDescriptor({
    required this.edgeType,
    this.shapeType = EdgeShapeType.ball,
    this.bend = true,
    this.depthScale = 0.95,
  });

  /// 边缘类型（Flat 外边框、Tab 凸头、Blank 凹槽）
  final EdgeType edgeType;

  /// 预设卡扣形状库类型
  final EdgeShapeType shapeType;

  /// 曲线弯曲方向 / 水平镜像标志（true 为正向，false 为关于 0.5 水平镜像对称）
  final bool bend;

  /// 凸头垂直法向深度缩放系数（默认 0.95，微调凸起比例使视觉更圆润饱满）
  final double depthScale;

  /// 标准平直外边框描述单例
  static const EdgeCurveDescriptor flat = EdgeCurveDescriptor(
    edgeType: EdgeType.flat,
  );

  bool get isFlat => edgeType == EdgeType.flat;
  bool get isTab => edgeType == EdgeType.tab;
  bool get isBlank => edgeType == EdgeType.blank;

  /// 生成与当前边空间共享且公母互锁的对偶描述器。
  ///
  /// 【公母扣契合原理】：
  /// 相邻两块碎片共享同一条物理分割线。
  /// 若碎片 A 该侧为 Tab（凸），则相邻碎片 B 该侧必为 Blank（凹），
  /// 且两者在空间中的物理曲线（[shapeType]、[bend]、[depthScale]）完全一致，
  /// 从而在数学上保证相邻卡扣 100% 严丝合缝、零误差咬合。
  EdgeCurveDescriptor complementary() {
    if (isFlat) return flat;
    return EdgeCurveDescriptor(
      edgeType: isTab ? EdgeType.blank : EdgeType.tab,
      shapeType: shapeType,
      bend: bend,
      depthScale: depthScale,
    );
  }

  /// 将当前边的几何曲线平滑追加到目标 [path] 中。
  ///
  /// 【参数说明】：
  /// - [path]：待追加曲线的 Flutter Path 对象。
  /// - [start]：该边在世界/局部坐标系下的标准规范起始点（Canonical Start）。
  /// - [end]：该边在世界/局部坐标系下的标准规范终止点（Canonical End）。
  /// - [normal]：由 [start] 指向 [end] 的顺时针向外单位法向量（Unit Normal Vector）。
  /// - [reverse]：是否逆向追踪此边。
  ///   - false（正向）：从 [start] 顺次绘制到 [end]；
  ///   - true（反向）：从当前笔触位置 [end] 逆向回溯绘制回 [start]（用于 Bottom 边与 Left 边）。
  void appendToPath(
    Path path, {
    required Offset start,
    required Offset end,
    required Offset normal,
    bool reverse = false,
  }) {
    // 1. 平直外边界直接用直线连接
    if (isFlat) {
      if (reverse) {
        path.lineTo(start.dx, start.dy);
      } else {
        path.lineTo(end.dx, end.dy);
      }
      return;
    }

    final tangent = end - start;
    final length = tangent.distance;
    if (length <= 0) return;

    // 沿边单位切向量与带符号外法向量
    final u = tangent / length;
    final sign = isTab ? 1.0 : -1.0;
    final directedNormal = normal * sign;

    final rawPts = JigexCurves.getPoints(shapeType);

    // 2. 预先计算标准正向 [start -> end] 空间下的 6 个控制点 (controls) 与 6 个锚点 (anchors)
    final controls = <Offset>[];
    final anchors = <Offset>[];

    if (bend) {
      // 正向形态：沿 0.0 -> 1.0 顺序取点
      for (var s = 0; s < 6; s++) {
        final ctrlPt = rawPts[s * 2];
        final anchorPt = rawPts[s * 2 + 1];

        final cp = start +
            u * (ctrlPt.along * length) +
            directedNormal * (ctrlPt.from * length * depthScale);
        final p = start +
            u * (anchorPt.along * length) +
            directedNormal * (anchorPt.from * length * depthScale);

        controls.add(cp);
        anchors.add(p);
      }
    } else {
      // 镜像形态：关于 along=0.5 进行左右水平镜像对称，曲线起点仍为 0.0，终点仍为 1.0：
      // 段 0: ctrl = 1 - P10, anchor = 1 - P9
      // 段 1: ctrl = 1 - P8,  anchor = 1 - P7
      // 段 2: ctrl = 1 - P6,  anchor = 1 - P5
      // 段 3: ctrl = 1 - P4,  anchor = 1 - P3
      // 段 4: ctrl = 1 - P2,  anchor = 1 - P1
      // 段 5: ctrl = 1 - P0,  anchor = (1.0, 0.0)
      for (var s = 0; s < 6; s++) {
        final rawCtrlIdx = 10 - s * 2;
        final ctrlPt = rawPts[rawCtrlIdx];
        final cpAlong = 1.0 - ctrlPt.along;

        final anchorAlong = (s == 5) ? 1.0 : 1.0 - rawPts[8 - s * 2 + 1].along;
        final anchorFrom = (s == 5) ? 0.0 : rawPts[8 - s * 2 + 1].from;

        final cp = start +
            u * (cpAlong * length) +
            directedNormal * (ctrlPt.from * length * depthScale);
        final p = start +
            u * (anchorAlong * length) +
            directedNormal * (anchorFrom * length * depthScale);

        controls.add(cp);
        anchors.add(p);
      }
    }

    // 3. 根据 reverse 标志按正确顺序将 6 段二次贝塞尔曲线推入 Path
    if (!reverse) {
      // 正向绘制：start -> A0 -> A1 -> A2 -> A3 -> A4 -> A5(end)
      for (var s = 0; s < 6; s++) {
        path.quadraticBezierTo(
          controls[s].dx,
          controls[s].dy,
          anchors[s].dx,
          anchors[s].dy,
        );
      }
    } else {
      // 反向回溯：笔触当前已在 end(A5)，顺次倒退 -> A4 -> A3 -> A2 -> A1 -> A0 -> start
      for (var s = 5; s >= 0; s--) {
        final target = (s == 0) ? start : anchors[s - 1];
        path.quadraticBezierTo(
          controls[s].dx,
          controls[s].dy,
          target.dx,
          target.dy,
        );
      }
    }
  }

  /// 计算该边向外凸出的最大包围盒裕量比例（占该边长度的比例）。
  /// 用于动态计算贴图采样裁剪区域 [Overhang]。
  double get maxOverhangRatio {
    if (isFlat || isBlank) return 0.0;
    return max(0.22, 0.35 * depthScale);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EdgeCurveDescriptor &&
          runtimeType == other.runtimeType &&
          edgeType == other.edgeType &&
          shapeType == other.shapeType &&
          bend == other.bend &&
          depthScale == other.depthScale;

  @override
  int get hashCode => Object.hash(edgeType, shapeType, bend, depthScale);
}
