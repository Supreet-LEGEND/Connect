import 'package:connect/core/hardware_connection_status/hardware_connection_status_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

final isWifiEnabledProvider = FutureProvider.autoDispose<bool?>((ref) async {
  return WifiConnectionManager.isWifiEnabled();
});

// returns the SSID of the connected wifi network, null if not connected
final availableWifiNewtworksProvider =
    FutureProvider.autoDispose<List<String>?>((ref) async {
      return await WifiConnectionManager.getAvailableWifiNetworksSSID();
    });

// status = true if connected to wifi, false otherwise
final wifiStatusProvider = StreamProvider<bool>((ref) {
  return Connectivity().onConnectivityChanged.map((result) {
    return result.contains(ConnectivityResult.wifi);
  });
});

final connectedWifiIpProvider = FutureProvider.autoDispose<String?>((
  ref,
) async {
  return await WifiConnectionManager.getLocalIp();
});
