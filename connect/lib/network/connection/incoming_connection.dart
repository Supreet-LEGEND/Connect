import 'dart:async';
import 'dart:io';

import '../crypto/crypto_service.dart';
import '../protocol/frame.dart';
import '../protocol/frame_parser.dart';

/// Manages an incoming connection from a remote device
///
/// This class handles:
/// - Receiving raw bytes from the socket
/// - Parsing them into frames
/// - Decrypting encrypted frames
/// - Emitting decrypted frames for higher-level handlers
///
/// This is a generic connection handler with no coupling to transfer logic.
/// Higher-level managers (like ReceiveTransferManager) subscribe to the
/// frames stream and handle the actual business logic.
class IncomingConnection {
  final Socket socket;
  final CryptoService crypto;

  final FrameParser _parser = FrameParser();

  /// Stream of decrypted frames: {type, header, payload, connection}
  final StreamController<Map<String, dynamic>> _decryptedFrames =
      StreamController<Map<String, dynamic>>.broadcast();

  StreamSubscription? _subscription;

  IncomingConnection({
    required this.socket,
    required this.crypto,
  });

  /// Stream of decrypted frames ready for processing
  Stream<Map<String, dynamic>> get frames => _decryptedFrames.stream;

  /// Start listening to the socket and emitting frames
  Future<void> start() async {
    _subscription = socket.listen(
      (bytes) {
        _parser.add(bytes);
      },
      onError: (_) {
        close();
      },
      onDone: () {
        close();
      },
    );

    _parser.frames.listen(
      _handleFrame,
    );
  }

  /// Handle a parsed frame by decrypting and emitting
  Future<void> _handleFrame(ParsedFrame frame) async {
    final type = frame.header['type'];

    final nonce = List<int>.from(
      frame.header['nonce'],
    );

    final mac = List<int>.from(
      frame.header['mac'],
    );

    final plaintext = await crypto.decrypt(
      cipherText: frame.payload,
      nonce: nonce,
      mac: mac,
    );

    // Emit decrypted frame with metadata
    _decryptedFrames.add({
      'type': type,
      'header': frame.header,
      'payload': plaintext,
      'connection': this,
    });
  }

  /// Send a frame response (e.g., acknowledgment)
  Future<void> sendFrame({
    required String type,
    required Map<String, dynamic> header,
    required List<int> payload,
  }) async {
    final encrypted = await crypto.encrypt(payload);

    final frame = Frame(
      header: {
        ...header,
        'type': type,
        'nonce': encrypted.nonce,
        'mac': encrypted.mac,
        'payloadLength': encrypted.cipherText.length,
      },
      payload: encrypted.cipherText,
    );

    socket.add(frame.encode());
    await socket.flush();
  }

  /// Convenience method for sending chunk acknowledgments
  Future<void> sendAck({
    required String transferId,
    required int chunkIndex,
  }) async {
    await sendFrame(
      type: 'chunk_ack',
      header: {
        'version': 1,
        'transferId': transferId,
        'chunkIndex': chunkIndex,
      },
      payload: const [],
    );
  }

  /// Close the connection and clean up resources
  Future<void> close() async {
    await _subscription?.cancel();
    await socket.close();
    await _decryptedFrames.close();
    await _parser.dispose();
  }
}
