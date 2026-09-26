import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/game/jigsaw_puzzle_game.dart';
import 'package:jigsawpuzzle/game/puzzle_piece_component.dart';

/// 1x1 transparent PNG used only as a decodable image source.
const _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

Future<ui.Image> _decodePng() => decodeImageFromList(base64Decode(_pngBase64));

Future<JigsawPuzzleGame> _boot() async {
  final img = await _decodePng();
  final g = JigsawPuzzleGame(image: img, rows: 3, cols: 3, onSolved: () {});
  g.onGameResize(Vector2(600, 900));
  await g.onLoad();
  return g;
}

PuzzlePieceComponent _piece(JigsawPuzzleGame g, int id) =>
    g.children.whereType<PuzzlePieceComponent>().firstWhere((c) => c.id == id);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('回归：拖回托盘必须同步权威状态', () {
    test('拖回托盘后 _boardState 写入 inTray 与托盘哨兵 ny', () async {
      final g = await _boot();
      final c4 = _piece(g, 4); // r=1,c=1，非边缘片

      // 构造"坐标已在槽位、但装配体未连通边缘"的孤岛态：可拖动、未锁定
      g.boardState = g.boardState.copyWith(
        pieces: g.boardState.pieces.map((p) {
          if (p.id != 4) return p;
          return p.copyWith(
            nx: p.targetNx(3),
            ny: p.targetNy(3),
            inTray: false,
          );
        }).toList(),
      );
      g.updatePiecesStateAndPriorities();
      expect(c4.isLocked, isFalse, reason: '孤岛内部片不应被锁定');

      g.startHoldingPiece(c4, 0.5, 0.5);
      g.updateHoldingPiecePosition(
        Vector2(g.trayPosition.x + 40, g.trayPosition.y + 20),
      );
      g.dropHoldingPiece();

      final after = g.boardState.pieceById(4);
      expect(c4.isInTray, isTrue, reason: '组件应进入托盘');
      expect(after.inTray, isTrue, reason: '权威状态必须同步 inTray');
      expect(
        after.ny,
        greaterThanOrEqualTo(2.0),
        reason: '权威状态必须写入托盘哨兵 ny（>=2.0）',
      );
    });

    test('拖回托盘的碎片不会在外框补全后被搬回棋盘并锁定', () async {
      final g = await _boot();
      final c4 = _piece(g, 4);

      g.boardState = g.boardState.copyWith(
        pieces: g.boardState.pieces.map((p) {
          if (p.id != 4) return p;
          return p.copyWith(
            nx: p.targetNx(3),
            ny: p.targetNy(3),
            inTray: false,
          );
        }).toList(),
      );
      g.updatePiecesStateAndPriorities();

      g.startHoldingPiece(c4, 0.5, 0.5);
      g.updateHoldingPiecePosition(
        Vector2(g.trayPosition.x + 40, g.trayPosition.y + 20),
      );
      g.dropHoldingPiece();
      expect(c4.isInTray, isTrue);

      // 外框全部归位 -> #4 变为连通装配体成员
      g.boardState = g.boardState.copyWith(
        pieces: g.boardState.pieces.map((p) {
          if (p.id == 4) return p;
          return p.copyWith(
            nx: p.targetNx(3),
            ny: p.targetNy(3),
            inTray: false,
          );
        }).toList(),
      );
      g.updatePiecesStateAndPriorities();

      expect(c4.isInTray, isTrue, reason: '托盘碎片严禁被搬出托盘');
      expect(c4.isLocked, isFalse, reason: '托盘碎片严禁被锁定');
      expect(
        c4.position.y,
        greaterThanOrEqualTo(g.trayPosition.y - 1.0),
        reason: '碎片必须留在托盘区域内，不得瞬移回棋盘',
      );
    });

    test('拖回托盘后进度不再把该碎片计为已就位', () async {
      final g = await _boot();
      final c4 = _piece(g, 4);

      g.boardState = g.boardState.copyWith(
        pieces: g.boardState.pieces.map((p) {
          if (p.id != 4) return p;
          return p.copyWith(
            nx: p.targetNx(3),
            ny: p.targetNy(3),
            inTray: false,
          );
        }).toList(),
      );
      g.updatePiecesStateAndPriorities();
      expect(g.solvedCount, 1, reason: '前置条件：#4 处于槽位应计入进度');

      g.startHoldingPiece(c4, 0.5, 0.5);
      g.updateHoldingPiecePosition(
        Vector2(g.trayPosition.x + 40, g.trayPosition.y + 20),
      );
      g.dropHoldingPiece();

      expect(g.solvedCount, 0, reason: '拖回托盘后该碎片不应再计入已就位');
    });
  });

  group('回归：页面平移判据 isPickablePieceAt', () {
    test('命中可拾取碎片 / 空白 / 已锁定碎片的判定', () async {
      final g = await _boot();
      final c0 = _piece(g, 0);

      // 托盘中的碎片：命中其中心应判为可拾取
      final trayCenter = Vector2(
        c0.position.x + c0.size.x * c0.scale.x / 2,
        c0.position.y + c0.size.y * c0.scale.y / 2,
      );
      expect(g.isPickablePieceAt(trayCenter), isTrue);

      // 棋盘空白区（棋盘上方、托盘之上）不应命中碎片
      expect(g.isPickablePieceAt(Vector2(4, 4)), isFalse);

      // 已锁定碎片不算可拾取：在其上拖动仍应平移棋盘
      g.boardState = g.boardState.copyWith(
        pieces: g.boardState.pieces.map((p) {
          if (p.id != 0) return p;
          return p.copyWith(nx: p.targetNx(3), ny: p.targetNy(3));
        }).toList(),
      );
      g.updatePiecesStateAndPriorities();
      expect(c0.isLocked, isTrue, reason: '边缘片归位后应被锁定');
      final lockedCenter = Vector2(
        c0.position.x + c0.size.x * c0.scale.x / 2,
        c0.position.y + c0.size.y * c0.scale.y / 2,
      );
      expect(g.isPickablePieceAt(lockedCenter), isFalse);
    });
  });
}
