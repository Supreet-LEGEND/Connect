import '../crypto/crypto_service.dart';
import 'connection_pool.dart';

class DeviceSession {
  final String deviceId;
  final String name;
  final String ip;
  final int port;

  final ConnectionPool pool;

  DeviceSession({
    required this.deviceId,
    required this.name,
    required this.ip,
    required this.port,
    required CryptoService crypto,
    int sockets = 4,
  }) : pool = ConnectionPool(
          deviceId: deviceId,
          host: ip,
          port: port,
          crypto: crypto,
          connectionCount: sockets,
        );

  Future<void> connect() {
    return pool.connect();
  }

  Future<void> close() {
    return pool.close();
  }
}