import 'dart:async';

import 'cancellation.dart';

const rangeBytes = 1024 * 1024;
const rangesPerTransfer = 4;
const initialTransfers = 2;
const maxTransfers = 16;

enum Phase {
  queued,
  resolving,
  downloading,
  preparing,
  uploading,
  complete,
  skipped,
  failed,
}

enum RangePhase { waiting, active, complete }

class ByteRange {
  ByteRange(this.start, this.end);
  final int start;
  final int end;
  int received = 0;
  RangePhase phase = RangePhase.waiting;
}

class Download {
  Download({
    required this.id,
    required this.sourceId,
    required this.sourceTitle,
    required this.title,
  });
  final String id;
  final String sourceId;
  final String sourceTitle;
  String title;
  int? durationSeconds;
  String? reason;
  String? error;
  Phase phase = Phase.queued;
  int total = 0;
  List<ByteRange> ranges = [];
  int get received => ranges.fold(0, (sum, range) => sum + range.received);
}

class DownloadSnapshot {
  DownloadSnapshot(List<Download> items, this.slotLimit)
    : items = List.unmodifiable(items);
  final List<Download> items;
  final int slotLimit;
}

/// One isolate owns the queue and every projection update. Slots cover the
/// complete resolve, download, preparation, and upload lifecycle.
class DownloadManager {
  final List<Download> _items = [];
  final StreamController<DownloadSnapshot> _changes =
      StreamController.broadcast(sync: true);
  final List<Completer<void>> _waiters = [];
  int _active = 0;
  int slotLimit = initialTransfers;

  Stream<DownloadSnapshot> get changes => _changes.stream;
  DownloadSnapshot snapshot() => DownloadSnapshot(_items, slotLimit);
  void _notify() => _changes.add(snapshot());

  void clear() {
    if (_active != 0) throw StateError('Downloads are still active');
    _items.clear();
    _notify();
  }

  void removeSource(String sourceId) {
    _items.removeWhere((item) => item.sourceId == sourceId);
    _notify();
  }

  List<Transfer> enqueue(
    String sourceId,
    String sourceTitle,
    List<({String id, String title})> episodes,
  ) {
    removeSource(sourceId);
    final result = <Transfer>[];
    for (final episode in episodes) {
      final item = Download(
        id: '$sourceId/${episode.id}',
        sourceId: sourceId,
        sourceTitle: sourceTitle,
        title: episode.title,
      );
      _items.add(item);
      result.add(Transfer._(this, item));
    }
    _notify();
    return result;
  }

  Future<void> drain() async {
    while (_active > 0) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
  }

  Future<ActiveTransfer> acquire(
    Transfer transfer,
    CancellationToken cancel,
  ) async {
    while (_active >= slotLimit) {
      cancel.throwIfCancelled();
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await cancel.race(waiter.future);
    }
    cancel.throwIfCancelled();
    _active++;
    transfer.phase(Phase.resolving);
    return ActiveTransfer._(this, transfer);
  }

  void _release() {
    _active--;
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _waiters.clear();
  }
}

class Transfer {
  Transfer._(this._manager, this.item);
  final DownloadManager _manager;
  final Download item;
  Future<ActiveTransfer> acquire(CancellationToken cancel) =>
      _manager.acquire(this, cancel);
  void phase(Phase value) {
    item.phase = value;
    _manager._notify();
  }

  void title(String value) {
    item.title = value;
    _manager._notify();
  }

  void duration(int? value) {
    if (value != null) item.durationSeconds = value;
    _manager._notify();
  }

  void skipped(String reason) {
    item.phase = Phase.skipped;
    item.reason = reason;
    _manager._notify();
  }

  void error(Object error) {
    item.phase = Phase.failed;
    item.error = error.toString();
    _manager._notify();
  }

  void startDownload(int total) {
    item.phase = Phase.downloading;
    item.total = total;
    item.ranges = [
      for (var start = 0; start < total; start += rangeBytes)
        ByteRange(start, (start + rangeBytes).clamp(0, total) - 1),
    ];
    _manager._notify();
  }

  void range(int start, int received, RangePhase phase) {
    final entry = item.ranges
        .where((range) => range.start == start)
        .firstOrNull;
    if (entry == null) throw StateError('Unknown download range');
    entry.received = received;
    entry.phase = phase;
    _manager._notify();
  }
}

class ActiveTransfer {
  ActiveTransfer._(this._manager, this.transfer);
  final DownloadManager _manager;
  final Transfer transfer;
  bool _finished = false;
  void finish([Object? error]) {
    if (_finished) return;
    _finished = true;
    if (error != null) {
      transfer.error(error);
    } else if (transfer.item.phase != Phase.skipped) {
      transfer.phase(Phase.complete);
    }
    _manager._release();
  }
}
