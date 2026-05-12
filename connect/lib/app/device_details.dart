import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';

class DeviceDetailsManager {
  DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();

  String getDevicePlatform() {
    return Platform.operatingSystem;
  }

  // GET DEVICE NAME BASED ON PLATFORM
  Future<String> getDeviceName() async {
    if (Platform.isAndroid) {
      AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
      return androidInfo.name;
    } else if (Platform.isIOS) {
      IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
      return iosInfo.name;
    } else if (Platform.isWindows) {
      WindowsDeviceInfo windowsInfo = await deviceInfo.windowsInfo;
      return windowsInfo.computerName;
    } else if (Platform.isMacOS) {
      MacOsDeviceInfo macInfo = await deviceInfo.macOsInfo;
      return macInfo.computerName;
    } else if (Platform.isLinux) {
      LinuxDeviceInfo linuxInfo = await deviceInfo.linuxInfo;
      return linuxInfo.name;
    } else {
      return "Unknown Device";
    }
  }
}
