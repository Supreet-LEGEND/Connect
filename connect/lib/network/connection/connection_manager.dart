import 'package:connect/network/connection/device_session.dart';
import 'package:connect/network/crypto/crypto_service.dart';

class ConnectionManager {
  final Map<String, DeviceSession>
      _devices = {};

  Map<String, DeviceSession>
      get devices =>
          Map.unmodifiable(_devices);

  Future<DeviceSession> addDevice({
    required String deviceId,
    required String name,
    required String ip,
    required int port,
    required CryptoService crypto,
    int sockets = 4,
  }) async {
    final existing =
        _devices[deviceId];

    if (existing != null) {
      return existing;
    }

    final device = DeviceSession(
      deviceId: deviceId,
      name: name,
      ip: ip,
      port: port,
      crypto: crypto,
      sockets: sockets,
    );

    await device.connect();

    _devices[deviceId] = device;

    return device;
  }

  DeviceSession? get(
    String deviceId,
  ) {
    return _devices[deviceId];
  }

  Future<void> remove(
    String deviceId,
  ) async {
    final device =
        _devices.remove(deviceId);

    await device?.close();
  }

  Future<void> closeAll() async {
    for (final device
        in _devices.values) {
      await device.close();
    }

    _devices.clear();
  }
}