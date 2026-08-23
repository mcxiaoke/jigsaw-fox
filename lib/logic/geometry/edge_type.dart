/// Represents the topology type of a puzzle piece's edge.
enum EdgeType {
  /// Flat edge (outer border of the puzzle).
  flat,

  /// Convex tab pointing outward from the piece body.
  tab,

  /// Concave blank (hole) pointing inward into the piece body.
  blank;

  /// Returns true if this edge is flat (puzzle border).
  bool get isFlat => this == EdgeType.flat;

  /// Returns true if this edge is a convex tab.
  bool get isTab => this == EdgeType.tab;

  /// Returns true if this edge is a concave blank.
  bool get isBlank => this == EdgeType.blank;

  /// Returns the complementary edge type required by an adjacent neighbor.
  EdgeType get opposite {
    switch (this) {
      case EdgeType.flat:
        return EdgeType.flat;
      case EdgeType.tab:
        return EdgeType.blank;
      case EdgeType.blank:
        return EdgeType.tab;
    }
  }
}
