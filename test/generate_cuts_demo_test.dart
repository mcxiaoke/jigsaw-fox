import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart'
    show BlurStyle, Color, MaskFilter, Paint, PaintingStyle, Rect;
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/geometry/edge_layout.dart';
import 'package:jigsawpuzzle/logic/geometry/piece_shape.dart';

Future<ui.Image> _loadImage(String path) async {
  final file = File(path);
  final bytes = await file.readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}

Future<void> _savePictureToPng(ui.Picture picture, int width, int height, String outputPath) async {
  final image = await picture.toImage(width, height);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  final buffer = byteData!.buffer.asUint8List();
  final file = File(outputPath);
  await file.writeAsBytes(buffer);
  // ignore: avoid_print
  print('Saved sample cut to $outputPath (${width}x$height)');
}

void main() {
  test('Generate sample jigsaw cut images to temp directory', () async {
    final image1 = await _loadImage('assets/images/sample_01.jpg');
    final image2 = await _loadImage('assets/images/sample_02.jpg');

    final bgPaint = Paint()..color = const Color(0xFF5A728A); // Classic Jigsaw Explorer blue desk background
    final shadowPaint = Paint()
      ..color = const Color(0x45000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5.0)
      ..isAntiAlias = true;
    final outlinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = const Color(0x35000000)
      ..isAntiAlias = true;
    final imagePaint = Paint()
      ..filterQuality = ui.FilterQuality.medium
      ..isAntiAlias = true;

    // -------------------------------------------------------------
    // Demo 1: Real-life Scattered Pieces on Desk (Jigsaw Explorer tabletop style)
    // -------------------------------------------------------------
    {
      const rows = 4;
      const cols = 4;
      const seed = 42;

      final edgeLayout = EdgeLayout(rows: rows, cols: cols, seed: seed);
      final pieceW = image1.width / cols;
      final pieceH = image1.height / rows;

      const canvasW = 1600;
      const canvasH = 1200;
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder, const Rect.fromLTWH(0, 0, canvasW + 0.0, canvasH + 0.0));

      // Draw background desk
      canvas.drawRect(const Rect.fromLTWH(0, 0, canvasW + 0.0, canvasH + 0.0), bgPaint);

      // Scatter pieces nicely across desk with random slight offsets and angles
      final rng = Random(seed);
      for (var r = 0; r < rows; r++) {
        for (var c = 0; c < cols; c++) {
          final edges = edgeLayout.edgesFor(r, c);
          final shape = PieceShape(edges: edges, width: pieceW * 0.7, height: pieceH * 0.7);
          final srcRect = shape.srcRect(
            row: r,
            col: c,
            srcWidthPerCol: pieceW,
            srcHeightPerRow: pieceH,
          );

          // Grid placement with scattered organic jitter
          final colX = 100.0 + c * (pieceW * 0.7 + 90.0) + (rng.nextDouble() - 0.5) * 40.0;
          final rowY = 80.0 + r * (pieceH * 0.7 + 80.0) + (rng.nextDouble() - 0.5) * 30.0;

          canvas.save();
          canvas.translate(colX, rowY);

          // 1. Drop shadow
          canvas.save();
          canvas.translate(0, 5.0);
          canvas.drawPath(shape.path, shadowPaint);
          canvas.restore();

          // 2. Texture & Cutline
          canvas.save();
          canvas.clipPath(shape.path);
          canvas.drawImageRect(image1, srcRect, shape.fillRect, imagePaint);
          canvas.drawPath(shape.path, outlinePaint);
          canvas.restore();

          canvas.restore();
        }
      }

      final picture = recorder.endRecording();
      await _savePictureToPng(picture, canvasW, canvasH, 'temp/sample_cuts_scattered_tabletop.png');
    }

    // -------------------------------------------------------------
    // Demo 2: 6x6 High-Density Seamless Assembled Cutlines (sample_02.jpg)
    // -------------------------------------------------------------
    {
      const rows = 6;
      const cols = 6;
      const seed = 888;

      final edgeLayout = EdgeLayout(rows: rows, cols: cols, seed: seed);
      final imgW = image2.width.toDouble();
      final imgH = image2.height.toDouble();
      final pieceW = imgW / cols;
      final pieceH = imgH / rows;

      final canvasW = (imgW + 120).toInt();
      final canvasH = (imgH + 120).toInt();
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder, Rect.fromLTWH(0, 0, canvasW + 0.0, canvasH + 0.0));

      canvas.drawRect(Rect.fromLTWH(0, 0, canvasW + 0.0, canvasH + 0.0), Paint()..color = const Color(0xFF22262B));

      canvas.save();
      canvas.translate(60.0, 60.0);

      // Draw shadow for whole board
      canvas.save();
      canvas.translate(0, 6.0);
      canvas.drawRect(Rect.fromLTWH(0, 0, imgW, imgH), shadowPaint);
      canvas.restore();

      for (var r = 0; r < rows; r++) {
        for (var c = 0; c < cols; c++) {
          final edges = edgeLayout.edgesFor(r, c);
          final shape = PieceShape(edges: edges, width: pieceW, height: pieceH);
          final srcRect = shape.srcRect(
            row: r,
            col: c,
            srcWidthPerCol: pieceW,
            srcHeightPerRow: pieceH,
          );

          canvas.save();
          canvas.translate(c * pieceW, r * pieceH);

          canvas.save();
          canvas.clipPath(shape.path);
          canvas.drawImageRect(image2, srcRect, shape.fillRect, imagePaint);
          canvas.drawPath(shape.path, outlinePaint);
          canvas.restore();

          canvas.restore();
        }
      }
      canvas.restore();

      final picture = recorder.endRecording();
      await _savePictureToPng(picture, canvasW, canvasH, 'temp/sample_cuts_assembled_6x6.png');
    }

    // -------------------------------------------------------------
    // Demo 3: 4 Distinct Shapes Close-up (Ball, Stub, Sock, Finger)
    // -------------------------------------------------------------
    {
      const canvasW = 1000;
      const canvasH = 460;
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder, const Rect.fromLTWH(0, 0, canvasW + 0.0, canvasH + 0.0));

      canvas.drawRect(const Rect.fromLTWH(0, 0, canvasW + 0.0, canvasH + 0.0), Paint()..color = const Color(0xFF1E2833));

      const rows = 3;
      const cols = 4;
      final edgeLayout = EdgeLayout(rows: rows, cols: cols, seed: 101);
      final pieceW = image1.width / cols;
      final pieceH = image1.height / rows;

      // Draw 4 distinct pieces
      for (var i = 0; i < 4; i++) {
        final r = 1;
        final c = i;
        final edges = edgeLayout.edgesFor(r, c);
        final shape = PieceShape(edges: edges, width: 170.0, height: 170.0);
        final srcRect = shape.srcRect(
          row: r,
          col: c,
          srcWidthPerCol: pieceW,
          srcHeightPerRow: pieceH,
        );

        final posX = 50.0 + i * 230.0;
        const posY = 130.0;

        canvas.save();
        canvas.translate(posX, posY);

        // Shadow
        canvas.save();
        canvas.translate(0, 6.0);
        canvas.drawPath(shape.path, shadowPaint);
        canvas.restore();

        // Piece
        canvas.save();
        canvas.clipPath(shape.path);
        canvas.drawImageRect(image1, srcRect, shape.fillRect, imagePaint);
        canvas.drawPath(shape.path, outlinePaint);
        canvas.restore();

        canvas.restore();
      }

      final picture = recorder.endRecording();
      await _savePictureToPng(picture, canvasW, canvasH, 'temp/sample_cuts_closeup_shapes.png');
    }
  });
}
