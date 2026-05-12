import 'dart:io';
import 'wifi_connection_platform_interface.dart';

class WifiConnection {
  Future<String?> getPlatformVersion() {
    return WifiConnectionPlatform.instance.getPlatformVersion();
  }

  // Wi-Fi
  static Future<bool> isWifiEnabled() {
    return WifiConnectionPlatform.instance.isWifiEnabled();
  }

  static Future<void> openWifiSettings() {
    return WifiConnectionPlatform.instance.openWifiSettings();
  }

  // Hotspot
  static Future<bool?> isHotspotEnabled() async {
    if (!Platform.isAndroid) {
      return null;
    }
    return await WifiConnectionPlatform.instance.isHotspotEnabled();
  }

  static Future<bool?> openHotspotSettings() async {
    if (!Platform.isAndroid) {
      return null;
    }
    await WifiConnectionPlatform.instance.openHotspotSettings();
    return true;
  }
}
