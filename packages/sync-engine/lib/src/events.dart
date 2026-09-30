import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api.dart';
import 'validation.dart';

/// Bounded parser for API terminal event streams.
class EventStream {
  EventStream._(this._api, this._iterator);

  final Api _api;
  final StreamIterator<List<int>> _iterator;
  final List<int> _buffer = [];
  final StringBuffer _data = StringBuffer();
  bool _closed = false;

  static Future<EventStream> fromResponse(
    Api api,
    http.StreamedResponse response,
  ) async {
    if (response.statusCode != 200) throw await api.responseError(response);
    if (!(response.headers['content-type']?.startsWith('text/event-stream') ??
        false)) {
      throw const FormatException('expected an event stream');
    }
    return EventStream._(api, StreamIterator(response.stream));
  }

  Future<Map<String, dynamic>> next() async {
    if (_closed) throw StateError('event stream is closed');
    while (true) {
      final end = _buffer.indexOf(0x0a);
      if (end >= 0) {
        final line = _buffer.sublist(0, end);
        _buffer.removeRange(0, end + 1);
        if (line.isNotEmpty && line.last == 0x0d) line.removeLast();
        final text = utf8.decode(line);
        if (text.isEmpty && _data.isNotEmpty) {
          final data = _data.toString();
          _data.clear();
          return jsonObject(jsonDecode(data), 'event');
        }
        if (text.startsWith('data:')) {
          if (_data.isNotEmpty) _data.write('\n');
          final payload = text.substring(5);
          _data.write(payload.startsWith(' ') ? payload.substring(1) : payload);
        }
        if (_data.length > 1 << 20) {
          throw const FormatException('event exceeds size limit');
        }
        continue;
      }
      final hasNext = await _api.cancel.race(_iterator.moveNext());
      if (!hasNext) {
        throw const FormatException(
          'event stream ended before a terminal event',
        );
      }
      final chunk = _iterator.current;
      if (chunk.length > (1 << 20) - _buffer.length) {
        throw const FormatException('event line exceeds size limit');
      }
      _buffer.addAll(chunk);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _iterator.cancel();
  }
}

class Progress {
  int? _last;

  /// Returns whether the visible progress advanced.
  bool update(int percent) {
    if (percent < 0 || percent > 100) {
      throw FormatException('malformed progress percent $percent');
    }
    if (_last != null && percent <= _last!) return false;
    _last = percent;
    stderr.writeln('Import progress: $percent%');
    return true;
  }
}
