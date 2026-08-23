import 'dart:async';
import 'dart:io';

import 'package:connect/network/crypto/crypto_service.dart';
import 'package:connect/network/protocol/frame.dart';
import 'package:connect/network/protocol/frame_parser.dart';
import 'package:connect/network/transfer/receive_transfer_manager.dart';

class ReceivingTransfer {
  final String id;
  final String fileName;
  final int fileSize;

  final RandomAccessFile file;

  final Set<int> receivedChunks =
      {};

  ReceivingTransfer({
    required this.id,
    required this.fileName,
    required this.fileSize,
    required this.file,
  });
}

class TcpServer {
  final int port;

  ServerSocket? _server;

  final Future<void> Function(
    Socket socket,
  ) onConnection;

  TcpServer({
    required this.port,
    required this.onConnection,
  });

  Future<void> start() async {
    _server =
        await ServerSocket.bind(
      InternetAddress.anyIPv4,
      port,
      shared: false,
    );

    _server!.listen(
      onConnection,
      onError: (error) {
        // log error
      },
    );
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }
}

class IncomingConnection {
  final Socket socket;
  final CryptoService crypto;
  final ReceiveTransferManager transfers;

  final FrameParser parser =
      FrameParser();

  StreamSubscription? subscription;

  IncomingConnection({
    required this.socket,
    required this.crypto,
    required this.transfers,
  });

  Future<void> start() async {
    subscription =
        socket.listen(
      (bytes) {
        parser.add(bytes);
      },
      onError: (_) {
        close();
      },
      onDone: () {
        close();
      },
    );

    parser.frames.listen(
      _handleFrame,
    );
  }

  Future<void> _handleFrame(
    ParsedFrame frame,
  ) async {
    final type =
        frame.header['type'];

    final nonce =
        List<int>.from(
      frame.header['nonce'],
    );

    final mac =
        List<int>.from(
      frame.header['mac'],
    );

    final plaintext =
        await crypto.decrypt(
      cipherText: frame.payload,
      nonce: nonce,
      mac: mac,
    );

    await transfers.handle(
      type: type,
      header: frame.header,
      payload: plaintext,
      connection: this,
    );
  }

  Future<void> sendAck({
    required String transferId,
    required int chunkIndex,
  }) async {
    final encrypted =
        await crypto.encrypt(
      const [],
    );

    final frame = Frame(
      header: {
        'version': 1,
        'type': 'chunk_ack',
        'transferId': transferId,
        'chunkIndex': chunkIndex,
        'nonce': encrypted.nonce,
        'mac': encrypted.mac,
        'payloadLength':
            encrypted.cipherText.length,
      },
      payload:
          encrypted.cipherText,
    );

    socket.add(
      frame.encode(),
    );

    await socket.flush();
  }

  Future<void> close() async {
    await subscription?.cancel();
    await socket.close();
    await parser.dispose();
  }
}