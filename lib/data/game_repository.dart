import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../logic/image_source.dart';
import '../logic/puzzle_model.dart';
import 'bing_daily_data.dart';
import 'models/custom_puzzle_item.dart';
import 'models/daily_challenge.dart';
import 'models/level_item.dart';

/// Central game data repository managing main levels, daily challenges, UGC custom puzzles, and persistent state.
class GameRepository {
  GameRepository._();
  static final GameRepository instance = GameRepository._();

  static const List<String> kBackgroundAssets = [
    'assets/images/bg_000.webp',
    'assets/images/bg_001.webp',
    'assets/images/bg_002.webp',
    'assets/images/bg_003.webp',
    'assets/images/bg_004.webp',
    'assets/images/bg_005.webp',
    'assets/images/bg_006.webp',
    'assets/images/bg_007.webp',
    'assets/images/bg_008.webp',
  ];

  static const String _keyLevelsPrefix = 'jigsaw_level_';
  static const String _keyDailyPrefix = 'jigsaw_daily_';
  static const String _keyCustomList = 'jigsaw_custom_list';
  static const String _keySoundEnabled = 'jigsaw_setting_sound';
  static const String _keyHapticEnabled = 'jigsaw_setting_haptic';
  static const String _keyGridPreviewEnabled = 'jigsaw_setting_grid_preview';
  static const String _keySelectedBackground = 'jigsaw_setting_selected_background';
  static const String _keyTotalCompleted = 'jigsaw_stat_total_completed';
  static const String _keyTotalPiecesSnapped = 'jigsaw_stat_total_pieces_snapped';
  static const String _keyTotalPlayTimeSeconds = 'jigsaw_stat_total_play_time';

  SharedPreferences? _prefs;
  List<LevelItem> _levels = [];
  List<DailyChallengeItem> _dailyChallenges = [];
  List<CustomPuzzleItem> _customPuzzles = [];

  List<LevelItem> get levels => List.unmodifiable(_levels);
  List<DailyChallengeItem> get dailyChallenges => List.unmodifiable(_dailyChallenges);
  List<CustomPuzzleItem> get customPuzzles => List.unmodifiable(_customPuzzles);

  bool get soundEnabled => _prefs?.getBool(_keySoundEnabled) ?? true;
  set soundEnabled(bool v) => _prefs?.setBool(_keySoundEnabled, v);

  bool get hapticEnabled => _prefs?.getBool(_keyHapticEnabled) ?? true;
  set hapticEnabled(bool v) => _prefs?.setBool(_keyHapticEnabled, v);

  bool get gridPreviewEnabled => _prefs?.getBool(_keyGridPreviewEnabled) ?? true;
  set gridPreviewEnabled(bool v) => _prefs?.setBool(_keyGridPreviewEnabled, v);

  String get selectedBackground =>
      _prefs?.getString(_keySelectedBackground) ?? kBackgroundAssets[0];
  set selectedBackground(String v) => _prefs?.setString(_keySelectedBackground, v);

  int get totalCompletedLevels => _prefs?.getInt(_keyTotalCompleted) ?? 0;
  int get totalPiecesSnapped => _prefs?.getInt(_keyTotalPiecesSnapped) ?? 0;
  int get totalPlayTimeSeconds => _prefs?.getInt(_keyTotalPlayTimeSeconds) ?? 0;

