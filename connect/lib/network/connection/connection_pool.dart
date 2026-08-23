import 'dart:async';

import '../crypto/crypto_service.dart';
import 'connection.dart';

class ConnectionPool {
  final String deviceId;
  final String host;
  final int port;

  final CryptoService crypto;

  final int connectionCount;

  final List<Connection> _connections =
      [];

  final StreamController<void>
      _connectionState =
      StreamController<void>.broadcast();

  ConnectionPool({
    required this.deviceId,
    required this.host,
    required this.port,
    required this.crypto,
    this.connectionCount = 4,
  });

  Stream<void> get connectionState =>
      _connectionState.stream;

  List<Connection> get connections =>
      List.unmodifiable(_connections);

  Future<void> connect() async {
    for (int i = 0;
        i < connectionCount;
        i++) {
      final connection = Connection(
        id: '$deviceId-$i',
        deviceId: deviceId,
        host: host,
        port: port,
        crypto: crypto,
      );

      await connection.connect();

      _connections.add(connection);
    }

    _connectionState.add(null);
  }

  Connection? getFreeConnection() {
    for (final connection
        in _connections) {
      if (!connection.isBusy &&
          connection.isConnected) {
        return connection;
      }
    }

    return null;
  }

  Future<void> close() async {
    for (final connection
        in _connections) {
      await connection.close();
    }

    _connections.clear();

    await _connectionState.close();
  }
}