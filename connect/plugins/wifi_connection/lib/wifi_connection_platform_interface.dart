import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'wifi_connection_method_channel.dart';

abstract class WifiConnectionPlatform extends PlatformInterface {
  /// Constructs a WifiConnectionPlatform.
  WifiConnectionPlatform() : super(token: _token);

  static final Object _token = Object();

  static WifiConnectionPlatform _instance = MethodChannelWifiConnection();

  /// The default instance of [WifiConnectionPlatform] to use.
  ///
  /// Defaults to [MethodChannelWifiConnection].
  static WifiConnectionPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [WifiConnectionPlatform] when
  /// they register themselves.
  static set instance(WifiConnectionPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  // Wi-Fi
  Future<bool> isWifiEnabled() {
    throw UnimplementedError('isWifiEnabled() has not been implemented.');
  }

  Future<void> openWifiSettings() {
    throw UnimplementedError('openWifiSettings() has not been implemented.');
  }

  // Hotspot
  Future<bool> isHotspotEnabled() {
    throw UnimplementedError('isHotspotEnabled() has not been implemented.');
  }

  Future<void> openHotspotSettings() {
    throw UnimplementedError('openHotspotSettings() has not been implemented.');
  }
}
