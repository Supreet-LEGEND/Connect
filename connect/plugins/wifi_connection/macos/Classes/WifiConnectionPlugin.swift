import Cocoa
import FlutterMacOS

public class WifiConnectionPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "wifi_connection", binaryMessenger: registrar.messenger)
    let instance = WifiConnectionPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
    case "isWifiEnabled":
      // macOS does not allow direct Wi-Fi API easily; return false as best effort
      result(false)
    case "openWifiSettings":
      NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Network.prefPane"))
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
