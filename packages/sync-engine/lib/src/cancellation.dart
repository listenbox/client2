import 'dart:async';

/// Cooperative cancellation for a tree of application-owned async operations.
class CancellationToken {
  CancellationToken._(this._parent) {
    if (_parent != null) {
      _parent._children.add(this);
      if (_parent.isCancelled) cancel();
    }
  }

  factory CancellationToken() => CancellationToken._(null);

  final CancellationToken? _parent;
  final Set<CancellationToken> _children = {};
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  CancellationToken child() => CancellationToken._(this);

  void cancel() {
    if (isCancelled) return;
    _cancelled.complete();
    for (final child in _children.toList()) {
      child.cancel();
    }
    _children.clear();
    _parent?._children.remove(this);
  }

  void throwIfCancelled() {
    if (isCancelled) throw const OperationCancelled();
  }

  Future<T> race<T>(Future<T> work) async {
    throwIfCancelled();
    return Future.any<T>([
      work,
      whenCancelled.then<T>((_) => throw const OperationCancelled()),
    ]);
  }
}

class OperationCancelled implements Exception {
  const OperationCancelled();
  @override
  String toString() =>
      'operation interrupted; resumable source upload state preserved';
}
