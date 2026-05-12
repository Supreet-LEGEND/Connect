import 'package:connect/core/hardware_connection_status/wifi_connection.dart';
import 'package:wifi_connection/wifi_connection.dart';

class WifiConnectionManager {
  // hotspot related methods

  static Future<bool?> isHotspotEnabled() async {
    return await WifiConnection.isHotspotEnabled();
  }

  static Future<bool?> openHotspotSettings() async {
    return await WifiConnection.openHotspotSettings();
  }

  // wifi related methods

  static Future<bool?> isWifiEnabled() async {
    return await WifiConnection.isWifiEnabled();
  }

  static Future<String?> getLocalIp() async {
    return await WifiNative.getLocalIp();
  }

  // GET LIST OF AVAILABLE WIFI NETWORKS SSIDs OR NULL IF NOT SUPPORTED
  static Future<List<String>?> getAvailableWifiNetworksSSID() async {
    return await WifiNative.getAvailableWifiNetworks();
  }

  // OPENS WIFI SETTINGS IN DIFFERENT PLATFORMS
  static Future<bool?> openWifiSettings() async {
    await WifiConnection.openWifiSettings();
    return true;
  }
}
