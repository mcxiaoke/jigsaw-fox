import '../models/puzzle_state.dart';

/// Lightweight pure snapshot stack for Undo / Redo operations.
class UndoManager {
  UndoManager({this.maxHistory = 30});

  final int maxHistory;
  final List<PuzzleBoardState> _undoStack = [];
  final List<PuzzleBoardState> _redoStack = [];

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  int get undoCount => _undoStack.length;
  int get redoCount => _redoStack.length;

  /// Records a snapshot state onto the undo stack and clears redo history.
  void record(PuzzleBoardState state) {
    _undoStack.add(state);
    if (_undoStack.length > maxHistory) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  /// Restores previous state, pushing [currentState] onto the redo stack.
  PuzzleBoardState? undo(PuzzleBoardState currentState) {
    if (_undoStack.isEmpty) return null;
    _redoStack.add(currentState);
    return _undoStack.removeLast();
  }

  /// Restores next state from redo stack, pushing [currentState] onto undo stack.
  PuzzleBoardState? redo(PuzzleBoardState currentState) {
    if (_redoStack.isEmpty) return null;
    _undoStack.add(currentState);
    return _redoStack.removeLast();
  }

  /// Resets all history.
  void clear() {
    _undoStack.clear();
    _redoStack.clear();
  }
}
