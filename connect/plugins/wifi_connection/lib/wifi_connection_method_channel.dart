import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'wifi_connection_platform_interface.dart';

/// An implementation of [WifiConnectionPlatform] that uses method channels.
class MethodChannelWifiConnection extends WifiConnectionPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('wifi_connection');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }

  @override
  Future<bool> isWifiEnabled() async {
    final bool enabled = await methodChannel.invokeMethod('isWifiEnabled');
    return enabled;
  }

  @override
  Future<void> openWifiSettings() async {
    await methodChannel.invokeMethod('openWifiSettings');
  }

  @override
  Future<bool> isHotspotEnabled() async {
    final bool enabled = await methodChannel.invokeMethod('isHotspotEnabled');
    return enabled;
  }

  @override
  Future<void> openHotspotSettings() async {
    await methodChannel.invokeMethod('openHotspotSettings');
  }
}
