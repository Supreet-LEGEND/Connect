import 'package:connect/core/connection_utils/device_connection_data_utils.dart';
import 'package:connect/core/device_discovery_and_connection/default_udp_broadcast_and_connecton_service.dart';
import 'package:connect/core/device_discovery_and_connection/udp_broadcast_service.dart';
import 'package:connect/core/device_discovery_and_connection/udp_connection_request.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

final udpServiceFutureProvider = FutureProvider.autoDispose<UdpDiscoveryService?>((
  ref,
) async {
  return await DefaultUdpBroadcastAndConnectionService.getDefaultUdpDiscoveryService();
});

// final udpServiceProvider = StateProvider.autoDispose<UdpDiscoveryService?>((
//   ref,
// ) {
//   return null;
// });

final connectionManagerFutureProvider =
    FutureProvider.autoDispose<ConnectionManager>((ref) async {
      return await DefaultUdpBroadcastAndConnectionService.getDefaultConnectionManager();
    });

final isDiscoveringProvider = StateProvider.autoDispose<bool>((ref) {
  return false;
});

final isDiscoveredProvider = StateProvider.autoDispose<bool>((ref) {
  return false;
});

final availableDevicesProvider =
    StateProvider.autoDispose<Map<String, DeviceConnectionInfo>>((ref) {
      return {};
    });

final connectedDevicesProvider =
    StateProvider.autoDispose<Map<String, DeviceConnectionInfo>>((ref) {
      return {};
    });

// callbacks providers
final onConnectionRequestProvider = StateProvider.autoDispose<String?>((ref) {
  return null;
});

final onConnectionAcceptedProvider = StateProvider.autoDispose<String?>((ref) {
  return null;
});

final onConnectionDeniedProvider = StateProvider.autoDispose<String?>((ref) {
  return null;
});

final onDevicesUpdatedProvider =
    StateProvider.autoDispose<Map<String, DeviceConnectionInfo>>((ref) {
      return {};
    });
