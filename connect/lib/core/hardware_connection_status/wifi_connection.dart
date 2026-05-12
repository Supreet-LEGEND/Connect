import 'dart:io';
import 'package:connect/relay/permission_manager.dart';
import 'package:wifi_scan/wifi_scan.dart';

class WifiNative {
  static Future<String?> getLocalIp() async {
    return (await getLocalIpAddrObj())?.address;
  }

  static Future<InternetAddress?> getLocalIpAddrObj() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );

    for (var interface in interfaces) {
      for (var addr in interface.addresses) {
        if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
          return addr;
        }
      }
    }
    return null;
  }

  static Future<List<String>?> getAvailableWifiNetworks() async {
    if (Platform.isAndroid) {
      return _getScannedResults().then((accessPoints) {
        return accessPoints?.map((ap) => ap.ssid).toList();
      });
    } else if (Platform.isIOS) {
      return _getScannedResults().then((accessPoints) {
        return accessPoints?.map((ap) => ap.ssid).toList();
      });
    } else if (Platform.isWindows) {
      final result = await Process.run('netsh', [
        'wlan',
        'show',
        'networks',
        'mode=bssid',
      ]);
      return result.stdout
          .toString()
          .trim()
          .split("\n")
          .where((s) => s.startsWith('SSID'))
          .map((s) {
            return s.split(':')[1].trim();
          })
          .toList();
    } else if (Platform.isMacOS) {
      return null;
    } else if (Platform.isLinux) {
      return null;
    }

    return null;
  }

  static Future<List<WiFiAccessPoint>?> _getScannedResults() async {
    // check platform support and necessary requirements
    final can = await WiFiScan.instance.canGetScannedResults(
      askPermissions: true,
    );
    switch (can) {
      case CanGetScannedResults.yes:
        // get scanned results
        final accessPoints = await WiFiScan.instance.getScannedResults();
        return accessPoints;
      // ... handle other cases of CanGetScannedResults values
      case CanGetScannedResults.notSupported:
        return null;
      case CanGetScannedResults.noLocationPermissionRequired:
        throw UnimplementedError();
      case CanGetScannedResults.noLocationPermissionDenied:
        throw UnimplementedError();
      case CanGetScannedResults.noLocationPermissionUpgradeAccuracy:
        throw UnimplementedError();
      case CanGetScannedResults.noLocationServiceDisabled:
        PermissionManager.ensureWifiScanReady();
        return null;
    }
  }
}
