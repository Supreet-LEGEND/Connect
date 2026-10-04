import 'dart:async';
import 'dart:io';

import 'secure_channel.dart';
import 'connection_health.dart';
import '../crypto/device_identity.dart';
import '../crypto/trust_store.dart';
import '../protocol/frame_parser.dart';
import 'package:cryptography/cryptography.dart';

class Connection implements HeartbeatCapable {
  String id;
  String deviceId;

  final String host;
  final int port;

  final DeviceIdentity identity;
  final TrustStore trustStore;
  final TrustPolicy trustPolicy;

  SecureChannel? _channel;

  bool _busy = false;
  bool _closed = false;

  Connection({
    required this.id,
    required this.deviceId,
    required this.host,
    required this.port,
    required this.identity,
    required this.trustStore,
    this.trustPolicy = TrustPolicy.tofu,
  });

  bool get isBusy => _busy;

  @override
  bool get isConnected => _channel != null && !_closed && _channel!.isHandshakeComplete;

  @override
  bool get isHandshakeComplete => _channel?.isHandshakeComplete ?? false;

  SimplePublicKey? get peerIdentityPublicKey => _channel?.peerIdentityPublicKey;

  SimplePublicKey? get peerEphemeralPublicKey => _channel?.peerEphemeralPublicKey;

  List<int>? get transcriptHash => _channel?.transcriptHash;

  SecureChannel? get channel => _channel;

  Stream<ParsedFrame> get frames {
    if (_channel == null) {
      return const Stream<ParsedFrame>.empty();
    }
    return _channel!.frames;
  }

  Future<void> connect() async {
    if (isConnected) {
      return;
    }

    if (_channel != null) {
      await _channel!.close();
    }

    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 5),
    );

    _closed = false;

    _channel = SecureChannel(
      socket: socket,
      identity: identity,
      isInitiator: true,
      trustStore: trustStore,
      trustPolicy: trustPolicy,
      onHeartbeatPong: () {
        // Callback set by DeviceSession after connection
      },
    );

    await _channel!.performHandshake();
    _channel!.startFrameProcessing();
  }

  Future<void> performHandshake({required bool isInitiator}) async {
    if (isHandshakeComplete) {
      return;
    }

    if (_channel == null) {
      throw StateError('Connection not established');
    }

    await _channel!.performHandshake();
    if (isInitiator) {
      _channel!.startFrameProcessing();
    }
  }

  Future<void> send({
    required String type,
    required Map<String, dynamic> metadata,
    required List<int> plaintext,
  }) async {
    if (!isConnected) {
      throw StateError('Connection is not connected');
    }

    _busy = true;

    try {
      await _channel!.sendFrame(
        type: type,
        header: {
          'version': 1,
          ...metadata,
        },
        payload: plaintext,
      );
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

  @override
  Future<void> sendHeartbeat() async {
    await sendControl(
      type: 'heartbeat_ping',
      metadata: {
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  Future<void> close() async {
    _closed = true;
    await _channel?.close();
    _channel = null;
  }

  void updateDeviceId(String newDeviceId) {
    deviceId = newDeviceId;
    id = newDeviceId;
  }
}