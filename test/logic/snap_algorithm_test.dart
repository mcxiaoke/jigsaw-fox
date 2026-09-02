import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/engine/puzzle_engine.dart';
import 'package:jigsawpuzzle/logic/models/puzzle_state.dart';

void main() {
  group('Snap & Cluster Merging Tests', () {
    test('Snap to board target slot when near correct position', () {
      final initialPieces = [
        const PieceState(id: 0, r: 0, c: 0, nx: 0.02, ny: 0.02, clusterId: 0),
        const PieceState(id: 1, r: 0, c: 1, nx: 0.8, ny: 0.8, clusterId: 1),
      ];

      final boardState = PuzzleBoardState(
        rows: 1,
        cols: 2,
        seed: 1,
        pieces: initialPieces,
      );

      final result = PuzzleEngine.resolveSnap(
        state: boardState,
        draggedPieceId: 0,
        customSnapDistance: 0.1,
      );

      expect(result.didSnap, isTrue);
      final snappedPiece = result.state.pieceById(0);
      expect(snappedPiece.nx, 0.0);
      expect(snappedPiece.ny, 0.0);
    });

    test('Snap and merge two adjacent neighbor pieces', () {
      // Piece 0 at (0, 0) and Piece 1 at (0, 1) in 2x2 board
      // Expected relative dx is 0.5 (1 / 2 cols)
      // Place Piece 0 at (0.3, 0.3), Piece 1 at (0.82, 0.31) -> error ~ 0.022
      final pieces = [
        const PieceState(id: 0, r: 0, c: 0, nx: 0.30, ny: 0.30, clusterId: 0),
        const PieceState(id: 1, r: 0, c: 1, nx: 0.82, ny: 0.31, clusterId: 1),
      ];

      final boardState = PuzzleBoardState(
        rows: 1,
        cols: 2,
        seed: 1,
        pieces: pieces,
      );

      final result = PuzzleEngine.resolveSnap(
        state: boardState,
        draggedPieceId: 0,
        customSnapDistance: 0.08,
      );

      expect(result.didSnap, isTrue);
      expect(result.didMerge, isTrue);

      final p0 = result.state.pieceById(0);
      final p1 = result.state.pieceById(1);

      // Now both pieces share the same clusterId
      expect(p0.clusterId, equals(p1.clusterId));
      // Relative offset is exact: p1.nx - p0.nx == 0.5
      expect((p1.nx - p0.nx - 0.5).abs() < 0.001, isTrue);
      expect((p1.ny - p0.ny).abs() < 0.001, isTrue);
    });

    test('Solved detection when all pieces are correctly aligned', () {
      final solvedPieces = [
        const PieceState(id: 0, r: 0, c: 0, nx: 0.0, ny: 0.0, clusterId: 0),
        const PieceState(id: 1, r: 0, c: 1, nx: 0.5, ny: 0.0, clusterId: 0),
        const PieceState(id: 2, r: 1, c: 0, nx: 0.0, ny: 0.5, clusterId: 0),
        const PieceState(id: 3, r: 1, c: 1, nx: 0.5, ny: 0.5, clusterId: 0),
      ];

      final boardState = PuzzleBoardState(
        rows: 2,
        cols: 2,
        seed: 1,
        pieces: solvedPieces,
      );

      expect(boardState.isSolved, isTrue);
    });

    test(
      'Pieces in tray (not in onBoardPieceIds) must NOT merge with board pieces or neighbor tray pieces',
      () {
        // 假设 Piece 0 在棋盘 (0.3, 0.3)，Piece 1 留在托盘 (0.8, 0.3)
        final pieces = [
          const PieceState(id: 0, r: 0, c: 0, nx: 0.30, ny: 0.30, clusterId: 0),
          const PieceState(id: 1, r: 0, c: 1, nx: 0.80, ny: 0.30, clusterId: 1),
        ];

        final boardState = PuzzleBoardState(
          rows: 1,
          cols: 2,
          seed: 1,
          pieces: pieces,
        );

        // 仅 Piece 0 在棋盘上
        final result = PuzzleEngine.resolveSnap(
          state: boardState,
          draggedPieceId: 0,
          onBoardPieceIds: {0},
          customSnapDistance: 0.1,
        );

        // Piece 1 不在棋盘上，严禁发生合并
        expect(result.didMerge, isFalse);
        final p0 = result.state.pieceById(0);
        final p1 = result.state.pieceById(1);
        expect(p0.clusterId, isNot(equals(p1.clusterId)));
        expect(p0.clusterId, 0);
        expect(p1.clusterId, 1);
      },
    );

    test('孤立内部碎片即使位置正确也不吸附锁定（连通到边缘规则）', () {
      // 3x3：id=4 是中心内部碎片 (r=1,c=1)，位于其正确槽位 (1/3, 1/3)。
      // 但它的四个邻居 (0,1),(2,1),(1,0),(1,2) 均远离槽位（未就位），故不连通到边缘装配体。
      final pieces = <PieceState>[
        const PieceState(id: 4, r: 1, c: 1, nx: 1 / 3, ny: 1 / 3, clusterId: 4),
        const PieceState(id: 1, r: 0, c: 1, nx: -0.9, ny: -0.9, clusterId: 1),
        const PieceState(id: 7, r: 2, c: 1, nx: -0.9, ny: -0.9, clusterId: 7),
        const PieceState(id: 3, r: 1, c: 0, nx: -0.9, ny: -0.9, clusterId: 3),
        const PieceState(id: 5, r: 1, c: 2, nx: -0.9, ny: -0.9, clusterId: 5),
        const PieceState(id: 0, r: 0, c: 0, nx: -0.9, ny: -0.9, clusterId: 0),
        const PieceState(id: 2, r: 0, c: 2, nx: 1.9, ny: 1.9, clusterId: 2),
        const PieceState(id: 6, r: 2, c: 0, nx: -0.9, ny: -0.9, clusterId: 6),
        const PieceState(id: 8, r: 2, c: 2, nx: 1.9, ny: 1.9, clusterId: 8),
      ];
      final boardState = PuzzleBoardState(
        rows: 3,
        cols: 3,
        seed: 1,
        pieces: pieces,
      );

      // 孤立内部碎片不属于“边缘长出装配体”
      expect(
        PuzzleEngine.computePlantedPieceIds(boardState).contains(4),
        isFalse,
        reason: '孤立内部碎片（无边缘、无已就位邻居）不属于已植入装配体',
      );

      // 松手吸附：即便恰好落在正确槽位（dist=0），也拒绝吸附，保持游离可移动
      final result = PuzzleEngine.resolveSnap(
        state: boardState,
        draggedPieceId: 4,
        onBoardPieceIds: pieces.map((p) => p.id).toSet(),
        customSnapDistance: 0.2,
      );
      expect(result.didSnap, isFalse, reason: '孤立内部碎片不应被吸附锁定');
      expect(result.didMerge, isFalse);
      expect(result.state.pieceById(4).clusterId, 4, reason: '仍是独立簇，可被移动/扫把回收');
    });

    test('内部两片岛屿即使都位正且相邻，不连通边缘也不吸附锁定', () {
      // 4x4：内部区为 r,c ∈ {1,2}。取 (1,1) 与 (1,2) 两块真·内部碎片，
      // 都位于各自正确槽位且互为邻居，但都不在四边上、也不与任何边缘装配体连接
      // → 整体“空中岛屿”，必须保持可拖动（即便相互拼合成自由集群也不锁定）。
      final far = <PieceState>[];
      for (var id = 0; id < 16; id++) {
        final r = id ~/ 4, c = id % 4;
        far.add(
          PieceState(
            id: id,
            r: r,
            c: c,
            nx: r == 3 ? 1.9 : -0.9,
            ny: c == 3 ? 1.9 : -0.9,
            clusterId: id,
          ),
        );
      }
      final pieces = [
        for (final p in far)
          if (p.r == 1 && p.c == 1)
            const PieceState(
              id: 5,
              r: 1,
              c: 1,
              nx: 1 / 4,
              ny: 1 / 4,
              clusterId: 5,
            )
          else if (p.r == 1 && p.c == 2)
            const PieceState(
              id: 6,
              r: 1,
              c: 2,
              nx: 2 / 4,
              ny: 1 / 4,
              clusterId: 6,
            )
          else
            p,
      ];
      final boardState = PuzzleBoardState(
        rows: 4,
        cols: 4,
        seed: 1,
        pieces: pieces,
      );

      final planted = PuzzleEngine.computePlantedPieceIds(boardState);
      expect(planted.contains(5), isFalse, reason: '内部岛屿第1块不属于装配体');
      expect(planted.contains(6), isFalse, reason: '内部岛屿第2块不属于装配体');

      // 岛屿内部可相互拼合/群组（自由集群），但绝不锁定：不连通边缘 → 始终不植入、保持可拖动
      final result = PuzzleEngine.resolveSnap(
        state: boardState,
        draggedPieceId: 5,
        onBoardPieceIds: pieces.map((p) => p.id).toSet(),
        customSnapDistance: 0.2,
      );
      final plantedAfter = PuzzleEngine.computePlantedPieceIds(result.state);
      expect(
        plantedAfter.contains(5),
        isFalse,
        reason: '内部岛屿即便已拼合，仍不连通边缘，不得锁定',
      );
      expect(
        plantedAfter.contains(6),
        isFalse,
        reason: '内部岛屿即便已拼合，仍不连通边缘，不得锁定',
      );
    });

    test('边缘碎片可独立吸附；与已就位装配体相邻的内部碎片也可吸附', () {
      // id=1 是 3x3 上边中央 (r=0,c=1) 已就位；id=4 是内部碎片 (r=1,c=1) 正与其相邻。
      // 装配体 {(0,1),(1,1)} 连通到边缘，故 id=4 具备锚定，可被吸附。
      final pieces = <PieceState>[
        const PieceState(id: 1, r: 0, c: 1, nx: 1 / 3, ny: 0.0, clusterId: 1),
        const PieceState(id: 4, r: 1, c: 1, nx: 1 / 3, ny: 1 / 3, clusterId: 4),
        const PieceState(id: 0, r: 0, c: 0, nx: -0.9, ny: -0.9, clusterId: 0),
        const PieceState(id: 2, r: 0, c: 2, nx: 1.9, ny: 1.9, clusterId: 2),
        const PieceState(id: 3, r: 1, c: 0, nx: -0.9, ny: -0.9, clusterId: 3),
        const PieceState(id: 5, r: 1, c: 2, nx: -0.9, ny: -0.9, clusterId: 5),
        const PieceState(id: 6, r: 2, c: 0, nx: 1.9, ny: 1.9, clusterId: 6),
        const PieceState(id: 7, r: 2, c: 1, nx: -0.9, ny: -0.9, clusterId: 7),
        const PieceState(id: 8, r: 2, c: 2, nx: 1.9, ny: 1.9, clusterId: 8),
      ];
      final boardState = PuzzleBoardState(
        rows: 3,
        cols: 3,
        seed: 1,
        pieces: pieces,
      );

      expect(
        PuzzleEngine.isBorderPiece(3, 3, 0, 1),
        isTrue,
        reason: 'id=1 是边缘碎片',
      );
      final planted = PuzzleEngine.computePlantedPieceIds(boardState);
      expect(planted.contains(1), isTrue, reason: '边缘碎片在装配体内');
      expect(planted.contains(4), isTrue, reason: '与已就位的边缘碎片连通，故在装配体内');
      expect(
        PuzzleEngine.canSnapCluster(boardState, [
          const PieceState(id: 4, r: 1, c: 1, nx: 0, ny: 0, clusterId: 4),
        ]),
        isTrue,
        reason: '可接到装配体，允许吸附',
      );

      // 内部碎片在连通后可正常吸附到槽位
      final result = PuzzleEngine.resolveSnap(
        state: boardState,
        draggedPieceId: 4,
        onBoardPieceIds: pieces.map((p) => p.id).toSet(),
        customSnapDistance: 0.2,
      );
      expect(result.didSnap, isTrue, reason: '连通后内部碎片可吸附');
      expect(result.state.pieceById(4).nx, closeTo(1 / 3, 0.001));
      expect(result.state.pieceById(4).ny, closeTo(1 / 3, 0.001));
    });
  });
}
