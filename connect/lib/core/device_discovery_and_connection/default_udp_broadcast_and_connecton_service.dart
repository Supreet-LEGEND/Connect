import 'package:connect/app/device_details.dart';
import 'package:connect/app/udp_config.dart';
import 'package:connect/core/hardware_connection_status/hardware_connection_status_manager.dart';
import 'package:connect/core/device_discovery_and_connection/udp_broadcast_service.dart';
import 'package:connect/core/device_discovery_and_connection/udp_connection_request.dart';

class DefaultUdpBroadcastAndConnectionService {
  // Returns a UdpDiscoveryService with default parameters (local IP and device name)
  static Future<UdpDiscoveryService?> getDefaultUdpDiscoveryService({
    void Function(String)? onConnectionRequest,
    void Function(String)? onConnectionAccepted,
    void Function(String)? onConnectionDenied,
  }) async {
    String? ip = await WifiConnectionManager.getLocalIp();
    String deviceName = await DeviceDetailsManager().getDeviceName();

    if (ip == null) {
      return null;
    }

    return UdpDiscoveryService(
      broadcastPort: UdpConfig.broadcastPort,
      myIp: ip,
      myName: deviceName,
      onConnectionRequest: onConnectionRequest,
      onConnectionAccepted: onConnectionAccepted,
      onConnectionDenied: onConnectionDenied,
    );
  }

  // Returns a UdpConnectionSignaler with default parameters (local IP and device name)
  static Future<UdpConnectionSignaler> getDefaultConnectionSignaler() async {
    String? ip = await WifiConnectionManager.getLocalIp();
    String deviceName = await DeviceDetailsManager().getDeviceName();

    return UdpConnectionSignaler(
      port: UdpConfig.broadcastPort,
      deviceIp: ip!,
      deviceName: deviceName,
    );
  }
}
