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
    this.extra = const {},
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

  /// 未来扩展保留字段：未知键透传，用于前瞻兼容（旧版本读新快照不丢字段）。
  final Map<String, dynamic> extra;

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
    Map<String, dynamic>? extra,
  }) {
    return PieceState(
      id: id ?? this.id,
      r: r ?? this.r,
      c: c ?? this.c,
      nx: nx ?? this.nx,
      ny: ny ?? this.ny,
      clusterId: clusterId ?? this.clusterId,
      rot: rot ?? this.rot,
      extra: extra ?? this.extra,
    );
  }

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'id': id,
      'r': r,
      'c': c,
      'nx': nx,
      'ny': ny,
      'g': clusterId,
      'rot': rot,
    };
    // 透传未来字段
    extra.forEach((k, v) {
      if (!m.containsKey(k)) m[k] = v;
    });
    return m;
  }

  factory PieceState.fromJson(Map<String, dynamic> json) {
    const known = {'id', 'r', 'c', 'nx', 'ny', 'g', 'clusterId', 'rot'};
    final extra = <String, dynamic>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) extra[e.key] = e.value;
    }
    return PieceState(
      id: json['id'] as int,
      r: json['r'] as int,
      c: json['c'] as int,
      nx: (json['nx'] as num).toDouble(),
      ny: (json['ny'] as num).toDouble(),
      clusterId: (json['g'] ?? json['clusterId']) as int,
      rot: (json['rot'] ?? 0) as int,
      extra: extra,
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
///
/// v3 前瞻性设计：`version` 显式版本号 + 未知字段透传 `extra`，新增字段均为可选
/// 且带默认值，旧版本读新快照时未知键进入 `extra` 并在下次 `toJson` 原样回写，
/// 做到“旧读新不丢、新读旧兼容”。
class PuzzleBoardState {
  static const int currentVersion = 3;
  static const int minSupportedVersion = 2;

  const PuzzleBoardState({
    required this.rows,
    required this.cols,
    required this.seed,
    this.rotationEnabled = false,
    required this.pieces,
    this.elapsedSeconds = 0,
    this.hintsUsed = 0,
    this.levelId = 'default_level',
    this.version = currentVersion,
    this.canonicalId = 'default_level',
    this.difficultyKey = '',
    this.aspectLabel,
    this.createdAt,
    this.updatedAt,
    this.extra = const {},
  });

  final int rows;
  final int cols;
  final int seed;
  final bool rotationEnabled;
  final List<PieceState> pieces;
  final int elapsedSeconds;
  final int hintsUsed;
  final String levelId;

  /// 显式版本号，当前 3，兼容 2
  final int version;

  /// 全局唯一关卡主键，如 main:042 / daily:20260827 / pack:xxx:file / ugc:xxx
  final String canonicalId;

  /// 难度键，如 10x10，与 rows*cols 强绑定
  final String difficultyKey;

  /// 宽高比标签，如 square1x1 / portrait3x4
  final String? aspectLabel;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// 未来新增字段的透传容器：所有未知顶层键在此回写时原样保留
  final Map<String, dynamic> extra;

  int get totalPieces => rows * cols;

  /// Piece lookup by ID with safety check.
  PieceState pieceById(int id) {
    for (final p in pieces) {
      if (p.id == id) return p;
    }
    throw StateError('PieceState with id=$id not found in PuzzleBoardState (total=${pieces.length})');
  }

  /// Piece lookup by ID, returning null if not found.
  PieceState? pieceByIdOrNull(int id) {
    for (final p in pieces) {
      if (p.id == id) return p;
    }
    return null;
  }

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

  /// Returns true if all border (outer edge) pieces are in their solved positions.
  bool get isEdgeComplete {
    for (final p in pieces) {
      final isBorder = p.r == 0 || p.r == rows - 1 || p.c == 0 || p.c == cols - 1;
      if (isBorder && !p.isSolved(rows, cols)) return false;
    }
    return true;
  }

  /// Returns the set of piece IDs belonging to the largest connected cluster on board.
  Set<int> get mainAssemblyPieceIds {
    if (pieces.isEmpty) return const {};
    final clusterSizes = <int, int>{};
    for (final p in pieces) {
      clusterSizes[p.clusterId] = (clusterSizes[p.clusterId] ?? 0) + 1;
    }
    var maxClusterId = pieces.first.clusterId;
    var maxSize = 0;
    for (final entry in clusterSizes.entries) {
      if (entry.value > maxSize) {
        maxSize = entry.value;
        maxClusterId = entry.key;
      }
    }
    return pieces
        .where((p) => p.clusterId == maxClusterId)
        .map((p) => p.id)
        .toSet();
  }

  String get effectiveDifficultyKey =>
      difficultyKey.isNotEmpty ? difficultyKey : '${rows}x$cols';

  String get effectiveCanonicalId =>
      canonicalId.isNotEmpty ? canonicalId : levelId;

  PuzzleBoardState copyWith({
    int? rows,
    int? cols,
    int? seed,
    bool? rotationEnabled,
    List<PieceState>? pieces,
    int? elapsedSeconds,
    int? hintsUsed,
    String? levelId,
    int? version,
    String? canonicalId,
    String? difficultyKey,
    String? aspectLabel,
    DateTime? createdAt,
    DateTime? updatedAt,
    Map<String, dynamic>? extra,
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
      version: version ?? this.version,
      canonicalId: canonicalId ?? this.canonicalId,
      difficultyKey: difficultyKey ?? this.difficultyKey,
      aspectLabel: aspectLabel ?? this.aspectLabel,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      extra: extra ?? this.extra,
    );
  }

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'version': version,
      'canonicalId': effectiveCanonicalId,
      'difficultyKey': effectiveDifficultyKey,
      'levelId': levelId,
      'seed': seed,
      'rows': rows,
      'cols': cols,
      'rotationEnabled': rotationEnabled,
      'elapsedSeconds': elapsedSeconds,
      'hintsUsed': hintsUsed,
      'pieces': pieces.map((p) => p.toJson()).toList(),
    };
    if (aspectLabel != null) m['aspectLabel'] = aspectLabel;
    if (createdAt != null) m['createdAt'] = createdAt!.toIso8601String();
    if (updatedAt != null) m['updatedAt'] = updatedAt!.toIso8601String();
    // 透传未知字段（不覆盖已知键）
    extra.forEach((k, v) {
      if (!m.containsKey(k)) m[k] = v;
    });
    return m;
  }

  factory PuzzleBoardState.fromJson(Map<String, dynamic> json) {
    const known = {
      'version',
      'canonicalId',
      'difficultyKey',
      'levelId',
      'seed',
      'rows',
      'cols',
      'rotationEnabled',
      'elapsedSeconds',
      'hintsUsed',
      'pieces',
      'aspectLabel',
      'createdAt',
      'updatedAt',
    };
    final extra = <String, dynamic>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) extra[e.key] = e.value;
    }
    final pieceList = (json['pieces'] as List<dynamic>)
        .map((e) => PieceState.fromJson(e as Map<String, dynamic>))
        .toList();

    // 兼容 v2：无 version/canonicalId/difficultyKey
    final ver = (json['version'] as int?) ?? 2;
    final cid = (json['canonicalId'] as String?) ??
        (json['levelId'] as String? ?? 'default_level');
    final dkey = (json['difficultyKey'] as String?) ??
        (json['rows'] != null && json['cols'] != null
            ? '${json['rows']}x${json['cols']}'
            : '');

    return PuzzleBoardState(
      rows: json['rows'] as int,
      cols: json['cols'] as int,
      seed: json['seed'] as int,
      rotationEnabled: (json['rotationEnabled'] ?? false) as bool,
      pieces: pieceList,
      elapsedSeconds: (json['elapsedSeconds'] ?? 0) as int,
      hintsUsed: (json['hintsUsed'] ?? 0) as int,
      levelId: (json['levelId'] ?? cid) as String,
      version: ver,
      canonicalId: cid,
      difficultyKey: dkey,
      aspectLabel: json['aspectLabel'] as String?,
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String)
          : null,
      updatedAt: json['updatedAt'] != null
          ? DateTime.tryParse(json['updatedAt'] as String)
          : null,
      extra: extra,
    );
  }
}
