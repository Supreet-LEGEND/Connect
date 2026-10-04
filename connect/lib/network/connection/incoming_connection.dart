import 'dart:async';
import 'dart:io';

import 'secure_channel.dart';
import 'connection_health.dart';
import '../crypto/crypto_service.dart';
import '../crypto/device_identity.dart';
import '../crypto/trust_store.dart';
import 'package:cryptography/cryptography.dart';

/// Manages an incoming connection from a remote device
///
/// This class handles:
/// - Receiving raw bytes from the socket
/// - Parsing them into frames
/// - Performing handshake as responder
/// - Decrypting encrypted frames
/// - Emitting decrypted frames for higher-level handlers
///
/// This is a generic connection handler with no coupling to transfer logic.
/// Higher-level managers (like ReceiveTransferManager) subscribe to the
/// frames stream and handle the actual business logic.
class IncomingConnection implements HeartbeatCapable {
  final Socket socket;
  final DeviceIdentity identity;
  final TrustStore trustStore;
  final TrustPolicy trustPolicy;

  SecureChannel? _channel;

  /// Stream of decrypted frames: {type, header, payload, connection}
  final StreamController<Map<String, dynamic>> _decryptedFrames =
      StreamController<Map<String, dynamic>>.broadcast();

  bool _closed = false;

  IncomingConnection({
    required this.socket,
    required this.identity,
    required this.trustStore,
    this.trustPolicy = TrustPolicy.tofu,
  });

  CryptoService? get crypto => _channel?.crypto;

  SimplePublicKey? get peerIdentityPublicKey => _channel?.peerIdentityPublicKey;

  SimplePublicKey? get peerEphemeralPublicKey => _channel?.peerEphemeralPublicKey;

  List<int>? get transcriptHash => _channel?.transcriptHash;

  SecureChannel? get channel => _channel;

  /// Stream of decrypted frames ready for processing
  Stream<Map<String, dynamic>> get frames => _decryptedFrames.stream;

  /// Perform handshake as responder (incoming connection) and start frame processing
  Future<void> performHandshake() async {
    if (isHandshakeComplete) {
      return;
    }

    _channel = SecureChannel(
      socket: socket,
      identity: identity,
      isInitiator: false,
      trustStore: trustStore,
      trustPolicy: trustPolicy,
    );

    await _channel!.performHandshake();
    _channel!.startFrameProcessing();

    // Forward decrypted frames with metadata
    _channel!.frames.listen(
      (frame) {
        final type = frame.header['type'] as String?;
        if (type == 'heartbeat_ping' || type == 'heartbeat_pong') {
          return; // Already handled by SecureChannel
        }
        _decryptedFrames.add({
          'type': type,
          'header': frame.header,
          'payload': frame.payload,
          'connection': this,
        });
      },
      onError: (_) {
        // SecureChannel handles errors by closing
      },
    );
  }

  /// Send a frame response (e.g., acknowledgment)
  Future<void> sendFrame({
    required String type,
    required Map<String, dynamic> header,
    required List<int> payload,
  }) async {
    if (!isHandshakeComplete || _channel == null) {
      throw StateError('Handshake not complete');
    }

    await _channel!.sendFrame(
      type: type,
      header: header,
      payload: payload,
    );
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

  /// Send heartbeat pong
  Future<void> sendHeartbeatPong() async {
    await sendFrame(
      type: 'heartbeat_pong',
      header: {
        'version': 1,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      },
      payload: const [],
    );
  }

  /// Send a control frame (empty payload)
  Future<void> sendControl({
    required String type,
    required Map<String, dynamic> metadata,
  }) async {
    await sendFrame(
      type: type,
      header: metadata,
      payload: const [],
    );
  }

  // HeartbeatCapable implementation
  @override
  bool get isConnected => _channel != null && !_closed && _channel!.isHandshakeComplete;

  @override
  bool get isHandshakeComplete => _channel?.isHandshakeComplete ?? false;

  @override
  Future<void> sendHeartbeat() async {
    await sendControl(
      type: 'heartbeat_ping',
      metadata: {
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  /// Close the connection and clean up resources
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _channel?.close();
    _channel = null;
    await _decryptedFrames.close();
  }
}