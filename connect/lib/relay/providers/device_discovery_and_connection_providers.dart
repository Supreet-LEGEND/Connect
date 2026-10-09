import 'package:connect/network/connection_utils/device_connection_data_utils.dart';
import 'package:connect/core/device_discovery_and_connection/default_udp_broadcast_and_connecton_service.dart';
import 'package:connect/core/device_discovery_and_connection/udp_broadcast_service.dart';
import 'package:connect/core/device_discovery_and_connection/udp_connection_request.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

// UDP Service - using FutureProvider for lifecycle
final udpDiscoveryServiceProvider = FutureProvider<UdpDiscoveryService?>((ref) async {
  return await DefaultUdpBroadcastAndConnectionService.getDefaultUdpDiscoveryService();
});

// UDP Service Future Provider
final udpServiceFutureProvider = FutureProvider<UdpDiscoveryService?>((ref) async {
  return await DefaultUdpBroadcastAndConnectionService.getDefaultUdpDiscoveryService();
});

// Connection Signaler
final connectionSignalerFutureProvider = FutureProvider<UdpConnectionSignaler>((ref) async {
  return await DefaultUdpBroadcastAndConnectionService.getDefaultConnectionSignaler();
});

// Discovery State
final isDiscoveringProvider = StateProvider<bool>((ref) => false);
final isDiscoveredProvider = StateProvider<bool>((ref) => false);

// Available Devices - using StateProvider for simplicity
final availableDevicesProvider = StateProvider.autoDispose<Map<String, DeviceConnectionInfo>>((ref) => {});

// Connected Devices - persistent, not autoDispose
final connectedDevicesProvider = StateProvider<Map<String, DeviceConnectionInfo>>((ref) => {});

// Callback providers
final onConnectionRequestProvider = StateProvider<String?>((ref) => null);
final onConnectionAcceptedProvider = StateProvider<String?>((ref) => null);
final onConnectionDeniedProvider = StateProvider<String?>((ref) => null);
final onDevicesUpdatedProvider = StateProvider.autoDispose<Map<String, DeviceConnectionInfo>>((ref) => {});

// Controller providers for UI actions
class DiscoveryController {
  final Ref ref;
  DiscoveryController(this.ref);

  Future<void> startDiscovery() async {
    final service = await ref.read(udpDiscoveryServiceProvider.future);
    if (service != null) {
      // Restart broadcast if it was stopped
      service.stopBroadcast();
      await service.start();
      ref.read(isDiscoveringProvider.notifier).state = true;
    }
  }

  Future<void> stopDiscovery() async {
    final service = await ref.read(udpDiscoveryServiceProvider.future);
    if (service != null) {
      service.stopBroadcast();
      ref.read(isDiscoveringProvider.notifier).state = false;
    }
  }

  void onConnectionRequest(String ip) {
    ref.read(onConnectionRequestProvider.notifier).state = ip;
  }

  void onConnectionAccepted(String ip) {
    ref.read(onConnectionAcceptedProvider.notifier).state = ip;
  }

  void onConnectionDenied(String ip) {
    ref.read(onConnectionDeniedProvider.notifier).state = ip;
  }

  void onDevicesUpdated(Map<String, DeviceConnectionInfo> devices) {
    ref.read(availableDevicesProvider.notifier).state = Map.from(devices);
    if (devices.isNotEmpty) {
      ref.read(isDiscoveredProvider.notifier).state = true;
    }
  }

  void onDisconnect(String ip) {
    ref.read(connectedDevicesProvider.notifier).update((state) {
      final newState = Map<String, DeviceConnectionInfo>.from(state);
      newState.remove(ip);
      return newState;
    });
  }
}

final discoveryControllerProvider = Provider<DiscoveryController>((ref) => DiscoveryController(ref));