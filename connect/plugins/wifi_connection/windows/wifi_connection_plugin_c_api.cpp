#include "include/wifi_connection/wifi_connection_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "wifi_connection_plugin.h"

void WifiConnectionPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  wifi_connection::WifiConnectionPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
