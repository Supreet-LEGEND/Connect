import 'dart:async';
import 'dart:io';

import 'package:connect/network/crypto/crypto_service.dart';
import 'package:connect/network/crypto/device_identity.dart';
import 'package:connect/network/crypto/handshake_handler.dart';
import 'package:connect/network/crypto/trust_store.dart';
import 'package:connect/network/protocol/frame.dart';
import 'package:connect/network/protocol/frame_parser.dart';
import 'package:cryptography/cryptography.dart';

enum SecureChannelPhase {
  handshake,
  frames,
  closed,
}

/// Callback for heartbeat events
typedef HeartbeatCallback = void Function();

class SecureChannel {
  final Socket _socket;
  final DeviceIdentity _identity;
  final bool _isInitiator;
  final FrameParser _parser = FrameParser();
  final StreamController<ParsedFrame> _frameController = StreamController<ParsedFrame>.broadcast();
  final StreamController<HandshakeResult> _handshakeController = StreamController<HandshakeResult>.broadcast();

  CryptoService? _crypto;
  SimplePublicKey? _peerIdentityPublicKey;
  SimplePublicKey? _peerEphemeralPublicKey;
  List<int>? _transcriptHash;

  SecureChannelPhase _phase = SecureChannelPhase.handshake;
  bool _closed = false;
  StreamSubscription? _socketSubscription;

  /// Optional callback when heartbeat pong is received
  HeartbeatCallback? onHeartbeatPong;

  final TrustStore trustStore;
  final TrustPolicy trustPolicy;

  static const Duration _handshakeTimeout = Duration(seconds: 30);

  SecureChannel({
    required Socket socket,
    required DeviceIdentity identity,
    required bool isInitiator,
    required this.trustStore,
    this.trustPolicy = TrustPolicy.tofu,
    this.onHeartbeatPong,
  })  : _socket = socket,
        _identity = identity,
        _isInitiator = isInitiator;

  Stream<ParsedFrame> get frames => _frameController.stream;
  Stream<HandshakeResult> get handshakeResult => _handshakeController.stream;
  CryptoService? get crypto => _crypto;
  SimplePublicKey? get peerIdentityPublicKey => _peerIdentityPublicKey;
  SimplePublicKey? get peerEphemeralPublicKey => _peerEphemeralPublicKey;
  List<int>? get transcriptHash => _transcriptHash;
  bool get isHandshakeComplete => _phase == SecureChannelPhase.frames;
  bool get isClosed => _closed;

  Future<HandshakeResult> performHandshake() async {
    final handler = HandshakeHandler(
      myIdentity: _identity,
      trustStore: trustStore,
      trustPolicy: trustPolicy,
    );
    HandshakeResult result;

    // Add overall handshake timeout
    final handshakeFuture = _isInitiator
        ? handler.performHandshakeAsInitiator(_socket)
        : handler.performHandshakeAsResponder(_socket);

    try {
      result = await handshakeFuture.timeout(_handshakeTimeout, onTimeout: () {
        throw TimeoutException('Handshake timed out after ${_handshakeTimeout.inSeconds}s');
      });
    } on TimeoutException {
      _handleDisconnect();
      rethrow;
    }

    _crypto = CryptoService(key: result.sessionKey);
    _peerIdentityPublicKey = result.peerIdentityPublicKey;
    _peerEphemeralPublicKey = result.peerEphemeralPublicKey;
    _transcriptHash = result.transcriptHash;

    _phase = SecureChannelPhase.frames;
    _handshakeController.add(result);

    return result;
  }

  void startFrameProcessing() {
    if (_phase != SecureChannelPhase.frames) {
      throw StateError('Handshake not complete');
    }

    _socketSubscription = _socket.listen(
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
      _handleParsedFrame,
      onError: (e) {
        // Frame parsing error - close connection
        close();
      },
    );
  }

  Future<void> _handleParsedFrame(ParsedFrame frame) async {
    if (_crypto == null) return;

    final type = frame.header['type'] as String?;

    // Handle unencrypted control frames
    if (type == 'heartbeat_ping') {
      await sendFrame(
        type: 'heartbeat_pong',
        header: {
          'version': 1,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        },
        payload: const [],
      );
      return;
    }

    if (type == 'heartbeat_pong') {
      // Notify health monitor
      onHeartbeatPong?.call();
      return;
    }

    // Decrypt encrypted frames
    final nonce = List<int>.from(frame.header['nonce'] as List);
    final mac = List<int>.from(frame.header['mac'] as List);

    try {
      final plaintext = await _crypto!.decrypt(
        cipherText: frame.payload,
        nonce: nonce,
        mac: mac,
      );

      _frameController.add(ParsedFrame(
        header: frame.header,
        payload: plaintext,
      ));
    } catch (e) {
      // Decryption failed - close connection immediately
      close();
    }
  }

  Future<void> sendFrame({
    required String type,
    required Map<String, dynamic> header,
    required List<int> payload,
  }) async {
    if (_crypto == null) {
      throw StateError('Handshake not complete');
    }

    final encrypted = await _crypto!.encrypt(payload);

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

    _socket.add(frame.encode());
    await _socket.flush();
  }

  Future<void> sendControl({
    required String type,
    required Map<String, dynamic> metadata,
  }) async {
    await sendFrame(
      type: type,
      header: {
        'version': 1,
        ...metadata,
      },
      payload: const [],
    );
  }

  Future<void> sendHeartbeat() async {
    await sendControl(
      type: 'heartbeat_ping',
      metadata: {
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  void _handleDisconnect() {
    if (_closed) return;
    _closed = true;
    _phase = SecureChannelPhase.closed;
    _socketSubscription?.cancel();
    _frameController.close();
    _handshakeController.close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _phase = SecureChannelPhase.closed;

    await _socketSubscription?.cancel();
    await _socket.flush();
    await _socket.close();
    await _parser.dispose();
    await _frameController.close();
    await _handshakeController.close();
  }
}