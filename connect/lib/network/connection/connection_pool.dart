import 'dart:async';

import '../crypto/device_identity.dart';
import 'connection.dart';
import '../crypto/trust_store.dart';

class ConnectionPool {
  String deviceId;
  final String host;
  final int port;

  final DeviceIdentity identity;
  final TrustStore trustStore;
  final TrustPolicy trustPolicy;

  final int connectionCount;

  final List<Connection> _connections = [];

  StreamController<void> _connectionState = StreamController<void>.broadcast();

  ConnectionPool({
    required this.deviceId,
    required this.host,
    required this.port,
    required this.identity,
    required this.trustStore,
    this.trustPolicy = TrustPolicy.tofu,
    this.connectionCount = 4,
  });

  Stream<void> get connectionState =>
      _connectionState.stream;

  List<Connection> get connections =>
      List.unmodifiable(_connections);

  Future<void> connect() async {
    // Close existing connections first
    await closeConnectionsOnly();

    for (int i = 0; i < connectionCount; i++) {
      final connection = Connection(
        id: '$deviceId-$i',
        deviceId: deviceId,
        host: host,
        port: port,
        identity: identity,
        trustStore: trustStore,
        trustPolicy: trustPolicy,
      );

      await connection.connect();

      _connections.add(connection);
    }

    // Notify listeners that connections are ready
    _connectionState.add(null);
  }

  Future<void> closeConnectionsOnly() async {
    for (final connection in _connections) {
      await connection.close();
    }
    _connections.clear();
  }

  Future<void> performHandshakes({required bool isInitiator}) async {
    for (final connection in _connections) {
      await connection.performHandshake(isInitiator: isInitiator);
    }
  }

  Connection? getFreeConnection() {
    for (final connection in _connections) {
      if (!connection.isBusy &&
          connection.isConnected &&
          connection.isHandshakeComplete) {
        return connection;
      }
    }
    return null;
  }

  void updateDeviceId(String newDeviceId) {
    deviceId = newDeviceId;
    for (int i = 0; i < _connections.length; i++) {
      _connections[i].updateDeviceId('$newDeviceId-$i');
    }
  }

  Future<void> close() async {
    await closeConnectionsOnly();
    await _connectionState.close();
  }
}