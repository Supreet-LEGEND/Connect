#ifndef FLUTTER_PLUGIN_WIFI_CONNECTION_PLUGIN_H_
#define FLUTTER_PLUGIN_WIFI_CONNECTION_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace wifi_connection {

class WifiConnectionPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  WifiConnectionPlugin();

  virtual ~WifiConnectionPlugin();

  // Disallow copy and assign.
  WifiConnectionPlugin(const WifiConnectionPlugin&) = delete;
  WifiConnectionPlugin& operator=(const WifiConnectionPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace wifi_connection

#endif  // FLUTTER_PLUGIN_WIFI_CONNECTION_PLUGIN_H_
