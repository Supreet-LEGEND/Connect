#include "wifi_connection_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

// For getPlatformVersion; remove unless needed for your plugin implementation.
#include <VersionHelpers.h>

#include "wifi_connection_plugin.h"
#include <windows.h>
#include <wlanapi.h>
#include <objbase.h>
#include <wtypes.h>
#pragma comment(lib, "wlanapi.lib")
#pragma comment(lib, "ole32.lib")

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <sstream>

namespace wifi_connection
{

  // static
  void WifiConnectionPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarWindows *registrar)
  {
    auto channel =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), "wifi_connection",
            &flutter::StandardMethodCodec::GetInstance());

    auto plugin = std::make_unique<WifiConnectionPlugin>();

    channel->SetMethodCallHandler(
        [plugin_pointer = plugin.get()](const auto &call, auto result)
        {
          plugin_pointer->HandleMethodCall(call, std::move(result));
        });

    registrar->AddPlugin(std::move(plugin));
  }

  WifiConnectionPlugin::WifiConnectionPlugin() {}

  WifiConnectionPlugin::~WifiConnectionPlugin() {}

  // FUCNTION TO CHECK WIFI ENABLED STATUS ON WINDOWS
  bool IsWifiEnabledWindows()
  {
    HANDLE hClient = NULL;
    DWORD dwMaxClient = 2;
    DWORD dwCurVersion = 0;
    DWORD dwResult = WlanOpenHandle(dwMaxClient, NULL, &dwCurVersion, &hClient);
    if (dwResult != ERROR_SUCCESS)
      return false;

    PWLAN_INTERFACE_INFO_LIST pIfList = NULL;
    dwResult = WlanEnumInterfaces(hClient, NULL, &pIfList);
    if (dwResult != ERROR_SUCCESS || pIfList == NULL)
    {
      WlanCloseHandle(hClient, NULL);
      return false;
    }

    bool wifiEnabled = false;
    for (DWORD i = 0; i < pIfList->dwNumberOfItems; i++)
    {
      WLAN_INTERFACE_INFO iface = pIfList->InterfaceInfo[i];
      if (
          iface.isState != wlan_interface_state_not_ready)
      {
        wifiEnabled = true;
        break;
      }
    }

    if (pIfList)
      WlanFreeMemory(pIfList);
    WlanCloseHandle(hClient, NULL);
    return wifiEnabled;
  }

  void WifiConnectionPlugin::HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
  {
    if (method_call.method_name().compare("getPlatformVersion") == 0)
    {
      std::ostringstream version_stream;
      version_stream << "Windows ";
      if (IsWindows10OrGreater())
      {
        version_stream << "10+";
      }
      else if (IsWindows8OrGreater())
      {
        version_stream << "8";
      }
      else if (IsWindows7OrGreater())
      {
        version_stream << "7";
      }
      result->Success(flutter::EncodableValue(version_stream.str()));
    }

    else if (method_call.method_name() == "isWifiEnabled")
    {
      result->Success(flutter::EncodableValue(IsWifiEnabledWindows()));
    }
    else if (method_call.method_name() == "openWifiSettings")
    {
      system("start ms-settings:network-wifi");
      result->Success(flutter::EncodableValue(true));
    }
    else
    {
      result->NotImplemented();
    }
  }

} // namespace wifi_connection
