/// Dual-axis multi-tiered star rating calculator (v3.3.1 design).
///
/// Combines TimeScore (speed relative to non-linear BaseSeconds) and
/// HintScore (hint usage vs scalable allowance) taking the minimum,
/// with guaranteed 1-star baseline upon puzzle completion.
class StarCalculator {
  const StarCalculator._();

  /// Calculates the zero-penalty hint allowance scaled by puzzle piece count.
  ///
  /// L1(25)=2 -> L2(64)=2 -> L3(100)=2 -> L4(144)=3 -> L5(225)=5 -> L6(400)=6 (clamped).
  static int hintAllowance(int pieces) {
    if (pieces <= 0) return 2;
    return (pieces / 50.0).ceil().clamp(2, 6);
  }

  /// Calculates final star rating (1 ~ 3) using integer millisecond comparisons
  /// to eliminate double rounding jitter.
  ///
  /// - TimeScore: <= 70% Base -> 3, <= 100% Base -> 2, > 100% Base -> 1
  /// - HintScore: 0 hints -> 3, <= allowance -> 2, > allowance -> 1
  /// - FinalStars = min(TimeScore, HintScore), guaranteed >= 1 on completion.
  static int calcStars({
    required int actualPieces,
    required double secPerPiece,
    required int hints,
    required int seconds,
  }) {
    if (actualPieces <= 0) return 1;
    final safeSeconds = seconds < 0 ? 0 : seconds;
    final safeHints = hints < 0 ? 0 : hints;

    // Integer millisecond calculation
    final baseMs = (actualPieces * secPerPiece * 1000).round();
    final ms = safeSeconds * 1000;

    final timeScore = ms <= (baseMs * 7 ~/ 10) ? 3 : (ms <= baseMs ? 2 : 1);
    final allowance = hintAllowance(actualPieces);
    final hintScore = safeHints == 0 ? 3 : (safeHints <= allowance ? 2 : 1);

    final finalStars = timeScore < hintScore ? timeScore : hintScore;
    return finalStars < 1 ? 1 : finalStars;
  }
}
