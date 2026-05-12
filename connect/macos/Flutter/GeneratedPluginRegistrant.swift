//
//  Generated file. Do not edit.
//

import FlutterMacOS
import Foundation

import app_settings
import connectivity_plus
import device_info_plus
import geolocator_apple
import package_info_plus
import wifi_connection

func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {
  AppSettingsPlugin.register(with: registry.registrar(forPlugin: "AppSettingsPlugin"))
  ConnectivityPlusPlugin.register(with: registry.registrar(forPlugin: "ConnectivityPlusPlugin"))
  DeviceInfoPlusMacosPlugin.register(with: registry.registrar(forPlugin: "DeviceInfoPlusMacosPlugin"))
  GeolocatorPlugin.register(with: registry.registrar(forPlugin: "GeolocatorPlugin"))
  FPPPackageInfoPlusPlugin.register(with: registry.registrar(forPlugin: "FPPPackageInfoPlusPlugin"))
  WifiConnectionPlugin.register(with: registry.registrar(forPlugin: "WifiConnectionPlugin"))
}
