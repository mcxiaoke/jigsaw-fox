/// Immutable state representing a single puzzle piece on the board.
class PieceState {
  const PieceState({
    required this.id,
    required this.r,
    required this.c,
    required this.nx,
    required this.ny,
    required this.clusterId,
    this.rot = 0,
  });

  /// Unique piece index (0 <= id < rows * cols).
  final int id;

  /// Target grid row index (0 <= r < rows).
  final int r;

  /// Target grid column index (0 <= c < cols).
  final int c;

  /// Normalized top-left X coordinate relative to the board bounds.
  /// Target position is `c / cols`.
  final double nx;

  /// Normalized top-left Y coordinate relative to the board bounds.
  /// Target position is `r / rows`.
  final double ny;

  /// Identifies which cluster/group this piece is currently merged with.
  final int clusterId;

  /// Discrete orientation (0 = 0°, 1 = 90°, 2 = 180°, 3 = 270° clockwise).
  final int rot;

  /// Target normalized X coordinate on the board.
  double targetNx(int cols) => c / cols;

  /// Target normalized Y coordinate on the board.
  double targetNy(int rows) => r / rows;

  /// Check if the piece is at its solved slot (within epsilon) and correctly oriented.
  bool isSolved(int rows, int cols, {double epsilon = 0.035}) {
    final tnx = targetNx(cols);
    final tny = targetNy(rows);
    return (nx - tnx).abs() <= epsilon &&
        (ny - tny).abs() <= epsilon &&
        (rot % 4 == 0);
  }

  PieceState copyWith({
    int? id,
    int? r,
    int? c,
    double? nx,
    double? ny,
    int? clusterId,
    int? rot,
  }) {
    return PieceState(
      id: id ?? this.id,
      r: r ?? this.r,
      c: c ?? this.c,
      nx: nx ?? this.nx,
      ny: ny ?? this.ny,
      clusterId: clusterId ?? this.clusterId,
      rot: rot ?? this.rot,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'r': r,
        'c': c,
        'nx': nx,
        'ny': ny,
        'g': clusterId,
        'rot': rot,
      };

  factory PieceState.fromJson(Map<String, dynamic> json) {
    return PieceState(
      id: json['id'] as int,
      r: json['r'] as int,
      c: json['c'] as int,
      nx: (json['nx'] as num).toDouble(),
      ny: (json['ny'] as num).toDouble(),
      clusterId: (json['g'] ?? json['clusterId']) as int,
      rot: (json['rot'] ?? 0) as int,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PieceState &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          r == other.r &&
          c == other.c &&
          nx == other.nx &&
          ny == other.ny &&
          clusterId == other.clusterId &&
          rot == other.rot;

  @override
  int get hashCode => Object.hash(id, r, c, nx, ny, clusterId, rot);

  @override
  String toString() =>
      'PieceState(id:$id, r:$r, c:$c, nx:${nx.toStringAsFixed(3)}, ny:${ny.toStringAsFixed(3)}, cluster:$clusterId, rot:$rot)';
}

/// Immutable snapshot of the puzzle board.
class PuzzleBoardState {
  const PuzzleBoardState({
    required this.rows,
    required this.cols,
    required this.seed,
    this.rotationEnabled = false,
    required this.pieces,
    this.elapsedSeconds = 0,
    this.hintsUsed = 0,
    this.levelId = 'default_level',
  });

  final int rows;
  final int cols;
  final int seed;
  final bool rotationEnabled;
  final List<PieceState> pieces;
  final int elapsedSeconds;
  final int hintsUsed;
  final String levelId;

  int get totalPieces => rows * cols;

  /// Piece lookup by ID.
  PieceState pieceById(int id) => pieces.firstWhere((p) => p.id == id);

  /// Returns all pieces belonging to a cluster.
  List<PieceState> piecesInCluster(int clusterId) =>
      pieces.where((p) => p.clusterId == clusterId).toList();

  /// Count of unique clusters on board.
  int get clusterCount => pieces.map((p) => p.clusterId).toSet().length;

  /// Returns true if all pieces are correctly aligned and oriented.
  bool get isSolved {
    for (final p in pieces) {
      if (!p.isSolved(rows, cols)) return false;
    }
    return true;
  }

  PuzzleBoardState copyWith({
    int? rows,
    int? cols,
    int? seed,
    bool? rotationEnabled,
    List<PieceState>? pieces,
    int? elapsedSeconds,
    int? hintsUsed,
    String? levelId,
  }) {
    return PuzzleBoardState(
      rows: rows ?? this.rows,
      cols: cols ?? this.cols,
      seed: seed ?? this.seed,
      rotationEnabled: rotationEnabled ?? this.rotationEnabled,
      pieces: pieces ?? this.pieces,
      elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
      hintsUsed: hintsUsed ?? this.hintsUsed,
      levelId: levelId ?? this.levelId,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': 2,
        'levelId': levelId,
        'seed': seed,
        'rows': rows,
        'cols': cols,
        'rotationEnabled': rotationEnabled,
        'elapsedSeconds': elapsedSeconds,
        'hintsUsed': hintsUsed,
        'pieces': pieces.map((p) => p.toJson()).toList(),
      };

  factory PuzzleBoardState.fromJson(Map<String, dynamic> json) {
    final pieceList = (json['pieces'] as List<dynamic>)
        .map((e) => PieceState.fromJson(e as Map<String, dynamic>))
        .toList();

    return PuzzleBoardState(
      rows: json['rows'] as int,
      cols: json['cols'] as int,
      seed: json['seed'] as int,
      rotationEnabled: (json['rotationEnabled'] ?? false) as bool,
      pieces: pieceList,
      elapsedSeconds: (json['elapsedSeconds'] ?? 0) as int,
      hintsUsed: (json['hintsUsed'] ?? 0) as int,
      levelId: (json['levelId'] ?? 'default_level') as String,
    );
  }
}

/// Result of an engine transition (e.g. after a drag release).
class BoardTransitionResult {
  const BoardTransitionResult({
    required this.state,
    required this.didSnap,
    required this.didMerge,
    required this.affectedPieceIds,
    required this.isCompleted,
  });

  final PuzzleBoardState state;
  final bool didSnap;
  final bool didMerge;
  final List<int> affectedPieceIds;
  final bool isCompleted;
}

/// Result of a hint query.
class HintResult {
  const HintResult({
    required this.pieceId,
    required this.targetNx,
    required this.targetNy,
  });

  final int pieceId;
  final double targetNx;
  final double targetNy;
}
