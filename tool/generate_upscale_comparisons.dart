// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:math' as math;
import 'package:image/image.dart' as img;
import 'package:jigsawpuzzle/logic/image_upscaler.dart';

void main() async {
  final inputDir = Directory('temp/testimages');
  final outDir = Directory('temp/comparisons');
  if (!await outDir.exists()) {
    await outDir.create(recursive: true);
  }

  // 挑选几张不同类型的典型测试图
  final selectedFiles = [
    '12019-sea-2361247.jpg', // 海面与天空渐变
    'ambquinn-irish-goat-7429437.jpg', // 山羊毛发与草地背景
    'suju-foto-butterfly-10412107.jpg', // 蝴蝶翅膀纹理与平坦背景
    'salofoto-fox-10395832.jpg', // 狐狸毛发与虚化背景
  ];

  print('开始生成图像增强对比图...');

  for (final filename in selectedFiles) {
    final file = File('${inputDir.path}/$filename');
    if (!await file.exists()) {
      print('文件不存在，跳过: $filename');
      continue;
    }

    final rawBytes = await file.readAsBytes();
    final original = img.decodeImage(rawBytes);
    if (original == null) continue;

    // 裁切中间 480x320 作为模拟小图输入
    final cropW = math.min(480, original.width);
    final cropH = math.min(320, original.height);
    final startX = (original.width - cropW) ~/ 2;
    final startY = (original.height - cropH) ~/ 2;

    final smallSrc = img.copyCrop(
      original,
      x: startX,
      y: startY,
      width: cropW,
      height: cropH,
    );

    // 1. 基准：仅双三次放大 2x（无锐化）
    final baseline2x = img.copyResize(
      smallSrc,
      width: cropW * 2,
      height: cropH * 2,
      interpolation: img.Interpolation.cubic,
    );

    // 2. 旧版 CAS：包含平坦区锐化噪点
    final oldCAS = ImageUpscaler.processPipeline(
      smallSrc,
      scale: 2.0,
      enableDenoise: true,
      denoiseStrength: 0.25,
      enableSharpen: true,
      sharpness: 0.45,
      useLumaGated: false,
      adaptiveSharpness: false,
    );

    // 3. 新版 Luma-Gated CAS：亮度驱动 + 噪声门限自适应锐化
    final newGatedCAS = ImageUpscaler.processPipeline(
      smallSrc,
      scale: 2.0,
      enableDenoise: true,
      denoiseStrength: 0.25,
      enableSharpen: true,
      sharpness: 0.45,
      useLumaGated: true,
      noiseThresholdLow: 8.0,
      noiseThresholdHigh: 24.0,
      adaptiveSharpness: true,
    );

    // 生成三联并排对比图
    final fullComparison = _createSideBySide3(
      baseline2x,
      oldCAS,
      newGatedCAS,
      label1: '1. Baseline 2x (No Sharpen)',
      label2: '2. Old CAS (Noisy in Flat Area)',
      label3: '3. New Luma-Gated CAS (Clean & Sharp)',
    );

    final baseName = filename.split('.').first;
    final outFullFile = File('${outDir.path}/${baseName}_comparison.png');
    await outFullFile.writeAsBytes(img.encodePng(fullComparison));
    print('已生成全景对比: ${outFullFile.path}');

    // 针对细节局部进行 2x 局部特写放大对比（便于肉眼观察平坦区噪点与边缘清晰度差异）
    final detailW = math.min(180, baseline2x.width);
    final detailH = math.min(180, baseline2x.height);
    final dX = (baseline2x.width - detailW) ~/ 2;
    final dY = (baseline2x.height - detailH) ~/ 2;

    final detail1 = img.copyResize(
      img.copyCrop(baseline2x, x: dX, y: dY, width: detailW, height: detailH),
      width: 320,
      height: 320,
      interpolation: img.Interpolation.nearest,
    );
    final detail2 = img.copyResize(
      img.copyCrop(oldCAS, x: dX, y: dY, width: detailW, height: detailH),
      width: 320,
      height: 320,
      interpolation: img.Interpolation.nearest,
    );
    final detail3 = img.copyResize(
      img.copyCrop(newGatedCAS, x: dX, y: dY, width: detailW, height: detailH),
      width: 320,
      height: 320,
      interpolation: img.Interpolation.nearest,
    );

    final detailComparison = _createSideBySide3(
      detail1,
      detail2,
      detail3,
      label1: 'Zoom: Baseline 2x',
      label2: 'Zoom: Old CAS (Noise)',
      label3: 'Zoom: Luma-Gated CAS',
    );

    final outDetailFile = File('${outDir.path}/${baseName}_detail_zoom.png');
    await outDetailFile.writeAsBytes(img.encodePng(detailComparison));
    print('已生成细节特写: ${outDetailFile.path}');
  }

  print('\n全部对比图生成完毕！保存在 temp/comparisons/');
}

img.Image _createSideBySide3(
  img.Image img1,
  img.Image img2,
  img.Image img3, {
  required String label1,
  required String label2,
  required String label3,
}) {
  final gap = 12;
  final headerH = 36;
  final totalW = img1.width + img2.width + img3.width + gap * 2 + 16;
  final totalH = img1.height + headerH + 16;

  final canvas = img.Image(width: totalW, height: totalH);
  img.fill(canvas, color: img.ColorRgba8(24, 24, 26, 255)); // 深色底板

  // 绘制 3 张图片
  final yOffset = headerH + 8;
  img.compositeImage(canvas, img1, dstX: 8, dstY: yOffset);
  img.compositeImage(canvas, img2, dstX: 8 + img1.width + gap, dstY: yOffset);
  img.compositeImage(
    canvas,
    img3,
    dstX: 8 + img1.width + gap + img2.width + gap,
    dstY: yOffset,
  );

  // 绘制标签
  final font = img.arial14;
  img.drawString(
    canvas,
    label1,
    font: font,
    x: 12,
    y: 12,
    color: img.ColorRgba8(200, 200, 200, 255),
  );
  img.drawString(
    canvas,
    label2,
    font: font,
    x: 12 + img1.width + gap,
    y: 12,
    color: img.ColorRgba8(255, 120, 120, 255),
  );
  img.drawString(
    canvas,
    label3,
    font: font,
    x: 12 + img1.width + gap + img2.width + gap,
    y: 12,
    color: img.ColorRgba8(100, 230, 120, 255),
  );

  return canvas;
}
