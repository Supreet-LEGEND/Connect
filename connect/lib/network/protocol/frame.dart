import 'dart:convert';
import 'dart:typed_data';

class Frame {
  final Map<String, dynamic> header;
  final List<int> payload;

  Frame({
    required this.header,
    required this.payload,
  });

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
}