  /// Initializes persistent store and generates predefined levels, daily challenge series, and UGC presets.
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _initLevels();
    _initDailyChallenges();
    _initCustomPuzzles();
  }

  void _initLevels() {
    final list = <LevelItem>[];
    const totalLevels = 100;

    for (var i = 1; i <= totalLevels; i++) {
      final assetPath = assetSamples[(i - 1) % assetSamples.length];

      // Tier difficulty progression (16 -> 25 -> 36 -> 64 -> 100 -> 225)
      final squareTiers = PuzzleAspectRatio.square1x1.tiers;
      PuzzleDifficulty diff;
      if (i <= 10) {
        diff = squareTiers[0].difficulty; // 4x4 (16)
      } else if (i <= 25) {
        diff = squareTiers[1].difficulty; // 5x5 (25)
      } else if (i <= 50) {
        diff = squareTiers[2].difficulty; // 6x6 (36)
      } else if (i <= 75) {
        diff = squareTiers[3].difficulty; // 8x8 (64)
      } else if (i <= 90) {
        diff = squareTiers[4].difficulty; // 10x10 (100)
      } else {
        diff = squareTiers[6].difficulty; // 15x15 (225)
      }

      // Read saved status from SharedPreferences
      final key = '$_keyLevelsPrefix$i';
      final savedStr = _prefs?.getString(key);
      if (savedStr != null) {
        try {
          final json = jsonDecode(savedStr) as Map<String, dynamic>;
          list.add(LevelItem.fromJson(json));
          continue;
        } catch (_) {}
      }

      // Default level state (Level 1 is unlocked initially)
      list.add(
        LevelItem(
          id: 'level_$i',
          index: i,
          title: '第 $i 关',
          assetPath: assetPath,
          difficulty: diff,
          isUnlocked: i == 1,
          isCompleted: false,
          progressPercent: 0,
        ),
      );
    }
    _levels = list;
  }

  void _initDailyChallenges() {
    final list = <DailyChallengeItem>[];

    // Load from Bing 30-day dataset
    for (final item in kBingDaily30Days) {
      final key = '$_keyDailyPrefix${item.dateStr}';
      final savedStr = _prefs?.getString(key);
      if (savedStr != null) {
        try {
          final json = jsonDecode(savedStr) as Map<String, dynamic>;
          var daily = DailyChallengeItem.fromJson(json);
          // Sanitize potential outdated asset path
          if (!daily.assetPath.startsWith('assets/images/sample_')) {
            daily = daily.copyWith(assetPath: item.fallbackAsset);
          }
          list.add(daily);
          continue;
        } catch (_) {}
      }

      final diff = PuzzleDifficulty.presets.firstWhere(
        (d) => d.rows == item.defaultRows && d.cols == item.defaultCols,
        orElse: () => PuzzleDifficulty.presets[5],
      );

      list.add(
        DailyChallengeItem(
          id: 'daily_${item.dateStr}',
          date: item.dateStr,
          dayNumber: item.dayNumber,
          title: item.title,
          author: item.author,
          assetPath: item.fallbackAsset,
          difficulty: diff,
        ),
      );
    }
    _dailyChallenges = list;
  }

  void _initCustomPuzzles() {
    final savedListStr = _prefs?.getString(_keyCustomList);
    if (savedListStr != null) {
      try {
        final rawList = jsonDecode(savedListStr) as List<dynamic>;
        _customPuzzles = rawList
            .map((e) => CustomPuzzleItem.fromJson(e as Map<String, dynamic>))
            .toList();
        return;
      } catch (_) {}
    }

    // Default preset samples for "My Puzzles"
    final squareTiers = PuzzleAspectRatio.square1x1.tiers;
    _customPuzzles = [
      CustomPuzzleItem(
        id: 'sample_01',
        title: '巴黎埃菲尔铁塔晨曦',
        imagePathOrUrl: assetSamples[0],
        isLocalFile: false,
        difficulty: squareTiers[0].difficulty, // 16
        createdAt: DateTime.now().subtract(const Duration(days: 2)),
      ),
      CustomPuzzleItem(
        id: 'sample_02',
        title: '午后阳光与香浓拿铁',
        imagePathOrUrl: assetSamples[1],
        isLocalFile: false,
        difficulty: squareTiers[2].difficulty, // 36
        createdAt: DateTime.now().subtract(const Duration(days: 1)),
      ),
      CustomPuzzleItem(
        id: 'sample_03',
        title: '草地上奔跑的小柴犬',
        imagePathOrUrl: assetSamples[2],
        isLocalFile: false,
        difficulty: squareTiers[3].difficulty, // 64
        createdAt: DateTime.now(),
      ),
    ];
    _saveCustomPuzzles();
  }

  Future<void> _saveCustomPuzzles() async {
    final jsonList = _customPuzzles.map((e) => e.toJson()).toList();
    await _prefs?.setString(_keyCustomList, jsonEncode(jsonList));
  }

  /// Adds a new user custom puzzle.
  Future<void> addCustomPuzzle(CustomPuzzleItem item) async {
    _customPuzzles.insert(0, item);
    await _saveCustomPuzzles();
  }

  /// Deletes a custom puzzle and cleans up local image file if present.
  Future<void> deleteCustomPuzzle(String id) async {
    final idx = _customPuzzles.indexWhere((p) => p.id == id);
    if (idx != -1) {
      final item = _customPuzzles[idx];
      if (item.isLocalFile && !item.imagePathOrUrl.startsWith('assets/')) {
        try {
          final file = File(item.imagePathOrUrl);
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {}
      }
      _customPuzzles.removeAt(idx);
      await _saveCustomPuzzles();
    }
  }

  /// Updates progress or completion state of a main level.
  Future<void> updateLevelProgress({
    required int levelIndex,
    required int progressPercent,
    String? snapshotJson,
    bool isCompleted = false,
    int? completedPieceCount,
    int stars = 0,
    int timeSeconds = 0,
  }) async {
    final idx = levelIndex - 1;
    if (idx < 0 || idx >= _levels.length) return;

    var current = _levels[idx];
    final newStars = isCompleted ? (stars > current.stars ? stars : current.stars) : current.stars;
    final newBestTime = isCompleted
        ? (current.bestTimeSeconds == 0 || timeSeconds < current.bestTimeSeconds
            ? timeSeconds
            : current.bestTimeSeconds)
        : current.bestTimeSeconds;

    final updatedCompletedCounts = Set<int>.from(current.completedPieceCounts);
    if (isCompleted && completedPieceCount != null) {
      updatedCompletedCounts.add(completedPieceCount);
    }

    _levels[idx] = current.copyWith(
      progressPercent: progressPercent,
      isCompleted: isCompleted || current.isCompleted || updatedCompletedCounts.isNotEmpty,
      stars: newStars,
      bestTimeSeconds: newBestTime,
      savedSnapshotJson: isCompleted ? null : snapshotJson,
      completedPieceCounts: updatedCompletedCounts.toList(),
    );

    // Save current level
    await _prefs?.setString('$_keyLevelsPrefix$levelIndex', jsonEncode(_levels[idx].toJson()));

    // Unlock next level if completed
    if (isCompleted && levelIndex < _levels.length) {
      final nextIdx = levelIndex;
      if (!_levels[nextIdx].isUnlocked) {
        _levels[nextIdx] = _levels[nextIdx].copyWith(isUnlocked: true);
        await _prefs?.setString(
          '$_keyLevelsPrefix${nextIdx + 1}',
          jsonEncode(_levels[nextIdx].toJson()),
        );
      }
    }

    if (isCompleted) {
      await _prefs?.setInt(_keyTotalCompleted, totalCompletedLevels + 1);
    }
  }

  /// Updates daily challenge state.
  Future<void> updateDailyProgress({
    required String dateStr,
    required int progressPercent,
    String? snapshotJson,
    bool isCompleted = false,
    int? completedPieceCount,
    int timeSeconds = 0,
  }) async {
    final idx = _dailyChallenges.indexWhere((d) => d.date == dateStr);
    if (idx == -1) return;

    var current = _dailyChallenges[idx];
    final newBestTime = isCompleted
        ? (current.bestTimeSeconds == 0 || timeSeconds < current.bestTimeSeconds
            ? timeSeconds
            : current.bestTimeSeconds)
        : current.bestTimeSeconds;

    final updatedCompletedCounts = Set<int>.from(current.completedPieceCounts);
    if (isCompleted && completedPieceCount != null) {
      updatedCompletedCounts.add(completedPieceCount);
    }

    _dailyChallenges[idx] = current.copyWith(
      progressPercent: progressPercent,
      isCompleted: isCompleted || current.isCompleted || updatedCompletedCounts.isNotEmpty,
      bestTimeSeconds: newBestTime,
      savedSnapshotJson: isCompleted ? null : snapshotJson,
      completedPieceCounts: updatedCompletedCounts.toList(),
    );

    await _prefs?.setString('$_keyDailyPrefix$dateStr', jsonEncode(_dailyChallenges[idx].toJson()));

    if (isCompleted) {
      await _prefs?.setInt(_keyTotalCompleted, totalCompletedLevels + 1);
    }
  }

  /// Updates custom puzzle progress.
  Future<void> updateCustomProgress({
    required String id,
    required int progressPercent,
    String? snapshotJson,
    bool isCompleted = false,
    int? completedPieceCount,
    int timeSeconds = 0,
  }) async {
    final idx = _customPuzzles.indexWhere((p) => p.id == id);
    if (idx == -1) return;

    var current = _customPuzzles[idx];
    final newBestTime = isCompleted
        ? (current.bestTimeSeconds == 0 || timeSeconds < current.bestTimeSeconds
            ? timeSeconds
            : current.bestTimeSeconds)
        : current.bestTimeSeconds;

    final updatedCompletedCounts = Set<int>.from(current.completedPieceCounts);
    if (isCompleted && completedPieceCount != null) {
      updatedCompletedCounts.add(completedPieceCount);
    }

    _customPuzzles[idx] = current.copyWith(
      progressPercent: progressPercent,
      isCompleted: isCompleted || current.isCompleted || updatedCompletedCounts.isNotEmpty,
      bestTimeSeconds: newBestTime,
      savedSnapshotJson: isCompleted ? null : snapshotJson,
      completedPieceCounts: updatedCompletedCounts.toList(),
    );

    await _saveCustomPuzzles();

    if (isCompleted) {
      await _prefs?.setInt(_keyTotalCompleted, totalCompletedLevels + 1);
    }
  }

  /// Adds statistics for snapped piece and play duration.
  Future<void> recordSnapStats({int pieceCount = 1, int durationSeconds = 0}) async {
    if (pieceCount > 0) {
      await _prefs?.setInt(_keyTotalPiecesSnapped, totalPiecesSnapped + pieceCount);
    }
    if (durationSeconds > 0) {
      await _prefs?.setInt(_keyTotalPlayTimeSeconds, totalPlayTimeSeconds + durationSeconds);
    }
  }

  /// Resets all local progress for testing/replay.
  Future<void> resetAllData() async {
    await _prefs?.clear();
    _initLevels();
    _initDailyChallenges();
    _initCustomPuzzles();
  }
}
