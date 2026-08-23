import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

class ParsedFrame {
  final Map<String, dynamic> header;
  final List<int> payload;

  ParsedFrame({
    required this.header,
    required this.payload,
  });
}

class FrameParser {
  final List<int> _buffer = [];

  final StreamController<ParsedFrame>
      _controller =
      StreamController<ParsedFrame>.broadcast();

  Stream<ParsedFrame> get frames =>
      _controller.stream;

  void add(List<int> bytes) {
    _buffer.addAll(bytes);

    while (true) {
      final frame = _tryParse();

      if (frame == null) {
        break;
      }

      _controller.add(frame);
    }
  }

  ParsedFrame? _tryParse() {
    if (_buffer.length < 4) {
      return null;
    }

    final bodyLength = ByteData.sublistView(
      Uint8List.fromList(
        _buffer.sublist(0, 4),
      ),
    ).getUint32(0, Endian.big);

    if (bodyLength <= 4) {
      throw StateError(
        'Invalid frame length',
      );
    }

    if (bodyLength > 64 * 1024 * 1024) {
      throw StateError(
        'Frame exceeds maximum allowed size',
      );
    }

    final totalLength =
        4 + bodyLength;

    if (_buffer.length < totalLength) {
      return null;
    }

    final body =
        _buffer.sublist(4, totalLength);

    _buffer.removeRange(
      0,
      totalLength,
    );

    final headerLength =
        ByteData.sublistView(
      Uint8List.fromList(
        body.sublist(0, 4),
      ),
    ).getUint32(0, Endian.big);

    if (headerLength <= 0 ||
        headerLength >
            body.length - 4) {
      throw StateError(
        'Invalid header length',
      );
    }

    final headerBytes = body.sublist(
      4,
      4 + headerLength,
    );

    final payload = body.sublist(
      4 + headerLength,
    );

    final decoded =
        jsonDecode(utf8.decode(headerBytes));

    if (decoded is! Map) {
      throw StateError(
        'Invalid frame header',
      );
    }

    return ParsedFrame(
      header: Map<String, dynamic>.from(
        decoded,
      ),
      payload: payload,
    );
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}