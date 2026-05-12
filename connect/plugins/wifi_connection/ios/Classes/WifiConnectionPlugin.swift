import Flutter
import UIKit

public class WifiConnectionPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "wifi_connection", binaryMessenger: registrar.messenger())
    let instance = WifiConnectionPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("iOS " + UIDevice.current.systemVersion)
    case "isWifiEnabled":
      // iOS does not allow direct Wi-Fi check; assume false
      result(false)
    case "openWifiSettings":
      if let url = URL(string:UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
      }
      result(true)
    case "isHotspotEnabled":
      // iOS does not provide API; return false
      result(false)
    case "openHotspotSettings":
      // Open personal hotspot settings
      if let url = URL(string: "App-Prefs:root=INTERNET_TETHERING") {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
      }
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
