import 'dart:convert';
import 'dart:typed_data';

class Frame {
  final Map<String, dynamic> header;
  final List<int> payload;

  static const int _currentVersion = 1;
  static const int _minSupportedVersion = 1;

  Frame({
    required this.header,
    required this.payload,
  });

  /// Create a frame with version header
  factory Frame.create({
    required Map<String, dynamic> header,
    required List<int> payload,
    int version = _currentVersion,
  }) {
    header['version'] = version;
    return Frame(header: header, payload: payload);
  }

  List<int> encode() {
    final headerBytes = utf8.encode(
      jsonEncode(header),
    );

    final headerLength = headerBytes.length;

    final bodyLength =
        4 + headerLength + payload.length;

    final result =
        BytesBuilder(copy: false);

    final bodyLengthBytes =
        ByteData(4);

    bodyLengthBytes.setUint32(
      0,
      bodyLength,
      Endian.big,
    );

    result.add(
      bodyLengthBytes.buffer.asUint8List(),
    );

    final headerLengthBytes =
        ByteData(4);

    headerLengthBytes.setUint32(
      0,
      headerLength,
      Endian.big,
    );

    result.add(
      headerLengthBytes.buffer.asUint8List(),
    );

    result.add(headerBytes);
    result.add(payload);

    return result.takeBytes();
  }

  static Frame decode(List<int> data) {
    if (data.length < 4) throw StateError('Frame too short');
    
    final bodyLength = ByteData.sublistView(
      Uint8List.fromList(data.sublist(0, 4)),
    ).getUint32(0, Endian.big);
    
    if (bodyLength > 64 * 1024 * 1024) {
      throw StateError('Frame exceeds maximum allowed size');
    }
    
    if (data.length < 4 + bodyLength) throw StateError('Incomplete frame');
    
    final body = data.sublist(4, 4 + bodyLength);
    
    if (body.length < 4) {
      throw StateError('Invalid frame');
    }
    
    final headerLength = ByteData.sublistView(
      Uint8List.fromList(body.sublist(0, 4)),
    ).getUint32(0, Endian.big);
    
    if (headerLength <= 0 || headerLength > body.length - 4) {
      throw StateError('Invalid header length');
    }
    
    final headerBytes = body.sublist(4, 4 + headerLength);
    final payload = body.sublist(4 + headerLength);
    
    final decoded = jsonDecode(utf8.decode(headerBytes));
    
    if (decoded is! Map) {
      throw StateError('Invalid frame header');
    }
    
    return Frame(
      header: Map<String, dynamic>.from(decoded),
      payload: payload,
    );
  }
}