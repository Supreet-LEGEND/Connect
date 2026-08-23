import 'dart:async';
import 'dart:io';

import '../crypto/crypto_service.dart';
import '../protocol/frame.dart';
import '../protocol/frame_parser.dart';

class Connection {
  final String id;
  final String deviceId;

  final String host;
  final int port;

  final CryptoService crypto;

  Socket? _socket;

  final FrameParser _parser =
      FrameParser();

  StreamSubscription? _subscription;

  final StreamController<ParsedFrame>
      _frames =
      StreamController<ParsedFrame>.broadcast();

  bool _busy = false;
  bool _closed = false;

  Connection({
    required this.id,
    required this.deviceId,
    required this.host,
    required this.port,
    required this.crypto,
  });

  bool get isBusy => _busy;

  bool get isConnected =>
      _socket != null &&
      !_closed;

  Stream<ParsedFrame> get frames =>
      _frames.stream;

  Future<void> connect() async {
    if (isConnected) {
      return;
    }

    _socket = await Socket.connect(
      host,
      port,
      timeout:
          const Duration(seconds: 5),
    );

    _closed = false;

    _subscription =
        _socket!.listen(
      (bytes) {
        _parser.add(bytes);
      },
      onError: (_) {
        _handleDisconnect();
      },
      onDone: () {
        _handleDisconnect();
      },
      cancelOnError: false,
    );

    _parser.frames.listen(
      _frames.add,
    );
  }

  Future<void> send({
    required String type,
    required Map<String, dynamic> metadata,
    required List<int> plaintext,
  }) async {
    if (!isConnected) {
      throw StateError(
        'Connection is not connected',
      );
    }

    _busy = true;

    try {
      final encrypted =
          await crypto.encrypt(
        plaintext,
      );

      final header = {
        'version': 1,
        'type': type,
        'nonce': encrypted.nonce,
        'mac': encrypted.mac,
        'payloadLength':
            encrypted.cipherText.length,
        ...metadata,
      };

      final frame = Frame(
        header: header,
        payload:
            encrypted.cipherText,
      );

      _socket!.add(frame.encode());

      await _socket!.flush();
    } finally {
      _busy = false;
    }
  }

  Future<void> sendControl({
    required String type,
    required Map<String, dynamic> metadata,
  }) async {
    await send(
      type: type,
      metadata: metadata,
      plaintext: const [],
    );
  }

  void _handleDisconnect() {
    _socket = null;
    _busy = false;
  }

  Future<void> close() async {
    _closed = true;

    await _subscription?.cancel();

    await _socket?.flush();

    await _socket?.close();

    await _parser.dispose();

    await _frames.close();
  }
}