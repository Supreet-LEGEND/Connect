import 'package:flutter_test/flutter_test.dart';
import 'package:wifi_connection/wifi_connection.dart';
import 'package:wifi_connection/wifi_connection_platform_interface.dart';
import 'package:wifi_connection/wifi_connection_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockWifiConnectionPlatform
    with MockPlatformInterfaceMixin
    implements WifiConnectionPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final WifiConnectionPlatform initialPlatform = WifiConnectionPlatform.instance;

  test('$MethodChannelWifiConnection is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelWifiConnection>());
  });

  test('getPlatformVersion', () async {
    WifiConnection wifiConnectionPlugin = WifiConnection();
    MockWifiConnectionPlatform fakePlatform = MockWifiConnectionPlatform();
    WifiConnectionPlatform.instance = fakePlatform;

    expect(await wifiConnectionPlugin.getPlatformVersion(), '42');
  });
}
