import 'dart:async';
import '../crypto/device_identity.dart';
import 'connection_pool.dart';
import 'connection.dart';
import 'connection_health.dart';
import 'reconnection_manager.dart';
import '../crypto/trust_store.dart';
import 'package:cryptography/cryptography.dart';

class DeviceSession {
  final String name;
  final String ip;
  final int port;

  final ConnectionPool pool;
  final ConnectionHealth health;
  final ReconnectionManager reconnectionManager;
  final TrustStore trustStore;
  final TrustPolicy trustPolicy;

  String _deviceId;
  final StreamController<SimplePublicKey> _peerFingerprintController =
      StreamController<SimplePublicKey>.broadcast();

  bool _isReconnecting = false;
  StreamSubscription? _healthSubscription;

  DeviceSession({
    required String deviceId,
    required this.name,
    required this.ip,
    required this.port,
    required DeviceIdentity identity,
    required this.trustStore,
    this.trustPolicy = TrustPolicy.tofu,
    int sockets = 4,
  })  : _deviceId = deviceId,
        pool = ConnectionPool(
          deviceId: deviceId,
          host: ip,
          port: port,
          identity: identity,
          trustStore: trustStore,
          trustPolicy: trustPolicy,
          connectionCount: sockets,
        ),
        health = ConnectionHealth(
          heartbeatInterval: const Duration(seconds: 5),
          heartbeatTimeout: const Duration(seconds: 15),
          maxMissedHeartbeats: 3,
        ),
        reconnectionManager = ReconnectionManager(
          maxRetries: 5,
          initialDelay: const Duration(seconds: 1),
          maxDelay: const Duration(seconds: 30),
          backoffMultiplier: 2.0,
        );

  String get deviceId => _deviceId;

  Stream<SimplePublicKey> get onPeerFingerprintKnown =>
      _peerFingerprintController.stream;

  Stream<ConnectionState> get healthStateChanges => health.stateChanges;

  Stream<ReconnectionEvent> get reconnectionEvents => reconnectionManager.events;

  Future<void> connect() async {
    await pool.connect();
    await pool.performHandshakes(isInitiator: true);

    // Start health monitoring on first connection
    if (pool.connections.isNotEmpty) {
      final firstConnection = pool.connections.first;
      _setupHealthMonitoring(firstConnection);
    }

    // After handshake, get the peer's fingerprint from the first connection
    if (pool.connections.isNotEmpty) {
      final peerKey = pool.connections.first.peerIdentityPublicKey;
      if (peerKey != null) {
        _peerFingerprintController.add(peerKey);
      }
    }
  }

  void _setupHealthMonitoring(Connection connection) {
    // Set up heartbeat pong callback on the secure channel
    connection.channel?.onHeartbeatPong = () {
      health.onHeartbeatReceived();
    };

    // Start heartbeat
    health.startHeartbeat(connection);

    // Listen for health state changes
    _healthSubscription?.cancel();
    _healthSubscription = health.stateChanges.listen((state) {
      if (state == ConnectionState.disconnected && !_isReconnecting) {
        _triggerReconnection();
      }
    });
  }

  Future<void> _triggerReconnection() async {
    if (_isReconnecting) return;
    _isReconnecting = true;

    try {
      await reconnectionManager.reconnect(
        session: this,
        onBeforeConnect: () {
          // Stop health monitoring before reconnect
          health.stop();
          _healthSubscription?.cancel();
        },
        onAfterConnect: () async {
          // Restart health monitoring after reconnect
          if (pool.connections.isNotEmpty) {
            _setupHealthMonitoring(pool.connections.first);
          }
        },
      );
    } finally {
      _isReconnecting = false;
    }
  }

  Future<void> reconnect() async {
    await pool.close();
    await pool.connect();
    await pool.performHandshakes(isInitiator: true);

    if (pool.connections.isNotEmpty) {
      final firstConnection = pool.connections.first;
      _setupHealthMonitoring(firstConnection);

      final peerKey = firstConnection.peerIdentityPublicKey;
      if (peerKey != null) {
        _peerFingerprintController.add(peerKey);
      }
    }
  }

  Future<void> close() {
    _healthSubscription?.cancel();
    health.stop();
    health.dispose();
    reconnectionManager.dispose();
    _peerFingerprintController.close();
    return pool.close();
  }

  void updateDeviceId(String newDeviceId) {
    _deviceId = newDeviceId;
    pool.updateDeviceId(newDeviceId);
  }
}